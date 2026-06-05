/* Waqful Madinah — PWA: SW registration, Web Push subscribe */
(function (w) {

  function urlB64ToUint8Array(base64String) {
    var padLen = (4 - (base64String.length % 4)) % 4;
    var padding = '';
    for (var p = 0; p < padLen; p++) padding += '=';
    var base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/');
    var raw = atob(base64);
    var out = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; ++i) out[i] = raw.charCodeAt(i);
    return out;
  }

  // আপডেট banner দেখানো
  function _showUpdateBanner(onReload) {
    var existing = document.getElementById('_swUpdateBanner');
    if (existing) return;
    var bar = document.createElement('div');
    bar.id = '_swUpdateBanner';
    bar.style.cssText = [
      'position:fixed', 'bottom:0', 'left:0', 'right:0', 'z-index:99999',
      'background:#1B5E20', 'color:#fff', 'padding:14px 16px',
      'display:flex', 'align-items:center', 'justify-content:space-between',
      'gap:12px', 'font-family:inherit', 'font-size:14px',
      'box-shadow:0 -2px 12px rgba(0,0,0,.25)', 'animation:_swSlideUp .3s ease',
    ].join(';');
    bar.innerHTML = '<span>🔄 নতুন আপডেট পাওয়া গেছে</span>'
      + '<button id="_swReloadBtn" style="background:#fff;color:#1B5E20;border:none;'
      + 'border-radius:20px;padding:7px 18px;font-weight:700;font-size:13px;cursor:pointer;'
      + 'font-family:inherit;flex-shrink:0">আপডেট করুন</button>';
    if (!document.getElementById('_swUpdateAnim')) {
      var st = document.createElement('style');
      st.id = '_swUpdateAnim';
      st.textContent = '@keyframes _swSlideUp{from{transform:translateY(100%)}to{transform:translateY(0)}}';
      document.head.appendChild(st);
    }
    document.body.appendChild(bar);
    document.getElementById('_swReloadBtn').addEventListener('click', function () {
      bar.remove();
      onReload();
    });
  }

  function register() {
    if (!('serviceWorker' in navigator)) return Promise.resolve(null);
    return navigator.serviceWorker.register('sw.js').then(function (reg) {
      if (!reg) return null;

      // waiting SW-কে activate করো এবং banner দেখাও
      function handleWaiting() {
        if (!reg.waiting) return;
        _showUpdateBanner(function () {
          reg.waiting.postMessage({ type: 'SKIP_WAITING' });
        });
      }

      // Install শেষ হলে check করো
      function onUpdateFound() {
        var newWorker = reg.installing;
        if (!newWorker) return;
        newWorker.addEventListener('statechange', function () {
          if (newWorker.state === 'installed' && navigator.serviceWorker.controller) {
            handleWaiting();
          }
        });
      }

      // Page load-এ already waiting SW আছে কিনা
      if (reg.waiting && navigator.serviceWorker.controller) {
        handleWaiting();
      }

      reg.addEventListener('updatefound', onUpdateFound);

      // SW activate হলে reload
      var reloading = false;
      navigator.serviceWorker.addEventListener('controllerchange', function () {
        if (reloading) return;
        reloading = true;
        w.location.reload();
      });

      // App foreground-এ এলে update check
      document.addEventListener('visibilitychange', function () {
        if (document.visibilityState === 'visible') {
          reg.update().catch(function () {});
        }
      });

      return reg;
    }).catch(function () {
      return null;
    });
  }

  function saveSubscriptionToRemote(role, studentWaqf, subJson) {
    var id = role === 'teacher' ? 'teacher' : (studentWaqf ? String(studentWaqf) : null);
    if (!id) return Promise.resolve(false);
    var sb = getSupabaseClient();
    if (!sb) return Promise.resolve(false);
    return sb.rpc('madrasa_rel_save_pwa_subscription', {
      p_id: id,
      p_role: role,
      p_subscription: subJson,
    }).then(function (res) {
      if (res.error) { console.warn('MadrasaPwa sub save:', res.error); return false; }
      return true;
    }).catch(function (e) {
      console.warn('MadrasaPwa sub save exception:', e);
      return false;
    });
  }

  function getSupabaseClient() {
    // Prefer RemoteSync's existing client to avoid creating duplicates
    var RS = w.RemoteSync;
    if (RS && RS.getClient) {
      var c = RS.getClient();
      if (c) return c;
    }
    // Fall back: build a minimal client directly from window globals
    var url = w.SUPABASE_URL;
    var key = w.SUPABASE_ANON_KEY;
    var create = (w.supabase && w.supabase.createClient) || (w.supabaseJs && w.supabaseJs.createClient);
    if (url && key && create) return create(url, key);
    return null;
  }

  async function saveSharedSubscription(subJson, role, idOverride) {
    var sb = getSupabaseClient();
    if (!sb) return false;
    try {
      var res = await sb.rpc('madrasa_rel_save_pwa_subscription', {
        p_id: idOverride,
        p_role: role,
        p_subscription: subJson,
      });
      if (res.error) { console.warn('MadrasaPwa shared sub save:', res.error); return false; }
      console.log('MadrasaPwa: shared device subscribed as', idOverride);
      return true;
    } catch (e) {
      console.warn('MadrasaPwa shared sub save exception:', e);
      return false;
    }
  }

  async function subscribeToPush(role, idOverride) {
    if (!('Notification' in w)) return;
    await register();
    var reg = await navigator.serviceWorker.ready;
    var perm = Notification.permission;
    if (perm === 'default') perm = await Notification.requestPermission();
    if (perm !== 'granted') return;

    var vapid = w.__PWA_VAPID_PUBLIC_KEY__;
    if (!vapid || typeof vapid !== 'string' || !vapid.trim()) return;

    try {
      var sub = await reg.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlB64ToUint8Array(vapid.trim()),
      });
      var subJson = sub.toJSON();
      if (idOverride) {
        var saved = await saveSharedSubscription(subJson, role, idOverride);
        if (!saved) {
          // RemoteSync not ready yet — retry on first sync event OR after 8s
          var _retried = false;
          async function _retrySave() {
            if (_retried) return;
            _retried = true;
            w.removeEventListener('madrasa-remote-sync', _retrySave);
            await saveSharedSubscription(subJson, role, idOverride);
          }
          w.addEventListener('madrasa-remote-sync', _retrySave);
          setTimeout(async function() {
            if (!_retried) await _retrySave();
          }, 8000);
        }
      } else {
        await saveSubscriptionToRemote(role, null, subJson);
      }
    } catch (err) {
      console.warn('MadrasaPwa push subscribe:', err);
    }
  }

  async function subscribeAndSave(role, opts, requestPermission) {
    opts = opts || {};
    if (!('Notification' in w)) return false;
    await register();
    var perm = Notification.permission;
    if (perm === 'default' && requestPermission) perm = await Notification.requestPermission();
    if (perm !== 'granted') return false;

    var vapid = w.__PWA_VAPID_PUBLIC_KEY__;
    if (!vapid || typeof vapid !== 'string' || !vapid.trim()) return false;

    try {
      var reg = await navigator.serviceWorker.ready;
      var sub = await reg.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: urlB64ToUint8Array(vapid.trim()),
      });
      var subJson = sub.toJSON();
      var saved = await saveSubscriptionToRemote(role, opts.waqfId, subJson);
      if (!saved) {
        var _retried = false;
        async function _retrySave() {
          if (_retried) return;
          _retried = true;
          w.removeEventListener('madrasa-remote-sync', _retrySave);
          await saveSubscriptionToRemote(role, opts.waqfId, subJson);
        }
        w.addEventListener('madrasa-remote-sync', _retrySave);
        setTimeout(function () { if (!_retried) _retrySave(); }, 8000);
      }
      return true;
    } catch (err) {
      console.warn('MadrasaPwa push subscribe:', err);
      return false;
    }
  }

  async function enableAfterAuth(role, opts) {
    return subscribeAndSave(role, opts, true);
  }

  async function refreshPushSubscription(role, opts) {
    return subscribeAndSave(role, opts, false);
  }

  // Each physical device gets a unique stable ID stored in localStorage
  // Format: shared_device_XXXXXXXX (8 hex chars)
  function getOrCreateSharedDeviceId() {
    var key = 'madrasa_shared_device_id';
    var id = null;
    try { id = localStorage.getItem(key); } catch(e) {}
    if (!id) {
      var arr = new Uint8Array(4);
      crypto.getRandomValues(arr);
      id = 'shared_device_' + Array.from(arr).map(function(b){ return b.toString(16).padStart(2,'0'); }).join('');
      try { localStorage.setItem(key, id); } catch(e) {}
    }
    return id;
  }

  // Call this when student panel is first opened (before login)
  // Each device subscribes with its own unique ID so multiple shared devices all get notifications
  async function enableSharedStudentDevice() {
    var deviceId = getOrCreateSharedDeviceId();
    await subscribeToPush('student', deviceId);
  }

  // Expose device ID so Edge Function lookup works
  function getSharedDeviceId() { return getOrCreateSharedDeviceId(); }

  w.MadrasaPwa = {
    register: register,
    enableAfterAuth: enableAfterAuth,
    refreshPushSubscription: refreshPushSubscription,
    enableSharedStudentDevice: enableSharedStudentDevice,
    getSharedDeviceId: getSharedDeviceId,
  };
})(typeof window !== 'undefined' ? window : globalThis);
