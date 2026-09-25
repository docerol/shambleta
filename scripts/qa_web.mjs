// QA local do pacote Web: serve `build/Web/` com os mesmos headers de isolamento
// que `deploy/web/nginx.conf` serve em produção e abre o artifact num Chromium
// headless de verdade (CDP puro, sem dependência de npm), coletando console,
// erros de rede e o estado do service worker.
//
// Por que isto existe: até 2026-09-25 nenhuma suíte do repositório abria o build
// web — o gate godot roda `--headless -s` (sem navegador) e o export só media
// bytes. Plataforma de lançamento sem nenhum teste que a executa. E as três
// coisas que decidem se o jogador consegue abrir o jogo — `crossOriginIsolated`
// (sem isso o build com thread_support aborta antes do boot), o canvas que o
// engine cria e o service worker que torna o app instalável no celular — só são
// observáveis dentro de um navegador.
//
// Uso: node scripts/qa_web.mjs [--dir build/Web] [--expect-sw 1] [--deadline 180]
//      [--chrome <bin>] [--shot <png>] [--keep-open 0]
// Sai com a linha de resultado no formato que `scripts/ci_gate_log.sh` lê
// ("== RESULT: N checks, M failures ==") e `[FAIL]` por check falho.

import {createServer} from 'node:http';
import {readFile, writeFile, mkdtemp, rm} from 'node:fs/promises';
import {existsSync, readFileSync} from 'node:fs';
import {spawn} from 'node:child_process';
import {tmpdir} from 'node:os';
import {join, extname, resolve} from 'node:path';

function arg(name, dflt) {
	const i = process.argv.indexOf('--' + name);
	if (i < 0) return dflt;
	const v = process.argv[i + 1];
	return (v === undefined || v.startsWith('--')) ? '1' : v;
}

const ROOT = resolve(arg('dir', 'build/Web'));
const EXPECT_SW = Number(arg('expect-sw', '1'));
const DEADLINE = Number(arg('deadline', '180')) * 1000;
const KEEP_OPEN = Number(arg('keep-open', '0')) * 1000;
const SHOT = arg('shot', '');
const CHROME = arg('chrome', process.env.HOME + '/.cache/ms-playwright/chromium-1234/chrome-linux64/chrome');

// Mesmos tipos que o nginx serve; sem `application/wasm` correto o Chrome recusa
// o streaming compilation e o boot morre com um erro que não é do jogo.
const MIME = {
	'.html': 'text/html; charset=utf-8', '.js': 'application/javascript', '.mjs': 'application/javascript',
	'.wasm': 'application/wasm', '.pck': 'application/octet-stream', '.json': 'application/json',
	'.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/vnd.microsoft.icon', '.cfg': 'text/plain',
};

// O contrato de isolamento do nginx (deploy/web/nginx.conf:21-32): COOP/COEP em
// todo arquivo do shell e `no-cache` em index.html e no service worker, para o
// deploy novo ser pego na hora. Copiado de propósito: se as duas metades
// divergirem, o QA local verde não vale para a produção.
function isolationHeaders(pathname) {
	const h = {
		'Cross-Origin-Opener-Policy': 'same-origin',
		'Cross-Origin-Embedder-Policy': 'require-corp',
		'Cross-Origin-Resource-Policy': 'cross-origin',
		'Cache-Control': 'no-cache',
	};
	if (!/^\/(index\.html|[^/]*\.service\.worker\.js)$/.test(pathname)) {
		h['Cache-Control'] = 'public, max-age=3600';
	}
	return h;
}

