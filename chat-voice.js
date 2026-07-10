/**
 * VoiceType — shared mic → /api/transcribe → textarea
 *
 * VoiceType.bind({ id, micBtn, target, join, maxSeconds, onState, onTick, idleTitle })
 * VoiceType.toggle(id) / VoiceType.stop(id, runTranscribe) / VoiceType.isBusy()
 *
 * Compat: toggleChatVoice() / stopChatVoice() → id "chat"
 */
(function (w) {
  const sessions = Object.create(null);
  let activeId = null;

  function toast(msg) {
    if (typeof w.showToast === 'function') w.showToast(msg);
  }

  function el(ref) {
    if (!ref) return null;
    if (typeof ref === 'string') return document.querySelector(ref);
    return ref;
  }

  function pickMime() {
    if (typeof MediaRecorder === 'undefined') return '';
    const cands = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4', 'audio/ogg;codecs=opus'];
    for (let i = 0; i < cands.length; i++) {
      try {
        if (MediaRecorder.isTypeSupported(cands[i])) return cands[i];
      } catch (e) {}
    }
    return '';
  }

  function blobToBase64(blob) {
    return new Promise(function (resolve, reject) {
      const fr = new FileReader();
      fr.onload = function () {
        const s = String(fr.result || '');
        const i = s.indexOf(',');
        resolve(i >= 0 ? s.slice(i + 1) : s);
      };
      fr.onerror = function () {
        reject(fr.error || new Error('read_fail'));
      };
      fr.readAsDataURL(blob);
    });
  }

  function emit(s, state, extra) {
    s.state = state;
    const btn = el(s.micBtn);
    if (btn) {
      btn.classList.toggle('recording', state === 'recording');
      btn.classList.toggle('busy', state === 'busy');
      btn.disabled = state === 'busy';
      const title =
        state === 'recording'
          ? 'রেকর্ড বন্ধ করুন'
          : state === 'busy'
            ? 'ট্রান্সক্রিপশন হচ্ছে…'
            : s.idleTitle || 'ভয়েস লিখন';
      btn.title = title;
      btn.setAttribute('aria-label', title);
    }
    if (typeof s.onState === 'function') {
      try {
        s.onState(state, extra || {});
      } catch (e) {
        console.error(e);
      }
    }
  }

  function release(s) {
    if (s.stream) {
      try {
        s.stream.getTracks().forEach(function (t) {
          t.stop();
        });
      } catch (e) {}
      s.stream = null;
    }
  }

  function appendText(s, piece) {
    const inp = el(s.target);
    if (!inp || !piece) return false;
    const cur = (inp.value || '').trim();
    const join = s.join === 'newline' ? '\n' : ' ';
    if (!cur) inp.value = piece;
    else if (s.join === 'newline') inp.value = cur + '\n' + piece;
    else inp.value = cur + (cur.endsWith('\n') ? '' : join) + piece;
    if (typeof w.autoResize === 'function') w.autoResize(inp);
    try {
      inp.focus();
    } catch (e) {}
    if (typeof s.onAppend === 'function') s.onAppend(piece, inp);
    return true;
  }

  async function transcribe(s, blob) {
    s.busy = true;
    if (activeId === s.id) activeId = s.id;
    emit(s, 'busy');
    try {
      const audioBase64 = await blobToBase64(blob);
      const res = await fetch('/api/transcribe', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          audioBase64: audioBase64,
          mimeType: blob.type || s.mime || 'audio/webm',
        }),
      });
      const data = await res.json().catch(function () {
        return {};
      });
      if (!res.ok || !data.ok) throw new Error(data.error || 'HTTP ' + res.status);
      const piece = String(data.text || '').trim();
      if (piece) {
        appendText(s, piece);
        emit(s, 'ready', { text: piece });
      } else {
        const warning = data.warning || 'ট্রান্সক্রিপশন খালি';
        toast(warning);
        emit(s, 'idle', { warning: warning });
      }
    } catch (e) {
      console.error(e);
      toast(e.message || 'ট্রান্সক্রিপশন ব্যর্থ');
      emit(s, 'idle', { error: e.message || 'ট্রান্সক্রিপশন ব্যর্থ' });
    } finally {
      s.busy = false;
      if (activeId === s.id) activeId = null;
      if (s.state === 'busy') emit(s, 'idle');
    }
  }

  function stopSession(s, runTranscribe) {
    clearInterval(s.timer);
    s.timer = null;
    const was = s.recording;
    s.recording = false;
    const rec = s.recorder;
    s.recorder = null;
    if (!rec || rec.state === 'inactive') {
      release(s);
      if (!s.busy) {
        if (activeId === s.id) activeId = null;
        emit(s, 'idle');
      }
      return;
    }
    const finish = function () {
      release(s);
      const blob = new Blob(s.chunks, { type: s.mime || 'audio/webm' });
      s.chunks = [];
      if (runTranscribe && was && blob.size > 0) transcribe(s, blob);
      else {
        if (activeId === s.id) activeId = null;
        emit(s, 'idle');
      }
    };
    rec.onstop = finish;
    try {
      rec.stop();
    } catch (e) {
      finish();
    }
  }

  async function startSession(s) {
    if (s.recording || s.busy) return;
    if (activeId && activeId !== s.id) {
      toast('অন্য রেকর্ডিং চলছে');
      return;
    }
    if (
      !navigator.mediaDevices ||
      !navigator.mediaDevices.getUserMedia ||
      typeof MediaRecorder === 'undefined'
    ) {
      toast('মাইক রেকর্ডিং সমর্থিত নয়');
      emit(s, 'idle', { error: 'unsupported' });
      return;
    }
    s.mime = pickMime();
    let stream;
    try {
      stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch (e) {
      toast('মাইক অনুমতি পাওয়া যায়নি');
      emit(s, 'idle', { error: 'permission' });
      return;
    }
    s.stream = stream;
    s.chunks = [];
    try {
      s.recorder = s.mime
        ? new MediaRecorder(stream, { mimeType: s.mime })
        : new MediaRecorder(stream);
    } catch (e) {
      release(s);
      toast('রেকর্ডার শুরু হয়নি');
      emit(s, 'idle', { error: 'recorder' });
      return;
    }
    s.mime = s.recorder.mimeType || s.mime || 'audio/webm';
    s.recorder.ondataavailable = function (ev) {
      if (ev.data && ev.data.size > 0) s.chunks.push(ev.data);
    };
    s.recorder.onerror = function () {
      toast('রেকর্ডিং ত্রুটি');
      stopSession(s, false);
    };
    s.recording = true;
    activeId = s.id;
    s.left = s.maxSeconds || 120;
    try {
      s.recorder.start(250);
    } catch (e) {
      s.recording = false;
      activeId = null;
      release(s);
      s.recorder = null;
      toast('রেকর্ড শুরু হয়নি');
      emit(s, 'idle', { error: 'start' });
      return;
    }
    emit(s, 'recording');
    if (typeof s.onTick === 'function') s.onTick(s.left);
    clearInterval(s.timer);
    s.timer = setInterval(function () {
      s.left = Math.max(0, s.left - 1);
      if (typeof s.onTick === 'function') s.onTick(s.left);
      if (s.left <= 0) stopSession(s, true);
    }, 1000);
  }

  function bind(opts) {
    opts = opts || {};
    const id = opts.id || 'default';
    if (sessions[id] && sessions[id].recording) stopSession(sessions[id], false);
    const s = {
      id: id,
      micBtn: opts.micBtn,
      target: opts.target,
      join: opts.join === 'newline' ? 'newline' : 'space',
      maxSeconds: opts.maxSeconds || 120,
      idleTitle: opts.idleTitle || 'ভয়েস লিখন',
      onState: opts.onState,
      onTick: opts.onTick,
      onAppend: opts.onAppend,
      state: 'idle',
      recording: false,
      busy: false,
      timer: null,
      left: opts.maxSeconds || 120,
      recorder: null,
      chunks: [],
      stream: null,
      mime: '',
    };
    sessions[id] = s;
    emit(s, 'idle');
    return {
      id: id,
      toggle: function () {
        VoiceType.toggle(id);
      },
      stop: function (run) {
        VoiceType.stop(id, run);
      },
    };
  }

  const VoiceType = {
    bind: bind,
    toggle: function (id) {
      const s = sessions[id || 'chat'];
      if (!s) return;
      if (s.busy) return;
      if (s.recording) stopSession(s, true);
      else startSession(s);
    },
    stop: function (id, runTranscribe) {
      const s = sessions[id || 'chat'];
      if (!s) return;
      stopSession(s, !!runTranscribe);
    },
    isBusy: function () {
      for (const id in sessions) {
        if (sessions[id].recording || sessions[id].busy) return true;
      }
      return false;
    },
    getState: function (id) {
      const s = sessions[id];
      return s ? s.state : 'idle';
    },
  };

  w.VoiceType = VoiceType;

  function ensureChat() {
    if (!document.getElementById('chatMicBtn') || !document.getElementById('msgIn')) return;
    if (sessions.chat) return;
    bind({
      id: 'chat',
      micBtn: '#chatMicBtn',
      target: '#msgIn',
      join: 'space',
      idleTitle: 'ভয়েস লিখন',
    });
  }

  w.toggleChatVoice = function () {
    ensureChat();
    VoiceType.toggle('chat');
  };
  w.stopChatVoice = function (run) {
    ensureChat();
    VoiceType.stop('chat', run);
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', ensureChat);
  } else {
    ensureChat();
  }
})(window);
