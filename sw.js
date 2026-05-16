// 최강전기 PWA Service Worker
// 정적 리소스만 캐시 - Supabase/Cloudinary 등 외부 API는 네트워크 우선
const VERSION = 'v1.0.0';
const STATIC_CACHE = `choigang-static-${VERSION}`;
const RUNTIME_CACHE = `choigang-runtime-${VERSION}`;

const PRECACHE_URLS = [
  './',
  './index.html',
  './manifest.json',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/icon.svg',
  './icons/apple-touch-icon.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(STATIC_CACHE)
      .then((cache) => cache.addAll(PRECACHE_URLS).catch(() => {}))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys
          .filter((k) => k !== STATIC_CACHE && k !== RUNTIME_CACHE)
          .map((k) => caches.delete(k))
      )
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;

  const url = new URL(req.url);

  // 외부 API/실시간 데이터: 네트워크 우선, 실패 시 캐시
  const isApi =
    url.hostname.includes('supabase.co') ||
    url.hostname.includes('googleapis.com');

  if (isApi) {
    event.respondWith(
      fetch(req)
        .then((res) => {
          const copy = res.clone();
          caches.open(RUNTIME_CACHE).then((c) => c.put(req, copy)).catch(() => {});
          return res;
        })
        .catch(() => caches.match(req))
    );
    return;
  }

  // 이미지/폰트/CDN: 캐시 우선, 백그라운드 갱신 (stale-while-revalidate)
  const isAsset =
    req.destination === 'image' ||
    req.destination === 'font' ||
    req.destination === 'style' ||
    req.destination === 'script' ||
    url.hostname.includes('cloudinary.com') ||
    url.hostname.includes('jsdelivr.net') ||
    url.hostname.includes('fonts.g');

  if (isAsset) {
    event.respondWith(
      caches.match(req).then((cached) => {
        const fetchPromise = fetch(req).then((res) => {
          const copy = res.clone();
          caches.open(RUNTIME_CACHE).then((c) => c.put(req, copy)).catch(() => {});
          return res;
        }).catch(() => cached);
        return cached || fetchPromise;
      })
    );
    return;
  }

  // HTML 문서: 네트워크 우선, 실패 시 캐시된 index.html
  if (req.mode === 'navigate' || req.destination === 'document') {
    event.respondWith(
      fetch(req)
        .then((res) => {
          const copy = res.clone();
          caches.open(STATIC_CACHE).then((c) => c.put(req, copy)).catch(() => {});
          return res;
        })
        .catch(() => caches.match(req).then((r) => r || caches.match('./index.html')))
    );
    return;
  }
});

self.addEventListener('message', (event) => {
  if (event.data === 'SKIP_WAITING') self.skipWaiting();
});

// ===== Web Push =====
self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (_) {
    data = { title: '최강전기', body: event.data ? event.data.text() : '' };
  }
  const title = data.title || '최강전기';
  const options = {
    body: data.body || '',
    icon: data.icon || './icons/icon-192.png',
    badge: data.badge || './icons/icon-192.png',
    tag: data.tag || 'choigang-default',
    renotify: data.renotify ?? true,
    requireInteraction: data.requireInteraction ?? false,
    vibrate: [80, 40, 80],
    data: {
      url: data.url || './',
      sessionId: data.sessionId || null,
    },
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const targetUrl = (event.notification.data && event.notification.data.url) || './';
  event.waitUntil((async () => {
    const allClients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of allClients) {
      if ('focus' in c) {
        c.navigate(targetUrl).catch(() => {});
        return c.focus();
      }
    }
    if (self.clients.openWindow) return self.clients.openWindow(targetUrl);
  })());
});

// 구독 만료 시 자동 재구독 (브라우저가 주기적으로 갱신)
self.addEventListener('pushsubscriptionchange', (event) => {
  event.waitUntil((async () => {
    try {
      const sub = await self.registration.pushManager.subscribe(
        event.oldSubscription?.options || { userVisibleOnly: true }
      );
      // 클라이언트에 알려서 Supabase에 다시 저장하도록
      const allClients = await self.clients.matchAll();
      allClients.forEach((c) => c.postMessage({ type: 'PUSH_RESUBSCRIBED', subscription: sub.toJSON() }));
    } catch (_) {}
  })());
});