const server = createServer(async (req, res) => {
	const pathname = decodeURIComponent(new URL(req.url, 'http://x').pathname);
	const file = join(ROOT, pathname === '/' ? 'index.html' : pathname.replace(/^\/+/, ''));
	if (!file.startsWith(ROOT)) { res.writeHead(403).end('fora da raiz'); return; }
	try {
		const body = await readFile(file);
		res.writeHead(200, {'Content-Type': MIME[extname(file)] || 'application/octet-stream', ...isolationHeaders(pathname)});
		res.end(body);
	} catch {
		res.writeHead(404, isolationHeaders(pathname)).end('não existe: ' + pathname);
	}
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const BASE = 'http://127.0.0.1:' + server.address().port + '/';

const checks = [];
function Check(ok, msg) {
	checks.push({ok: !!ok, msg});
	console.log((ok ? '  OK  ' : '[FAIL] ') + msg);
}

// ------------------------------------------------------------------ Chromium
const profile = await mkdtemp(join(tmpdir(), 'qa-web-'));
const chrome = spawn(CHROME, [
	'--headless=new', '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage',
	'--user-data-dir=' + profile, '--remote-debugging-port=0', '--remote-allow-origins=*',
	'about:blank',
], {stdio: ['ignore', 'pipe', 'pipe']});
let chromeStderr = '';
chrome.stderr.on('data', (d) => { chromeStderr += d.toString(); });

async function devtoolsPort() {
	const f = join(profile, 'DevToolsActivePort');
	for (let waited = 0; waited < 30000; waited += 250) {
		if (existsSync(f)) {
			const first = readFileSync(f, 'utf8').split('\n')[0].trim();
			if (/^\d+$/.test(first)) return Number(first);
		}
		await new Promise((r) => setTimeout(r, 250));
	}
	throw new Error('Chromium não expôs DevToolsActivePort em 30 s. stderr:\n' + chromeStderr);
}
const port = await devtoolsPort();

const console_ = [];   // {type, text, src}
const netErrors = [];  // {text, url}
const exceptions = [];

const version = await (await fetch(BASE.replace(/:\d+\/$/, ':' + port + '/') + 'json/version')).json();
let ws = new WebSocket(version.webSocketDebuggerUrl);
await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
let seq = 0;
const pending = new Map();
const sessions = new Map();

function send(method, params = {}, sessionId) {
	return new Promise((resolve) => {
		const id = ++seq;
		pending.set(id, resolve);
		ws.send(JSON.stringify(sessionId ? {id, method, params, sessionId} : {id, method, params}));
	});
}
ws.onmessage = (ev) => {
	const m = JSON.parse(ev.data);
	if (m.id && pending.has(m.id)) { pending.get(m.id)(m.result ?? m.error); pending.delete(m.id); return; }
	const sid = m.sessionId;
	if (m.method === 'Runtime.consoleAPICalled' && sid) {
		const text = (m.params.args || []).map((a) => a.value ?? a.description ?? a.unserializableValue ?? '').join(' ');
		console_.push({type: m.params.type, text});
	} else if (m.method === 'Runtime.exceptionThrown' && sid) {
		const d = m.params.exceptionDetails;
		exceptions.push({text: d.exception?.description || d.text || 'exceção sem descrição', url: d.url || '', line: d.lineNumber ?? -1});
	} else if (m.method === 'Log.entryAdded' && sid) {
		const e = m.params.entry;
		if (e.source === 'network' && e.level === 'error') netErrors.push({text: e.text || '', url: e.url || ''});
	}
};

const {targetId} = await send('Target.createTarget', {url: 'about:blank'});
const {sessionId} = await send('Target.attachToTarget', {targetId, flatten: true});
await send('Runtime.enable', {}, sessionId);
await send('Page.enable', {}, sessionId);
await send('Log.enable', {}, sessionId);
await send('Page.navigate', {url: BASE + 'index.html'}, sessionId);

// Espera o banner do engine no console (o que prova que o main loop rodou), com
// teto de tempo — boot de 36 MB em localhost não é instantâneo e um crash
// silencioso tem que estourar como falha, não como espera infinita.
const BANNER = /Godot Engine v[0-9]/;
let bannerSeen = false;
const t0 = Date.now();
while (Date.now() - t0 < DEADLINE) {
	if (console_.some((c) => BANNER.test(c.text))) { bannerSeen = true; break; }
	await new Promise((r) => setTimeout(r, 250));
}
await new Promise((r) => setTimeout(r, 2500)); // deixa o boot continuar até um estado estável

const PROBE = `(async () => {
	const regs = await navigator.serviceWorker.getRegistrations();
	const canvas = document.querySelector('canvas');
	let manifest = null;
	const link = document.querySelector('link[rel="manifest"]');
	if (link) { try { manifest = await (await fetch(link.href)).json(); } catch (e) { manifest = {error: String(e)}; } }
	return {
		crossOriginIsolated: self.crossOriginIsolated === true,
		sharedArrayBuffer: typeof SharedArrayBuffer === 'function',
		canvas: canvas ? {id: canvas.id, w: canvas.width, h: canvas.height} : null,
		sw: regs.map((r) => ({scope: r.scope, script: r.active ? r.active.scriptURL : (r.installing ? r.installing.scriptURL : null), waiting: !!r.waiting})),
		manifest: manifest,
		splashLoaded: (() => { const i = document.getElementById('status-splash'); return i ? (i.complete && i.naturalWidth > 0) : null; })(),
	};
})()`;
const probeResult = await send('Runtime.evaluate', {expression: PROBE, awaitPromise: true, returnByValue: true}, sessionId);
const page = probeResult.result?.value ?? null;

if (SHOT) {
	const shot = await send('Page.captureScreenshot', {format: 'png'}, sessionId);
	if (shot.data) await writeFile(SHOT, Buffer.from(shot.data, 'base64'));
}

// ------------------------------------------------------------------ checks
console.log('== QA web: ' + BASE + ROOT);
Check(bannerSeen, 'web: o engine bootou no navegador (banner "Godot Engine v" no console)');
Check(!!page, 'web: a página respondeu à sonda de estado (sem timeout de evaluate)');
if (page) {
	Check(page.crossOriginIsolated, 'web: crossOriginIsolated true com os headers do nginx (sem isso o build thread_support aborta)');
	Check(page.sharedArrayBuffer, 'web: SharedArrayBuffer existe (threads habilitadas)');
	Check(page.canvas && page.canvas.w > 0 && page.canvas.h > 0, 'web: o canvas do engine existe com tamanho não-zero (' + JSON.stringify(page.canvas) + ')');
	Check(page.manifest && page.manifest.display === 'standalone' && Array.isArray(page.manifest.icons) && page.manifest.icons.length > 0, 'pwa: manifest servido com display standalone e ícone (' + JSON.stringify(page.manifest && {d: page.manifest.display, i: (page.manifest.icons || []).length}) + ')');
	Check(page.sw.length === EXPECT_SW, 'pwa: ' + EXPECT_SW + ' service worker(s) registrado(s) no escopo raiz (' + JSON.stringify(page.sw) + ')');
}

// Erro de conexão com o servidor do jogo é esperado aqui: o pacote local não tem
// `SHAMBLETA_SERVER_ADDRESS` horneado (só o Dockerfile horneia). Tudo o que não
// for dessa classe é falha real — inclusive o GDScript, cujo erro o engine
// encaminha para o console do navegador com a mesma etiqueta "SCRIPT ERROR" que
// o gate §24-8 procura no log.
const EXPECTED_NET = /ERR_NAME_NOT_RESOLVED|ERR_CONNECTION_REFUSED|ERR_EMPTY_RESPONSE|websocket|wss?:\/\//i;
const unexpectedNet = (page ? netErrors : []).filter((e) => !EXPECTED_NET.test(e.text + ' ' + e.url));
Check(unexpectedNet.length === 0, 'web: nenhuma requisição do pacote falhou (' + unexpectedNet.length + ' inesperadas: ' + JSON.stringify(unexpectedNet.slice(0, 3)) + ')');
const errConsole = console_.filter((c) => c.type === 'error' && !EXPECTED_NET.test(c.text));
// Godot despeja um `console.error` por linha: a mensagem, a linha `at:` e cada quadro
// do backtrace do GDScript chegam como entradas separadas. Contar entrada por entrada
// inflava o veredito (a medição de 2026-09-25 reportou "47" para meia dúzia de erros),
// e um portão que não conta a mesma coisa que um humano lê não é portão. O que conta é
// cabeçalho de erro — o resto é continuação do anterior.
const CONTINUATION = /^\s*(at\s|GDScript backtrace|\[\d+\])/;
const errHeads = errConsole.filter((c) => !CONTINUATION.test(c.text));
Check(errHeads.length === 0, 'web: nenhum erro de console além da conexão ausente com o server (' + errHeads.length + ' de ' + errConsole.length + ' linhas: ' + JSON.stringify(errHeads.slice(0, 4).map((c) => c.text.slice(0, 160))) + ')');
Check(exceptions.length === 0, 'web: nenhuma exceção não tratada na página (' + JSON.stringify(exceptions.slice(0, 2)) + ')');

// despejo de diagnóstico: o gate decide por contagem, mas quem lê o log precisa
// ver a linha inteira (o backtrace do GDScript vem no console do navegador com
// arquivo e função — é assim que se nomeia a causa sem adivinhar).
const dump = console_.filter((c) => c.type === 'error' || c.type === 'warning');
if (dump.length) {
	console.log('--- console do navegador (' + dump.length + ' linhas error/warning) ---');
	for (const c of dump.slice(0, 60)) console.log('  [' + c.type + '] ' + c.text);
}
if (netErrors.length) {
	console.log('--- rede (' + netErrors.length + ') ---');
	for (const e of netErrors.slice(0, 20)) console.log('  ' + e.text + ' ' + e.url);
}

const failures = checks.filter((c) => !c.ok).length;
console.log('== RESULT: ' + checks.length + ' checks, ' + failures + ' failures ==');

if (KEEP_OPEN) await new Promise((r) => setTimeout(r, KEEP_OPEN));
try { ws.close(); } catch {}
try { server.close(); } catch {}
chrome.kill('SIGTERM');
await rm(profile, {recursive: true, force: true});
process.exit(failures === 0 ? 0 : 1);
