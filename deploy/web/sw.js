// Shambleta — worker de web push (SOM-W5/B). NÃO É o service worker do engine.
//
// O export Godot registra `index.service.worker.js` no escopo "/" — é ele que
// traz COOP/COEP e o cache offline dos assets (.pck/.wasm). Este arquivo aqui é
// um segundo worker, fino, só de push: trata `push` e `notificationclick` e
// NUNCA instala handler de `fetch` — interceptar requests por cima do worker
// do engine quebraria o streaming/caching do build e o cabeçalho CORS-Origem
// compartilhada. Um worker substitui o outro no MESMO escopo: por isso o
// registro disto (`navigator.serviceWorker.register('/sw.js', {scope:'/'})`,
// chamado do lado do jogo via WebPush/_register_service_worker) fica atrás de
// WebPush.CanDeliver(), ainda false — só ligar quando existir entrega real
// (chave VAPID + subscription + sender no companion). Enquanto CanDeliver() é
// false, este arquivo está servido (Dockerfile/nginx) mas jamais registrado, e
// o worker do engine continua no controle de tudo.
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
