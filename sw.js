/* Waqful Madinah — full-app shell cache + Web Push display */
var CACHE = 'waqful-full-v69';

var CDN_ASSETS = [
  'https://unpkg.com/@supabase/supabase-js@2.49.8/dist/umd/supabase.js',
  'https://cdn.jsdelivr.net/npm/jspdf@2.5.2/dist/jspdf.umd.min.js',
];

function baseHref() {
  var p = self.location.pathname;
  var i = p.lastIndexOf('/');
  return self.location.origin + (i <= 0 ? '/' : p.slice(0, i + 1));
}

function absLocal(path) {
  return new URL(path, baseHref()).href;
}

var LOCAL_SHELL = [
  'index.html',
  'teacher.html',
  'student.html',
  'style.css',
  'tablet-desktop.css',
  'api-amal.js',
  'api.js',
  'api-daily-schedule.js',
  'amal.css',
  'remote-sync-write.js',
  'remote-sync.js',
  'pdf-merge.js',
  'pwa-notify.js',
  'manifest.webmanifest',
  'icons/icon-192.png',
  'icons/icon-512.png',
  'supabase-config.js',
  'pwa-config.js',
].map(absLocal);

function precacheAll(cache) {
  var all = LOCAL_SHELL.concat(CDN_ASSETS);
  return Promise.all(
    all.map(function (url) {
      return cache.add(url).catch(function () {});
    })
  );
}

self.addEventListener('install', function (e) {
  e.waitUntil(
    caches.open(CACHE).then(function (cache) {
      return precacheAll(cache);
    })
  );
  self.skipWaiting();
});

self.addEventListener('activate', function (e) {
  e.waitUntil(
    caches.keys().then(function (keys) {
      return Promise.all(
        keys.map(function (k) {
          if (k !== CACHE) return caches.delete(k);
        })
      );
    }).then(function () {
      return self.clients.claim();
    })
  );
});

function sameOrigin(url) {
  return url.origin === self.location.origin;
}

self.addEventListener('fetch', function (e) {
  if (e.request.method !== 'GET') return;
  var url = new URL(e.request.url);
  if (e.request.mode === 'navigate') {
    e.respondWith(
      fetch(e.request)
        .then(function (res) {
          var copy = res.clone();
          if (res.ok && sameOrigin(url))
            caches.open(CACHE).then(function (c) {
              c.put(e.request, copy);
            });
          return res;
        })
        .catch(function () {
          return caches.match(e.request).then(function (hit) {
            if (hit) return hit;
            var path = url.pathname || '';
            var name = path.split('/').pop() || '';
            if (path === '/' || /index\.html$/i.test(path))
              return caches.match(absLocal('index.html'));
            if (/teacher\.html$/i.test(name)) return caches.match(absLocal('teacher.html'));
            if (/student\.html$/i.test(name)) return caches.match(absLocal('student.html'));
            return caches.match(absLocal('index.html'));
          });
        })
    );
    return;
  }

  if (!sameOrigin(url)) return;

  e.respondWith(
    fetch(e.request)
      .then(function (res) {
        if (res && res.ok) {
          var copy = res.clone();
          caches.open(CACHE).then(function (c) {
            c.put(e.request, copy);
          });
        }
        return res;
      })
      .catch(function () {
        return caches.match(e.request);
      })
  );
});

// ── Badge tracking via IndexedDB (persists across SW restarts) ────────────────
function _idbOpen() {
  return new Promise(function (res, rej) {
    var r = indexedDB.open('waqful-badge', 1);
    r.onupgradeneeded = function (e) { e.target.result.createObjectStore('counts'); };
    r.onsuccess = function (e) { res(e.target.result); };
    r.onerror = function () { rej(r.error); };
  });
}
function _idbGet(tag) {
  return _idbOpen().then(function (db) {
    return new Promise(function (res) {
      var tx = db.transaction('counts', 'readonly');
      var req = tx.objectStore('counts').get(tag);
      req.onsuccess = function () { res(req.result || 0); };
      req.onerror = function () { res(0); };
    });
  }).catch(function () { return 0; });
}
function _idbSet(tag, n) {
  return _idbOpen().then(function (db) {
    return new Promise(function (res) {
      var tx = db.transaction('counts', 'readwrite');
      var store = tx.objectStore('counts');
      if (n <= 0) store.delete(tag); else store.put(n, tag);
      tx.oncomplete = function () { res(); };
      tx.onerror = function () { res(); };
    });
  }).catch(function () {});
}
function _idbTotal() {
  return _idbOpen().then(function (db) {
    return new Promise(function (res) {
      var tx = db.transaction('counts', 'readonly');
      var req = tx.objectStore('counts').getAll();
      req.onsuccess = function () {
        var total = (req.result || []).reduce(function (s, n) { return s + n; }, 0);
        res(total);
      };
      req.onerror = function () { res(0); };
    });
  }).catch(function () { return 0; });
}
function _idbClear() {
  return _idbOpen().then(function (db) {
    return new Promise(function (res) {
      var tx = db.transaction('counts', 'readwrite');
      tx.objectStore('counts').clear();
      tx.oncomplete = function () { res(); };
      tx.onerror = function () { res(); };
    });
  }).catch(function () {});
}

