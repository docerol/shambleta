// Shambleta — worker de web push (SOM-W5/B). NÃO É o service worker do engine.
//
// O export Godot registra `index.service.worker.js` no escopo "/" — é ele que
// cuida do cache offline dos assets (.pck/.wasm). Este arquivo aqui é um segundo
// worker, fino, só de push: trata `push` e `notificationclick` e NUNCA instala
// handler de `fetch` — interceptar requests por cima do worker do engine
// quebraria o streaming/caching do build.
//
// Um worker substitui o outro no MESMO escopo, então o registro deste é feito com
// escopo ESTREITO — `register('/sw.js', {scope:'/sw/'})`, na ponte do jogo
// (ShambletaPush.register_sw, chamada por WebPush._register_service_worker) — e o
// engine continua dono de '/'. O arquivo precisa morar na raiz mesmo assim: é o
// teto do escopo que um script controla, e '/sw/' está dentro dele. COOP/COEP
// vêm do nginx (deploy/web/nginx.conf), não do worker, então o escopo estreito não
// custa threads. Custo real: clients.matchAll só enxerga janelas dentro do escopo,
// e '/sw/' não contém página nenhuma — notificationclick abaixo quase sempre vai
// openWindow em vez de focar a aba existente.
//
// O registro continua atrás de WebPushDelivery.CanDeliver() — a conjunção de
// cinco peças (sender implementado, chave VAPID configurada, navegador capaz de
// assinar, servidor que persiste a subscription, caminho client->server). Assim
// este arquivo só é registrado quando a entrega inteira existir; enquanto
// CanDeliver() é false ele fica servido (Dockerfile/nginx) e jamais registrado.
//
// Regra de manutenção: nada daqui pode tocar em requests. Se um dia precisar
// de fetch, é o worker do engine que cresce — não este.

self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener('push', (event) => {
  let data = {};
  if (event.data) {
    try {
      data = event.data.json();
    } catch (e) {
      data = { title: 'Shambleta', body: event.data.text() };
    }
  }
  const title = data.title || 'Shambleta';
  const options = {
    body: data.body || '',
    icon: data.icon || 'index.144x144.png',
    badge: data.badge || 'index.144x144.png',
    data: data.url || '/',
    requireInteraction: false,
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = event.notification.data || '/';
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clients) => {
      for (const client of clients) {
        if (client.url === url && 'focus' in client) {
          return client.focus();
        }
      }
      if (self.clients.openWindow) {
        return self.clients.openWindow(url);
      }
    })
  );
});
