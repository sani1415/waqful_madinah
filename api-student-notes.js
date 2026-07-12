/* Waqful Madinah — ছাত্র বিবরণ নোট + ক্যাটাগরি (API.StudentNotes) */
(function (w) {
  const LS_NOTES = 'madrasa_student_notes_v1';
  const LS_CATS = 'madrasa_student_note_cats_v1';
  const DEFAULT_CATS = [
    { id: 'general', label: 'সাধারণ', sort: 0 },
    { id: 'matbakh', label: 'মাতবাখের দরস', sort: 1 },
    { id: 'tajriba', label: 'তাজেরেবা', sort: 2 },
  ];

  function _remote() {
    return !!(w.RemoteSync && w.RemoteSync.isRemote && w.RemoteSync.isRemote());
  }
  function _RS() { return w.RemoteSync || null; }
  function _uid(p) {
    return (p || 'sn') + Date.now() + Math.random().toString(36).slice(2, 5);
  }
  function _today() {
    return w.API && w.API.today ? w.API.today() : new Date().toISOString().slice(0, 10);
  }
  function _nowTime() {
    return w.API && w.API.nowTime
      ? w.API.nowTime()
      : (() => {
          const d = new Date();
          return String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
        })();
  }

  function _normCat(c, i) {
    return {
      id: String(c.id || ''),
      label: String(c.label || c.name || ''),
      sort: typeof c.sort === 'number' ? c.sort : (typeof c.sort_order === 'number' ? c.sort_order : i),
    };
  }
  function _normNote(n) {
    return {
      id: String(n.id || ''),
      studentId: String(n.studentId || n.student_id || ''),
      categoryId: String(n.categoryId || n.category_id || 'general') || 'general',
      date: String(n.date || n.note_date || ''),
      time: String(n.time || n.note_time || ''),
      title: String(n.title || ''),
      text: String(n.text || ''),
    };
  }

  function _readCatsLS() {
    try {
      const raw = JSON.parse(localStorage.getItem(LS_CATS) || 'null');
      if (Array.isArray(raw) && raw.length) return raw.map(_normCat);
    } catch (e) {}
    return DEFAULT_CATS.map(c => ({ ...c }));
  }
  function _writeCatsLS(arr) {
    localStorage.setItem(LS_CATS, JSON.stringify(arr || []));
  }
  function _readNotesLS() {
    try { return JSON.parse(localStorage.getItem(LS_NOTES) || '{}') || {}; } catch (e) { return {}; }
  }
  function _writeNotesLS(map) {
    localStorage.setItem(LS_NOTES, JSON.stringify(map || {}));
  }

  function _patchLocal(sid, note) {
    const map = _readNotesLS();
    const list = Array.isArray(map[sid]) ? map[sid] : [];
    const ix = list.findIndex(n => n.id === note.id);
    if (ix >= 0) list[ix] = note; else list.unshift(note);
    map[sid] = list;
    _writeNotesLS(map);
  }

  const StudentNotes = {
    DEFAULT_CATS: DEFAULT_CATS.map(c => ({ ...c })),

    getCategories() {
      if (_remote()) {
        const RS = _RS();
        const list = (RS.mem && RS.mem.noteCategories) || [];
        if (list.length) return list.map(_normCat).sort((a, b) => a.sort - b.sort);
      }
      return _readCatsLS().sort((a, b) => a.sort - b.sort);
    },

    catLabel(id) {
      const c = this.getCategories().find(x => x.id === id);
      return c ? c.label : (id === 'general' ? 'সাধারণ' : id || 'সাধারণ');
    },

    async upsertCategory(cat) {
      const id = String(cat.id || _uid('nc'));
      const label = String(cat.label || '').trim();
      if (!label) throw new Error('empty_label');
      const next = _normCat({ id, label, sort: cat.sort });
      if (_remote() && _RS().upsertNoteCategoryRemote) {
        await _RS().upsertNoteCategoryRemote(next);
        return next;
      }
      const arr = _readCatsLS();
      const ix = arr.findIndex(x => x.id === id);
      if (ix >= 0) arr[ix] = { ...arr[ix], ...next };
      else {
        next.sort = typeof next.sort === 'number' ? next.sort : arr.length;
        arr.push(next);
      }
      _writeCatsLS(arr);
      return next;
    },

    async deleteCategory(id) {
      if (id === 'general') throw new Error('cannot_delete_default');
      if (_remote() && _RS().deleteNoteCategoryRemote) {
        await _RS().deleteNoteCategoryRemote(id);
        return;
      }
      _writeCatsLS(_readCatsLS().filter(c => c.id !== id));
      const map = _readNotesLS();
      Object.keys(map).forEach(sid => {
        map[sid] = (map[sid] || []).map(n =>
          n.categoryId === id ? { ...n, categoryId: 'general' } : n
        );
      });
      _writeNotesLS(map);
    },

    getAll(sid) {
      if (!sid) return [];
      if (_remote()) {
        const RS = _RS();
        const by = (RS.mem && RS.mem.studentNotesByStudent) || {};
        return (by[sid] || []).map(_normNote);
      }
      const all = _readNotesLS();
      return (Array.isArray(all[sid]) ? all[sid] : []).map(_normNote);
    },

    get(sid, noteId) {
      return this.getAll(sid).find(n => n.id === noteId) || null;
    },

    async add(sid, { text, title, categoryId }) {
      const note = {
        id: _uid('sn'),
        studentId: sid,
        categoryId: categoryId || 'general',
        date: _today(),
        time: _nowTime(),
        title: String(title || '').trim(),
        text: String(text || '').trim(),
      };
      if (!note.text) throw new Error('empty');
      if (_remote()) {
        if (!_RS() || !_RS().upsertStudentNoteRemote) throw new Error('note_save_unavailable');
        await _RS().upsertStudentNoteRemote(note, sid);
        return note;
      }
      _patchLocal(sid, note);
      return note;
    },

    async update(sid, noteId, { text, title, categoryId }) {
      const prev = this.get(sid, noteId);
      if (!prev) throw new Error('not_found');
      const note = {
        ...prev,
        categoryId: categoryId || prev.categoryId || 'general',
        time: _nowTime(),
        title: title != null ? String(title).trim() : String(prev.title || '').trim(),
        text: String(text || '').trim(),
      };
      if (!note.text) throw new Error('empty');
      if (_remote()) {
        if (!_RS() || !_RS().upsertStudentNoteRemote) throw new Error('note_save_unavailable');
        await _RS().upsertStudentNoteRemote(note, sid);
        return note;
      }
      _patchLocal(sid, note);
      return note;
    },

    async delete(sid, noteId) {
      if (_remote()) {
        if (!_RS() || !_RS().deleteStudentNoteRemote) throw new Error('note_delete_unavailable');
        await _RS().deleteStudentNoteRemote(sid, noteId);
        return;
      }
      const map = _readNotesLS();
      map[sid] = (map[sid] || []).filter(n => n.id !== noteId);
      _writeNotesLS(map);
    },
  };

  if (!w.API) w.API = {};
  w.API.StudentNotes = StudentNotes;
})(typeof window !== 'undefined' ? window : globalThis);