// ── Push notification ─────────────────────────────────────────────────────────
self.addEventListener('push', function (e) {
  var title = 'Waqful Madinah';
  var body = 'নতুন আপডেট আছে।';
  var openUrl = absLocal('index.html');
  var tag = 'waqful-push';
  if (e.data) {
    try {
      var j = e.data.json();
      if (j.title) title = j.title;
      if (j.body) body = j.body;
      if (j.url) openUrl = new URL(j.url, baseHref()).href;
      if (j.tag) tag = j.tag;
    } catch (err) {
      var t = e.data.text();
      if (t) body = t.slice(0, 200);
    }
  }
  var _body = body;
  var _tag = tag;
  e.waitUntil(
    _idbGet(_tag).then(function (prev) {
      var tagCount = prev + 1;
      return _idbSet(_tag, tagCount).then(function () {
        return _idbTotal();
      }).then(function (total) {
        // Show count in body when multiple messages from same sender
        var displayBody = tagCount > 1
          ? _body + ' (' + tagCount + 'টি নতুন)'
          : _body;
        return self.registration.showNotification(title, {
          body: displayBody,
          icon: absLocal('icons/icon-192.png'),
          badge: absLocal('icons/icon-192.png'),
          tag: _tag,
          renotify: true,
          silent: false,
          vibrate: [200, 100, 200],
          data: { url: openUrl, tag: _tag },
        }).then(function () {
          if ('setAppBadge' in navigator) navigator.setAppBadge(total);
          // Tell any open page to refresh data immediately
          return self.clients.matchAll({ type: 'window', includeUncontrolled: true })
            .then(function (clients) {
              clients.forEach(function (c) { c.postMessage({ type: 'REFRESH_DATA' }); });
            });
        });
      });
    })
  );
});

// ── Notification click ────────────────────────────────────────────────────────
self.addEventListener('notificationclick', function (e) {
  e.notification.close();
  var clickedTag = (e.notification.data && e.notification.data.tag) || e.notification.tag;
  var url = (e.notification.data && e.notification.data.url) || absLocal('index.html');
  e.waitUntil(
    _idbSet(clickedTag, 0).then(function () {
      return _idbTotal();
    }).then(function (remaining) {
      if ('setAppBadge' in navigator) {
        return remaining > 0 ? navigator.setAppBadge(remaining) : navigator.clearAppBadge();
      }
    }).then(function () {
      return self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    }).then(function (list) {
      for (var i = 0; i < list.length; i++) {
        var c = list[i];
        if (c.url && 'focus' in c) {
          return c.focus().then(function (fc) {
            if (fc) fc.postMessage({ type: 'REFRESH_DATA' });
          });
        }
      }
      if (self.clients.openWindow) return self.clients.openWindow(url);
    })
  );
});

// ── Message from page ─────────────────────────────────────────────────────────
self.addEventListener('message', function (e) {
  if (!e.data) return;
  if (e.data.type === 'CLEAR_BADGE') {
    _idbClear().then(function () {
      if ('clearAppBadge' in navigator) navigator.clearAppBadge();
    });
  }
  // Page থেকে force-activate অনুরোধ এলে নতুন SW সক্রিয় করো
  if (e.data.type === 'SKIP_WAITING') {
    self.skipWaiting();
  }
  // মেসেজ পড়া হলে OS notification বন্ধ করো
  if (e.data && e.data.type === 'CLEAR_NOTIFICATION' && e.data.tag) {
    self.registration.getNotifications({ tag: e.data.tag }).then(function(list) {
      list.forEach(function(n) { n.close(); });
    });
    _idbSet(e.data.tag, 0).then(function() {
      return _idbTotal();
    }).then(function(total) {
      if (total > 0) navigator.setAppBadge && navigator.setAppBadge(total);
      else navigator.clearAppBadge && navigator.clearAppBadge();
    });
  }
});
