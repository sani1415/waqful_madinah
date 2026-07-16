/* Waqful Madinah — full-app shell cache + Web Push display */
var CACHE = 'waqful-full-v185';

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
  'teacher/',
  'student.html',
  'student/',
  'style.css',
  'tablet-desktop.css',
  'api-amal.js',
  'api.js',
  'api-daily-schedule.js',
  'api-student-notes.js',
  'chat-voice.js',
  'amal.css',
  'remote-sync-write.js',
  'remote-sync.js',
  'pdf-merge.js',
  'pwa-notify.js',
  'manifest-teacher.webmanifest',
  'manifest-student.webmanifest',
  'icons/icon-teacher-192.png',
  'icons/icon-teacher-512.png',
  'icons/icon-student-192.png',
  'icons/icon-student-512.png',
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
            if (/\/teacher\/?$/i.test(path) || /teacher\.html$/i.test(name))
              return caches.match(absLocal('teacher.html'));
            if (/\/student\/?$/i.test(path) || /student\.html$/i.test(name))
              return caches.match(absLocal('student.html'));
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

function setBadgeCount(n) {
  var count = Math.max(0, Number(n) || 0);
  try {
    if (count > 0) {
      if (self.registration && self.registration.setAppBadge) return self.registration.setAppBadge(count);
      if (self.navigator && self.navigator.setAppBadge) return self.navigator.setAppBadge(count);
    } else {
      if (self.registration && self.registration.clearAppBadge) return self.registration.clearAppBadge();
      if (self.navigator && self.navigator.clearAppBadge) return self.navigator.clearAppBadge();
    }
  } catch (e) {}
  return Promise.resolve();
}

// ── Push notification ─────────────────────────────────────────────────────────
self.addEventListener('push', function (e) {
  var title = 'Waqful Madinah';
  var body = 'নতুন আপডেট আছে।';
  var openUrl = absLocal('index.html');
  var tag = 'waqful-push';
  var iconPath = 'icons/icon-student-192.png';
  if (e.data) {
    try {
      var j = e.data.json();
      if (j.title) title = j.title;
      if (j.body) body = j.body;
      if (j.url) openUrl = new URL(j.url, baseHref()).href;
      if (j.tag) tag = j.tag;
      if (j.icon) iconPath = j.icon;
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
          icon: absLocal(iconPath),
          badge: absLocal(iconPath),
          tag: _tag,
          renotify: true,
          silent: false,
          vibrate: [200, 100, 200],
          data: { url: openUrl, tag: _tag },
        }).then(function () {
          setBadgeCount(total);
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
  var targetUrl = new URL(url, self.location.origin).href;
  e.waitUntil(
    _idbSet(clickedTag, 0).then(function () {
      return _idbTotal();
    }).then(function (remaining) {
      return setBadgeCount(remaining);
    }).then(function () {
      return self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    }).then(function (list) {
      for (var j = 0; j < list.length; j++) {
        var tc = list[j];
        if (tc.url && tc.url.indexOf(targetUrl) === 0 && 'focus' in tc) {
          return tc.focus().then(function (fc) {
            if (fc) fc.postMessage({ type: 'REFRESH_DATA' });
          });
        }
      }
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
      setBadgeCount(0);
    });
  }
  if (e.data.type === 'SET_BADGE') {
    setBadgeCount(e.data.count);
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
      setBadgeCount(total);
    });
  }
});
