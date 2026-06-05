/* Waqful Madinah · api.js — সব ডেটা লজিক এখানে। LocalStorage বা remote-sync + supabase-config। */
const API = (() => {
  const DB_KEY='madrasa_db', GOALS_KEY='madrasa_goals',
        EXAMS_KEY='madrasa_exams', DOCS_KEY='madrasa_docs',
        T_PIN_KEY='teacher_pin', DEF_PIN='1234';

  const _useRemote = typeof window !== 'undefined' && window.RemoteSync && window.RemoteSync.isRemote();
  const RS = typeof window !== 'undefined' ? window.RemoteSync : null;

  const today  = () => new Date().toISOString().split('T')[0];
  const nowTime= () => { const d=new Date(); return `${String(d.getHours()).padStart(2,'0')}:${String(d.getMinutes()).padStart(2,'0')}`; };
  const nextDate= d => { const dt=new Date(); dt.setDate(dt.getDate()+d); return dt.toISOString().split('T')[0]; };
  const uid    = p => (p||'id')+Date.now()+Math.random().toString(36).slice(2,5);
  const safeFilePart = name => String(name||'file').replace(/[^a-zA-Z0-9._-]/g,'_').slice(0,80);
  /** একক আপলোড সর্বোচ্চ আকার (রিমোট: Supabase Storage; মেটা `docs_meta` এ KV তে) */
  const MAX_UPLOAD_BYTES = 10 * 1024 * 1024;

  function fileWithinUploadLimit(file) {
    return file && typeof file.size === 'number' && file.size > 0 && file.size <= MAX_UPLOAD_BYTES;
  }

  function looksLikeImageFile(f) {
    if (f.type && f.type.startsWith('image/')) return true;
    return /\.(jpe?g|png|gif|webp|bmp)$/i.test(f.name || '');
  }

  async function prepareFilesForUpload(fileList) {
    const files = Array.from(fileList || []).filter(Boolean);
    if (!files.length) throw new Error('no_file');
    for (const f of files) {
      if (!fileWithinUploadLimit(f)) throw new Error('file_too_large');
    }
    if (files.length === 1) return files[0];
    const allImg = files.every(looksLikeImageFile);
    if (!allImg) throw new Error('mixed_or_non_image');
    const merger = typeof window !== 'undefined' && window.mergeImageFilesToPdf;
    if (!merger) throw new Error('pdf_lib_missing');
    const pdf = await merger(files);
    if (!fileWithinUploadLimit(pdf)) throw new Error('file_too_large');
    return pdf;
  }

  function ensureChatsShape(db) {
    if (!db.chats) db.chats = {};
    (db.students || []).forEach(s => { if (!db.chats[s.id]) db.chats[s.id] = []; });
    if (!db.chats._bc) db.chats._bc = [];
  }

  const readDB = () => {
    if (_useRemote) return RS.mem.core;
    try { return JSON.parse(localStorage.getItem(DB_KEY))||null; } catch { return null; }
  };
  // Stamps _notifyAt on db so the Edge Function knows this write contains a new chat message.
  // Call only when a message is actually sent — NOT for markRead, task completions, or resets.
  function stampNotify(db) { db._notifyAt = new Date().toISOString(); }

  const writeDB = db => {
    if (_useRemote) {
      RS.mem.core = db;
      RS.schedule('core', () => JSON.parse(JSON.stringify(RS.mem.core)));
      return;
    }
    localStorage.setItem(DB_KEY, JSON.stringify(db));
  };

  // ── Seed ──────────────────────────────────────────────────
  function buildSeedDemo() {
    const colors=['#128C7E','#1565C0','#6A1B9A','#BF360C','#1B5E20'];
    return {
      teacher: { name:'উস্তাজ', madrasa:'Waqful Madinah' },
      students: [
        { id:'s1', waqfId:'waqf_001', name:'মুহাম্মাদ রাফি',      cls:'হিফজ ১ম',   roll:'০১', note:'',  color:colors[0], pin:'1111', fatherName:'আব্দুর রহমান',   contact:'01711000001', enrollmentDate:'2024-01-10' },
        { id:'s2', waqfId:'waqf_002', name:'আব্দুল্লাহ মাহমুদ',   cls:'হিফজ ১ম',   roll:'০২', note:'',  color:colors[1], pin:'2222', fatherName:'মোহাম্মদ হানিফ', contact:'01711000002', enrollmentDate:'2024-01-10' },
        { id:'s3', waqfId:'waqf_003', name:'উমর ফারুক',           cls:'হিফজ ২য়',   roll:'০৩', note:'',  color:colors[2], pin:'3333', fatherName:'ইব্রাহীম খলিল', contact:'01711000003', enrollmentDate:'2024-03-05' },
        { id:'s4', waqfId:'waqf_004', name:'ইয়াহইয়া নাদিম',      cls:'নাজেরা ১ম', roll:'০৪', note:'',  color:colors[3], pin:'4444', fatherName:'সালেহ আহমাদ',   contact:'01711000004', enrollmentDate:'2024-06-01' },
        { id:'s5', waqfId:'waqf_005', name:'হামজা আব্দুল আজিজ',  cls:'নাজেরা ২য়', roll:'০৫', note:'',  color:colors[4], pin:'5555', fatherName:'জামালুদ্দিন',   contact:'01711000005', enrollmentDate:'2025-01-15' },
      ],
      chats: {
        's1': [{ id:uid('m'), role:'out', text:'আস-সালামু আলাইকুম রাফি! আজকের সবক তৈরি করো।', time:nowTime(), read:false, type:'text' }],
      },
      tasks: [],
    };
  }
  function seedDemo() {
    const db = buildSeedDemo();
    writeDB(db);
    return db;
  }

  // ── AUTH ──────────────────────────────────────────────────
  const Auth = {
    getTeacherPin() {
      if (_useRemote) return RS.mem.teacherPin || DEF_PIN;
      return localStorage.getItem(T_PIN_KEY)||DEF_PIN;
    },
    setTeacherPin(p) {
      if (_useRemote) {
        RS.mem.teacherPin = p;
        RS.schedule('teacher_pin', () => ({ pin: RS.mem.teacherPin || '' }));
        return;
      }
      localStorage.setItem(T_PIN_KEY, p);
    },
    checkTeacherPin(p)  { return p === this.getTeacherPin(); },
  };

  // ── DB ────────────────────────────────────────────────────
  const DB = {
    init() {
      if (!_useRemote) {
        let db=readDB();
        if(!db||!db.students?.length) db=seedDemo();
        else ensureChatsShape(db);
        Tasks.syncTodayFromCompletions();
        return Promise.resolve(db);
      }
      return RS.bootstrap().then(async () => {
        if (RS.startRealtimeSync) RS.startRealtimeSync();
        let c = RS.mem.core;
        const secure = RS.usesSecureKv?.();
        if (secure) {
          ensureChatsShape(c);
          Tasks.syncTodayFromCompletions();
          return c;
        }
        const needSeed = !c || (!c.students?.length && !c.allowEmptyStudents);
        if (needSeed) {
          c = buildSeedDemo();
          ensureChatsShape(c);
          RS.mem.core = c;
          await RS.flushKey('core', c);
        } else {
          ensureChatsShape(c);
        }
        if (RS.mem.teacherPin == null || RS.mem.teacherPin === '') {
          RS.mem.teacherPin = DEF_PIN;
          await RS.flushKey('teacher_pin', { pin: DEF_PIN });
        }
        Tasks.syncTodayFromCompletions();
        return c;
      });
    },
    get() {
      if (_useRemote) {
        if (!RS.mem.loaded || !RS.mem.core) throw new Error('API not ready — await API.DB.init()');
        return RS.mem.core;
      }
      let db=readDB();
      if(!db) db=seedDemo();
      else if(!db.students?.length && !db.allowEmptyStudents) db=seedDemo();
      else ensureChatsShape(db);
      return db;
    },
    save(db)        { writeDB(db); },
    getTeacher()    { return this.get().teacher; },
    saveTeacher(data){ const db=this.get(); db.teacher={...db.teacher,...data}; this.save(db); },
    exportJSON() {
      const goals = _useRemote ? RS.mem.goals : JSON.parse(localStorage.getItem(GOALS_KEY)||'{}');
      const exams = _useRemote ? RS.mem.exams : JSON.parse(localStorage.getItem(EXAMS_KEY)||'{}');
      const docs = _useRemote ? RS.mem.docs : JSON.parse(localStorage.getItem(DOCS_KEY)||'[]');
      const academic = _useRemote ? RS.mem.academic : JSON.parse(localStorage.getItem('madrasa_academic')||'{}');
      const tnotes = _useRemote ? RS.mem.tnotes : JSON.parse(localStorage.getItem('madrasa_tnotes')||'{}');
      // chats: remote-এ RS.mem.core.chats, local-এ db.chats
      const chats = _useRemote ? (RS.mem.core?.chats || {}) : (this.get().chats || {});
      const completions = window.ApiAmal ? window.ApiAmal.Completions._all()
        : (()=>{ try{return JSON.parse(localStorage.getItem('madrasa_completions')||'[]');}catch{return[];} })();
      return JSON.stringify({ db:this.get(), goals, exams, docs, academic, tnotes, chats, completions, _backupAt: new Date().toISOString() }, null, 2);
    },
    importJSON(json){
      const p=JSON.parse(json); if(!p.db?.students) throw new Error('invalid');
      if (p.db.students.length) delete p.db.allowEmptyStudents;
      // chats backup থাকলে db-তে merge করো
      if (p.chats && typeof p.chats === 'object') p.db.chats = p.chats;
      writeDB(p.db);
      if (_useRemote) {
        RS.mem.core = p.db;
        RS.mem.goals = p.goals || {};
        RS.mem.exams = p.exams || { quizzes: [], submissions: [] };
        RS.mem.docs = Array.isArray(p.docs) ? p.docs : [];
        RS.mem.academic = p.academic || {};
        RS.mem.tnotes = p.tnotes || {};
        if (Array.isArray(p.completions)) RS.mem.completions = p.completions;
        return RS.flushAllFromMem().then(()=>p.db);
      }
      if(p.goals) localStorage.setItem(GOALS_KEY,JSON.stringify(p.goals));
      if(p.exams) localStorage.setItem(EXAMS_KEY,JSON.stringify(p.exams));
      if(p.docs) localStorage.setItem(DOCS_KEY,JSON.stringify(p.docs));
      if(p.academic) localStorage.setItem('madrasa_academic',JSON.stringify(p.academic));
      if(p.tnotes) localStorage.setItem('madrasa_tnotes',JSON.stringify(p.tnotes));
      if(Array.isArray(p.completions)) localStorage.setItem('madrasa_completions',JSON.stringify(p.completions));
      return Promise.resolve(p.db);
    },
    /** সব ছাত্র + টাস্ক/পরীক্ষা/ডক/লক্ষ্য/নোট খালি; শিক্ষক তথ্য ও গ্রুপ ব্রডকাস্ট চ্যাট রাখে। */
    resetForNewRoster() {
      const db = this.get();
      const bc = (db.chats && Array.isArray(db.chats._bc)) ? db.chats._bc.slice() : [];
      db.students = [];
      db.chats = { _bc: bc };
      db.tasks = [];
      db.allowEmptyStudents = true;
      this.save(db);
      if (_useRemote) {
        RS.mem.goals = {};
        RS.mem.exams = { quizzes: [], submissions: [] };
        RS.mem.docs = [];
        RS.mem.academic = {};
        RS.mem.tnotes = {};
        return RS.flushAllFromMem();
      }
      localStorage.setItem(GOALS_KEY, '{}');
      localStorage.setItem(EXAMS_KEY, JSON.stringify({ quizzes: [], submissions: [] }));
      localStorage.setItem(DOCS_KEY, '[]');
      localStorage.setItem('madrasa_academic', '{}');
      localStorage.setItem('madrasa_tnotes', '{}');
      Object.keys(localStorage).filter(k => k.startsWith('madrasa_doc_')).forEach(k => localStorage.removeItem(k));
      return Promise.resolve();
    },
    finalizeRemoteTeacherAfterUnlock() {
      if (!_useRemote || !RS.usesSecureKv?.() || typeof window === 'undefined' || window.__MADRASA_ROLE__ !== 'teacher') return Promise.resolve();
      let c = RS.mem.core;
      const needSeed = !c || (!c.students?.length && !c.allowEmptyStudents);
      if (needSeed) {
        c = buildSeedDemo();
        ensureChatsShape(c);
        RS.mem.core = c;
        return RS.flushKey('core', c).then(() => {
          if (RS.mem.teacherPin == null || RS.mem.teacherPin === '') {
            RS.mem.teacherPin = DEF_PIN;
            return RS.flushKey('teacher_pin', { pin: DEF_PIN });
          }
        });
      }
      ensureChatsShape(c);
      if (RS.mem.teacherPin == null || RS.mem.teacherPin === '') {
        RS.mem.teacherPin = DEF_PIN;
        return RS.flushKey('teacher_pin', { pin: DEF_PIN });
      }
      return Promise.resolve();
    },
  };

  // ── STUDENTS ──────────────────────────────────────────────
  const Students = {
    getAll()   { return DB.get().students||[]; },
    getById(id){ return DB.get().students.find(s=>s.id===id)||null; },

    getNextWaqfId() {
      const used = new Set(
        this.getAll()
          .map((s) => {
            const m = String(s.waqfId || '').match(/waqf_(\d+)/i);
            return m ? parseInt(m[1], 10) : NaN;
          })
          .filter((n) => !Number.isNaN(n) && n > 0)
      );
      let n = 1;
      while (used.has(n)) n++;
      return 'waqf_' + String(n).padStart(3, '0');
    },

    /** UI-only: "001" from stored `waqf_001` (waqfId in memory/DB unchanged). */
    displayWaqfId(waqfId) {
      const w = String(waqfId || '').trim();
      if (!w) return '';
      const m = w.match(/^waqf_0*(\d+)$/i);
      if (m) return String(parseInt(m[1], 10)).padStart(3, '0');
      return w;
    },
    /** ছাত্র তালিকা/চ্যাট ফিল্টার — নাম, waqf_001, বা সংক্ষিপ্ত "001". */
    matchesSearchQuery(s, rawFilter) {
      const f = String(rawFilter || '').trim().toLowerCase();
      if (!f) return true;
      if ((s.name || '').toLowerCase().includes(f)) return true;
      if (s.waqfId && String(s.waqfId).toLowerCase().includes(f)) return true;
      return String(this.displayWaqfId(s.waqfId)).toLowerCase().includes(f);
    },
    // Public display id (তিন অঙ্ক); লগইনে `getByWaqfShortId` দিয়ে "001" বা "waqf_001" দুটোই চলে
    getShortId(s) {
      return s?.waqfId ? this.displayWaqfId(s.waqfId) : null;
    },
    getPendingForLockScreen(){ return _useRemote&&RS.mem&&Array.isArray(RS.mem.lockHints)?RS.mem.lockHints.filter(s=>(s.unreadCount||0)>0):this.getAll().filter(s=>Messages.unreadCount(s.id,'out')>0); },

    // Login lookup: accepts "001" or "waqf_001" (case-insensitive waqf_)
    getByWaqfShortId(raw) {
      const t=String(raw||'').trim().replace(/\s/g,'');
      if(!t) return null;
      let n;
      if(/^waqf_/i.test(t)) n=parseInt(t.slice(5),10);
      else n=parseInt(t,10);
      if(Number.isNaN(n)||n<0) return null;
      const padded='waqf_'+String(n).padStart(3,'0');
      return this.getAll().find(s=>s.waqfId===padded)||null;
    },

    getBatchYear(enrollmentDate) {
      if(!enrollmentDate) return null;
      return new Date().getFullYear() - new Date(enrollmentDate).getFullYear();
    },
    add({ name, cls, roll, note, pin, fatherName='', fatherOccupation='', contact='', district='', upazila='', bloodGroup='', enrollmentDate='', responsibility='' }) {
      const db = DB.get();
      const colors=['#128C7E','#1565C0','#6A1B9A','#BF360C','#1B5E20','#E65100','#004D40','#880E4F'];
      const s = {
        id:uid('s'), waqfId:this.getNextWaqfId(),
        name, cls, roll, note, pin, color:colors[db.students.length%colors.length],
        fatherName, fatherOccupation, contact, district, upazila, bloodGroup, enrollmentDate, responsibility,
      };
      db.students.push(s); db.chats[s.id]=[];
      delete db.allowEmptyStudents;
      DB.save(db);
      if (_useRemote && RS.saveStudentRemote) RS.saveStudentRemote(s);
      return s;
    },

    update(sid, data) {
      const db=DB.get(); const s=db.students.find(s=>s.id===sid); if(!s) return null;
      // Don't overwrite id, waqfId, color
      const { id:_, waqfId:__, color:___, ...rest } = data;
      Object.assign(s, rest); DB.save(db); return s;
    },

    updatePin(sid, pin) {
      const db=DB.get();
      const s=db.students.find(s=>s.id===sid); if(s){ s.pin=pin; DB.save(db); } return s;
    },

    /** ছাত্র সারি অপরিবর্তিত; চ্যাট, টাস্ক, পরীক্ষা, ডক, লক্ষ্য, একাডেমিক, নোট মুছে। */
    clearAllRelatedData(sid) {
      if (!this.getById(sid)) throw new Error('student_not_found');
      // Delete all related rows from the remote DB first (before local changes)
      if (_useRemote && RS.clearStudentDataRemote) RS.clearStudentDataRemote(sid);
      if (typeof window !== 'undefined' && window.DailyScheduleAPI && window.DailyScheduleAPI.clearStudent)
        window.DailyScheduleAPI.clearStudent(sid);
      const AA = window.ApiAmal; if (AA) AA.Completions.clearStudent(sid);
      const db0 = DB.get();
      db0.chats[sid] = [];
      DB.save(db0);
      const acad = AcademicHistory._read();
      delete acad[sid];
      AcademicHistory._write(acad);
      const tnotes = TeacherNotes._read();
      delete tnotes[sid];
      TeacherNotes._write(tnotes);
      const gAll = Goals._all();
      delete gAll[sid];
      if (_useRemote) {
        RS.mem.goals = gAll;
        RS.schedule('goals', () => JSON.parse(JSON.stringify(RS.mem.goals)));
      } else {
        localStorage.setItem(GOALS_KEY, JSON.stringify(gAll));
      }
      const db1 = DB.get();
      db1.tasks = (db1.tasks || [])
        .map((t) => {
          if (!t.assignees || t.assignees[sid] === undefined) return t;
          const assignees = { ...t.assignees };
          delete assignees[sid];
          const completedBy = { ...(t.completedBy || {}) };
          delete completedBy[sid];
          if (!Object.keys(assignees).length) return null;
          return { ...t, assignees, completedBy };
        })
        .filter(Boolean);
      DB.save(db1);
      const ex = Exams._readAll();
      ex.submissions = (ex.submissions || []).filter((sub) => sub.studentId !== sid);
      ex.quizzes = (ex.quizzes || []).map((q) => ({
        ...q,
        assigneeIds: (q.assigneeIds || []).filter((id) => id !== sid),
      }));
      Exams._write(ex);
      Docs.deleteAllForStudent(sid);
    },

    /** সব ছাত্রের সংশ্লিষ্ট ডেটা মুছে — নাম/ওয়াকফ/পিন অপরিবর্তিত থাকে। */
    clearAllStudentsData() {
      for (const s of this.getAll()) this.clearAllRelatedData(s.id);
    },

    /** ছাত্র + সব সংশ্লিষ্ট ডেটা মুছে; ওয়াকফ নম্বর পরে নতুন ছাত্রের জন্য পুনরায় বরাদ্দ হতে পারে। */
    deleteCompletely(sid) {
      if (!this.getById(sid)) throw new Error('student_not_found');
      this.clearAllRelatedData(sid);
      const db = DB.get();
      db.students = db.students.filter((s) => s.id !== sid);
      delete db.chats[sid];
      DB.save(db);
      if (_useRemote) {
        // Remove from lock-screen hints immediately so UI updates at once
        if (RS.mem && Array.isArray(RS.mem.lockHints))
          RS.mem.lockHints = RS.mem.lockHints.filter(s => s.id !== sid);
        // Delete from DB (CASCADE removes all related rows)
        if (RS.deleteStudentRemote) RS.deleteStudentRemote(sid);
      }
    },

    importFromCSV(csvText) {
      const lines = csvText.replace(/\r/g,'').trim().split('\n');
      if(lines.length < 2) throw new Error('empty_file');
      const parseCSVLine = line => {
        const out = []; let cur = ''; let i = 0; let inQ = false;
        while (i < line.length) {
          const c = line[i];
          if (inQ) {
            if (c === '"') {
              if (line[i + 1] === '"') { cur += '"'; i += 2; continue; }
              inQ = false; i++; continue;
            }
            cur += c; i++; continue;
          }
          if (c === '"') { inQ = true; i++; continue; }
          if (c === ',') { out.push(cur.trim()); cur = ''; i++; continue; }
          cur += c; i++;
        }
        out.push(cur.trim());
        return out.map(x => x.replace(/^"|"$/g, '').replace(/""/g, '"'));
      };
      const header = parseCSVLine(lines[0]).map(h => h.toLowerCase());
      const col = k => header.indexOf(k);
      const results = { success:0, errors:[] };
      const db = DB.get();
      for(let i=1;i<lines.length;i++){
        if(!lines[i].trim()) continue;
        const r = parseCSVLine(lines[i]);
        const name = r[col('name')]||''; const pin = (r[col('pin')]||'').trim();
        if(!name){ results.errors.push(`Row ${i+1}: name missing`); continue; }
        if(!/^\d{4}$/.test(pin)){ results.errors.push(`Row ${i+1} (${name}): invalid PIN`); continue; }
        const colors=['#128C7E','#1565C0','#6A1B9A','#BF360C','#1B5E20','#E65100','#004D40','#880E4F'];
        const s = {
          id:uid('s'), waqfId:this.getNextWaqfId(),
          name, pin, color:colors[db.students.length%colors.length],
          cls:r[col('class')]||r[col('cls')]||'',
          roll:r[col('roll')]||'',
          fatherName:r[col('father_name')]||'',
          fatherOccupation:r[col('father_occupation')]||'',
          contact:r[col('contact')]||'',
          district:r[col('district')]||'',
          upazila:r[col('upazila')]||'',
          bloodGroup:r[col('blood_group')]||'',
          enrollmentDate:r[col('enrollment_date')]||'',
          note:r[col('note')]||'',
        };
        db.students.push(s); db.chats[s.id]=[]; results.success++;
      }
      if (results.success > 0) delete db.allowEmptyStudents;
      DB.save(db); return results;
    },
  };

  // ── ACADEMIC HISTORY ──────────────────────────────────────
  const AcademicHistory = {
    _key:'madrasa_academic',
    _read(){
      if (_useRemote) return RS.mem.academic || {};
      try{ return JSON.parse(localStorage.getItem(this._key)||'{}'); }catch{ return {}; }
    },
    _write(d){
      if (_useRemote) {
        RS.mem.academic = d;
        RS.schedule('academic', () => JSON.parse(JSON.stringify(RS.mem.academic)));
        return;
      }
      localStorage.setItem(this._key,JSON.stringify(d));
    },
    getAll(sid){ return this._read()[sid]||[]; },
    add(sid,{yearClass,grade}){
      const all=this._read(); if(!all[sid]) all[sid]=[];
      const rec={id:uid('ah'),yearClass,grade,addedAt:today()};
      all[sid].push(rec); this._write(all); return rec;
    },
    delete(sid,rid){
      const all=this._read();
      if(all[sid]) all[sid]=all[sid].filter(r=>r.id!==rid);
      this._write(all);
    },
  };

  // ── TEACHER NOTES ─────────────────────────────────────────
  const TeacherNotes = {
    _key:'madrasa_tnotes',
    _read(){
      if (_useRemote) return RS.mem.tnotes || {};
      try{ return JSON.parse(localStorage.getItem(this._key)||'{}'); }catch{ return {}; }
    },
    _write(d){
      if (_useRemote) {
        RS.mem.tnotes = d;
        RS.schedule('tnotes', () => JSON.parse(JSON.stringify(RS.mem.tnotes)));
        return;
      }
      localStorage.setItem(this._key,JSON.stringify(d));
    },
    getAll(sid){ return this._read()[sid]||[]; },
    add(sid,text){
      const all=this._read(); if(!all[sid]) all[sid]=[];
      const note={id:uid('tn'),text,date:today(),time:nowTime()};
      all[sid].unshift(note); this._write(all); return note;
    },
    update(sid,nid,text){
      const all=this._read(); const n=(all[sid]||[]).find(x=>x.id===nid);
      if(n){ n.text=text; n.edited=today(); this._write(all); } return n;
    },
    delete(sid,nid){
      const all=this._read();
      if(all[sid]) all[sid]=all[sid].filter(n=>n.id!==nid);
      this._write(all);
    },
  };

  // ── MESSAGES ─────────────────────────────────────────────
  const Messages = {
    getThread(id)          { return DB.get().chats[id]||[]; },
    send(threadId,text,type='text',extra={}) {
      const db=DB.get(); if(!db.chats[threadId]) db.chats[threadId]=[];
      // read:false = student hasn't seen it yet (shows single tick; double tick after student opens chat)
      const m={id:uid('m'),role:'out',text,type,time:nowTime(),read:false,_ts:Date.now(),...extra};
      db.chats[threadId].push(m); stampNotify(db); DB.save(db); return m;
    },
    sendFromStudent(sid,text,type='text',extra={}) {
      const db=DB.get(); if(!db.chats[sid]) db.chats[sid]=[];
      // read:false = teacher hasn't seen it yet (single tick on student side)
      const m={id:uid('m'),role:'in',text,type,time:nowTime(),read:false,_ts:Date.now(),...extra};
      db.chats[sid].push(m); stampNotify(db); DB.save(db); return m;
    },
    // Send a file directly from chat (student → teacher)
    sendFileFromStudent(sid, file, { category='general', note='', replyTo=null, displayName=null } = {}) {
      return new Promise((resolve, reject) => {
        const student=Students.getById(sid);
        if(!student){ reject(new Error('student_not_found')); return; }
        if(!fileWithinUploadLimit(file)){ reject(new Error('file_too_large')); return; }
        const dispName = displayName || file.name;
        if (_useRemote) {
          const docId=uid('doc');
          const path=`${sid}/${docId}_${safeFilePart(file.name)}`;
          RS.uploadFile(path, file).then(res=>{
            const { fileUrl, storagePath } = RS.consumeUploadResult(res);
            const meta={
              id:docId, studentId:sid, studentName:student.name,
              fileName:dispName, fileType:file.type, fileSize:file.size,
              category, note, uploadedAt:new Date().toISOString(), read:false,
              fileUrl, storage_path: storagePath || path, sentBy:'student', reviewStatus:'pending',
            };
            const list=RS.mem.docs||[];
            list.unshift(meta);
            RS.mem.docs=list;
            RS.schedule('docs_meta', ()=>JSON.parse(JSON.stringify(RS.mem.docs)));
            const db=DB.get(); if(!db.chats[sid]) db.chats[sid]=[];
            const m={id:uid('m'),role:'in',type:'doc',text:dispName,time:nowTime(),read:false,
                     fileName:dispName, fileType:file.type, fileSize:file.size, docId, fileUrl, storage_path: storagePath || path,
                     ...(replyTo?{replyTo}:{})};
            db.chats[sid].push(m); stampNotify(db); DB.save(db);
            resolve({ meta, msg: m });
          }).catch(err=>reject(err));
          return;
        }
        const reader=new FileReader();
        reader.onload=e=>{
          const docId=uid('doc');
          const meta={
            id:docId, studentId:sid, studentName:student.name,
            fileName:dispName, fileType:file.type, fileSize:file.size,
            category, note, uploadedAt:new Date().toISOString(), read:false, sentBy:'student', reviewStatus:'pending',
          };
          try { localStorage.setItem('madrasa_doc_'+docId, e.target.result); }
          catch { reject(new Error('storage_full')); return; }
          const list=JSON.parse(localStorage.getItem('madrasa_docs')||'[]');
          list.unshift(meta); localStorage.setItem('madrasa_docs', JSON.stringify(list));
          const db=DB.get(); if(!db.chats[sid]) db.chats[sid]=[];
          const m={id:uid('m'),role:'in',type:'doc',text:dispName,time:nowTime(),read:false,
                   fileName:dispName, fileType:file.type, fileSize:file.size, docId,
                   ...(replyTo?{replyTo}:{})};
          db.chats[sid].push(m); DB.save(db);
          resolve({ meta, msg: m });
        };
        reader.onerror=()=>reject(new Error('read_error'));
        reader.readAsDataURL(file);
      });
    },
    sendFileFromTeacher(sid, file, { replyTo=null, displayName=null } = {}) {
      return new Promise((resolve, reject) => {
        if(!fileWithinUploadLimit(file)){ reject(new Error('file_too_large')); return; }
        const dispName = displayName || file.name;
        if (_useRemote) {
          const docId=uid('tdoc');
          const path=`teacher/${sid}/${docId}_${safeFilePart(file.name)}`;
          const st=Students.getById(sid);
          RS.uploadFile(path, file).then(res=>{
            const { fileUrl, storagePath } = RS.consumeUploadResult(res);
            const meta={
              id:docId, studentId:sid, studentName:st?.name||'',
              fileName:dispName, fileType:file.type, fileSize:file.size,
              category:'general', note:'', uploadedAt:new Date().toISOString(), read:true,
              fileUrl, storage_path: storagePath || path, sentBy:'teacher',
            };
            const list=RS.mem.docs||[];
            list.unshift(meta);
            RS.mem.docs=list;
            RS.schedule('docs_meta', ()=>JSON.parse(JSON.stringify(RS.mem.docs)));
            const db=DB.get(); if(!db.chats[sid]) db.chats[sid]=[];
            const m={id:uid('m'),role:'out',type:'doc',text:dispName,time:nowTime(),read:false,
                     fileName:dispName, fileType:file.type, fileSize:file.size, docId, fileUrl, storage_path: storagePath || path,
                     ...(replyTo?{replyTo}:{})};
            db.chats[sid].push(m); stampNotify(db); DB.save(db);
            resolve({ msg: m });
          }).catch(err=>reject(err));
          return;
        }
        const reader=new FileReader();
        reader.onload=e=>{
          const docId=uid('tdoc');
          try { localStorage.setItem('madrasa_doc_'+docId, e.target.result); }
          catch { reject(new Error('storage_full')); return; }
          // Add metadata so Docs.getById() can find this file for preview
          const st=Students.getById(sid);
          const meta={id:docId, studentId:sid, studentName:st?.name||'',
                      fileName:dispName, fileType:file.type, fileSize:file.size,
                      category:'general', note:'', uploadedAt:new Date().toISOString(), read:true, sentBy:'teacher'};
          const mList=JSON.parse(localStorage.getItem(DOCS_KEY)||'[]');
          mList.unshift(meta); localStorage.setItem(DOCS_KEY, JSON.stringify(mList));
          const db=DB.get(); if(!db.chats[sid]) db.chats[sid]=[];
          const m={id:uid('m'),role:'out',type:'doc',text:dispName,time:nowTime(),read:false,
                   fileName:dispName, fileType:file.type, fileSize:file.size, docId,
                   ...(replyTo?{replyTo}:{})};
          db.chats[sid].push(m); DB.save(db);
          resolve({ msg: m });
        };
        reader.onerror=()=>reject(new Error('read_error'));
        reader.readAsDataURL(file);
      });
    },
    broadcast(text) {
      const db=DB.get(); const m={id:uid('m'),role:'out',text,type:'text',time:nowTime(),read:false,isBroadcast:true,_ts:Date.now()};
      if(!db.chats['_bc']) db.chats['_bc']=[];
      db.chats['_bc'].push({...m});
      // Student copies are local-only — _bc row in Supabase is the single notification source.
      db.students.forEach(s=>{ if(!db.chats[s.id]) db.chats[s.id]=[]; db.chats[s.id].push({...m,id:uid('m'),_skipRemote:true}); });
      stampNotify(db); DB.save(db); return m;
    },
    sendTask(sid,task) {
      const db=DB.get(); if(!db.chats[sid]) db.chats[sid]=[];
      const m={id:uid('m'),role:'out',type:'task',text:task.title,task:{title:task.title,desc:task.desc,deadline:task.deadline,taskType:task.type},time:nowTime(),read:true};
      db.chats[sid].push(m); stampNotify(db); DB.save(db); return m;
    },
    markRead(threadId,role='in') {
      const db=DB.get(); (db.chats[threadId]||[]).forEach(m=>{ if(m.role===role) m.read=true; }); DB.save(db);
      if (_useRemote && RS.markMessagesReadRemote) RS.markMessagesReadRemote(threadId, role === 'in' ? 'teacher' : 'student');
      // Dismiss matching OS push notification
      if ('serviceWorker' in navigator && navigator.serviceWorker.controller) {
        const tag = role === 'in'
          ? 'msg-in-' + threadId
          : 'msg-out-' + (Students.getById(threadId)?.waqfId || threadId);
        navigator.serviceWorker.controller.postMessage({ type: 'CLEAR_NOTIFICATION', tag });
      }
    },
    // Teacher opened a student's chat → mark student messages as read (→ double tick on student)
    markReadByTeacher(sid) { this.markRead(sid,'in'); },
    unreadCount(threadId,role='in') { return (DB.get().chats[threadId]||[]).filter(m=>m.role===role&&!m.read).length; },
    /** শিক্ষক UI: সব ছাত্র + গ্রুপ ব্রডকাস্ট থ্রেডে মেসেজ টেক্সট খোঁজা (লোকাল মেমোরি থেকে)। */
    searchAllChats(rawQuery, opts = {}) {
      const limit = Math.min(Math.max(Number(opts.limit) || 60, 1), 200);
      const needle = String(rawQuery || '').trim().toLowerCase();
      if (!needle) return [];
      const db = DB.get();
      const textOf = (m) => {
        if (!m) return '';
        if (m.type === 'task' && m.task) return [m.task.title, m.task.desc, m.text].filter(Boolean).join('\n');
        if (m.type === 'doc') return [m.fileName, m.text].filter(Boolean).join('\n');
        return String(m.text || '');
      };
      const tsOf = (m) => {
        if (m._ts) return m._ts;
        const x = /^m(\d{13})/.exec(m.id || '');
        return x ? parseInt(x[1], 10) : 0;
      };
      const snippet = (full) => {
        const fullS = String(full || '').replace(/\s+/g, ' ').trim();
        const low = fullS.toLowerCase();
        const i = low.indexOf(needle);
        const maxLen = 120;
        if (i < 0) return (fullS.slice(0, maxLen) + (fullS.length > maxLen ? '…' : ''));
        const start = Math.max(0, i - 28);
        const chunk = fullS.slice(start, start + maxLen);
        return (start > 0 ? '…' : '') + chunk + (start + maxLen < fullS.length ? '…' : '');
      };
      const bcSigs = new Set();
      (db.chats._bc || []).forEach((m) => {
        if (m && (m.type === 'text' || !m.type)) bcSigs.add(`${String(m.text || '')}\0${String(m.time || '')}`);
      });
      const out = [];
      const push = (threadId, m, studentLabel, waqfShort) => {
        const full = textOf(m);
        if (!full.toLowerCase().includes(needle)) return;
        const sig = `${String(m.text || '')}\0${String(m.time || '')}`;
        if (m.role === 'out' && (m.type === 'text' || !m.type) && threadId !== '_broadcast' && bcSigs.has(sig)) return;
        out.push({
          threadId,
          messageId: m.id,
          studentLabel,
          waqfShort: waqfShort || '',
          time: m.time || '',
          snippet: snippet(full),
          kind: m.type === 'doc' ? 'doc' : m.type === 'task' ? 'task' : 'text',
          _ts: tsOf(m),
        });
      };
      (db.chats._bc || []).forEach((m) => push('_broadcast', m, '📢 সবাইকে বার্তা', ''));
      Students.getAll().forEach((s) => {
        const w = s.waqfId ? Students.displayWaqfId(s.waqfId) : '';
        (db.chats[s.id] || []).forEach((m) => push(s.id, m, s.name || '', w));
      });
      out.sort((a, b) => (b._ts || 0) - (a._ts || 0));
      return out.slice(0, limit).map(({ _ts, ...rest }) => rest);
    },
    /** টেক্সট মেসেজ সম্পাদনা/মোছার সময় (মিলি সেকেন্ড) — WhatsApp-সদৃশ ১৫ মিনিট */
    MSG_TEXT_WINDOW_MS: 15 * 60 * 1000,
    _msgSentTs(m) {
      if (!m) return 0;
      if (m._ts) return m._ts;
      const x = /^m(\d{13})/.exec(m.id || '');
      return x ? parseInt(x[1], 10) : 0;
    },
    /** asTeacher=true: শিক্ষকের নিজের (out); false: ছাত্রের নিজের (in) — উভয় পক্ষ টেক্সট সম্পাদনা/মোছা (সময়সীমার মধ্যে) */
    canModifyOwnMessage(m, asTeacher) {
      if (!m || m._skipRemote) return false;
      if (m.type && m.type !== 'text') return false;
      if (m.isBroadcast && m.role === 'in') return false;
      const own = asTeacher ? m.role === 'out' : m.role === 'in';
      if (!own) return false;
      const ts = this._msgSentTs(m);
      if (!ts) return false;
      return (Date.now() - ts) <= this.MSG_TEXT_WINDOW_MS;
    },
    updateOwnText(threadId, msgId, newText, asTeacher) {
      const t = String(newText || '').trim();
      if (!t) return { ok: false, err: 'empty' };
      const db = DB.get();
      const arr = db.chats[threadId];
      const m = arr && arr.find((x) => x.id === msgId);
      if (!m) return { ok: false, err: 'nf' };
      if (!this.canModifyOwnMessage(m, !!asTeacher)) return { ok: false, err: 'forbidden' };
      m.text = t;
      m.editedAt = new Date().toISOString();
      stampNotify(db);
      DB.save(db);
      if (_useRemote && RS.updateMessageTextRemote) RS.updateMessageTextRemote(msgId, t);
      return { ok: true };
    },
    deleteOwn(threadId, msgId, asTeacher) {
      const db = DB.get();
      const arr = db.chats[threadId];
      const m = arr && arr.find((x) => x.id === msgId);
      if (!m) return { ok: false, err: 'nf' };
      if (!this.canModifyOwnMessage(m, !!asTeacher)) return { ok: false, err: 'forbidden' };
      const ix = arr.findIndex((x) => x.id === msgId);
      if (ix < 0) return { ok: false };
      arr.splice(ix, 1);
      stampNotify(db);
      DB.save(db);
      if (_useRemote && RS.deleteOwnMessageRemote) RS.deleteOwnMessageRemote(msgId);
      return { ok: true };
    },
  };

  // ── TASKS ─────────────────────────────────────────────────
  const Tasks = {
    getAll()           { return DB.get().tasks||[]; },
    getForStudent(sid) { return this.getAll().filter(t=>t.assignees&&t.assignees[sid]); },

    add({ title, desc, deadline, type='onetime', assigneeIds }) {
      const db=DB.get();
      const task={
        id:uid('t'), title, desc,
        type:type||'onetime',
        deadline:type==='onetime'?(deadline||nextDate(7)):'',
        created:today(),
        assignees:Object.fromEntries(assigneeIds.map(id=>[id,'pending'])),
        completedBy:{},
      };
      db.tasks.push(task); DB.save(db);
      if (_useRemote && RS.saveTaskRemote) RS.saveTaskRemote(task);
      return task;
    },

    // ── Completions API ────────────────────────────────────────
    markCompleted(tid,sid,opts)    { const AA=window.ApiAmal; return AA&&AA.markCompleted(tid,sid,opts); },
    unmarkCompleted(tid,sid,date)  { const AA=window.ApiAmal; AA&&AA.unmarkCompleted(tid,sid,date); },
    isCompleted(tid,sid,date)      { const AA=window.ApiAmal; return !!(AA&&AA.isCompleted(tid,sid,date)); },

    getTodayStatus(task,sid) {
      if (task.type==='daily') return this.isCompleted(task.id,sid,today())?'done':'pending';
      return task.assignees?.[sid]==='done'?'done':'pending';
    },

    syncTodayFromCompletions() {
      const AA=window.ApiAmal;
      if (!AA) { this._legacyResetDaily(); return; }
      const db=DB.get();
      db.tasks=AA.syncTodayFromCompletions(db.tasks);
      DB.save(db);
    },

    _legacyResetDaily() {
      const db=DB.get(); const todayStr=today(); let changed=false;
      db.tasks.forEach(t=>{
        if (t.type!=='daily') return;
        Object.keys(t.assignees||{}).forEach(sid=>{
          const cb=t.completedBy?.[sid];
          if (t.assignees[sid]==='done'&&cb?.date!==todayStr){ t.assignees[sid]='pending'; changed=true; }
        });
      });
      if (changed) DB.save(db);
    },

    // Legacy compat — also records in Completions
    markDailyDone(tid,sid) {
      const db=DB.get(); const t=db.tasks.find(x=>x.id===tid); if(!t) return null;
      if (!t.completedBy) t.completedBy={};
      t.completedBy[sid]={date:today(),time:nowTime()};
      t.assignees[sid]='done';
      DB.save(db);
      const AA=window.ApiAmal; if (AA) AA.markCompleted(tid,sid,{status:'done'});
      return t;
    },
    markDone(tid,sid) {
      const db=DB.get(); const t=db.tasks.find(x=>x.id===tid); if(!t) return null;
      t.assignees[sid]='done';
      if (!t.completedBy) t.completedBy={};
      t.completedBy[sid]={date:today(),time:nowTime()};
      DB.save(db);
      const AA=window.ApiAmal; if (AA) AA.markCompleted(tid,sid,{status:'done'});
      return t;
    },
    isDailyDoneToday(task,sid) {
      return this.isCompleted(task.id,sid,today())||task.completedBy?.[sid]?.date===today();
    },
    toggleStatus(tid,sid) {
      const db=DB.get(); const t=db.tasks.find(x=>x.id===tid); if(!t) return null;
      if (t.type==='daily') {
        const done=this.isCompleted(tid,sid,today());
        if (done) this.unmarkCompleted(tid,sid,today()); else this.markCompleted(tid,sid);
        t.assignees[sid]=done?'pending':'done';
      } else {
        const c=t.assignees[sid];
        t.assignees[sid]=c==='pending'?'done':c==='done'?'late':'pending';
      }
      DB.save(db); return t;
    },
    resetDailyForToday() { this.syncTodayFromCompletions(); },

    pendingCount(sid=null) {
      const tasks=this.getAll(); let n=0;
      if (sid) return tasks.filter(t=>{
        if (t.type==='daily') return !this.isDailyDoneToday(t,sid);
        return t.assignees?.[sid]==='pending';
      }).length;
      tasks.forEach(t=>Object.keys(t.assignees||{}).forEach(s=>{
        if (t.type==='daily'){ if(!this.isDailyDoneToday(t,s)) n++; }
        else{ if(t.assignees[s]==='pending') n++; }
      })); return n;
    },

    overallStatus(task) {
      const ids=Object.keys(task.assignees||{});
      if (task.type==='daily'){
        const done=ids.filter(id=>this.isDailyDoneToday(task,id)).length;
        return done===ids.length?'done':done>0?'partial':'pending';
      }
      const done=ids.filter(id=>task.assignees[id]==='done').length;
      const late=task.deadline<today()&&done<ids.length;
      return done===ids.length?'done':late?'late':'pending';
    },

    delete(tid) {
      const db=DB.get(); db.tasks=db.tasks.filter(t=>t.id!==tid); DB.save(db);
      if (_useRemote && RS.deleteTaskRemote) RS.deleteTaskRemote(tid);
    },

    // ── ApiAmal delegates ─────────────────────────────────────
    getStreak(sid,tid)       { const AA=window.ApiAmal; return AA?AA.getStreak(sid,tid):{current:0,longest:0}; },
    getProgressSummary(sid)  { const AA=window.ApiAmal; return AA?AA.getProgressSummary(sid):{today:{done:0,total:0,percent:0},week:{done:0,total:0,percent:0},month:{done:0,total:0,percent:0}}; },
    getTodayOverview(date)   { const AA=window.ApiAmal; return AA?AA.getTodayOverview(date):[]; },
    getLeaderboard(period)   { const AA=window.ApiAmal; return AA?AA.getLeaderboard(period):[]; },
    getCalendarData(sid,y,m) { const AA=window.ApiAmal; return AA?AA.getCalendarData(sid,y,m):{}; },
  };

  // ── GOALS ─────────────────────────────────────────────────
  const Goals = {
    _all() {
      if (_useRemote) return RS.mem.goals || (RS.mem.goals = {});
      try { return JSON.parse(localStorage.getItem(GOALS_KEY)||'{}'); } catch { return {}; }
    },
    getAll(sid)  { const all=this._all(); return all[sid]||[]; },
    _save(sid,g) {
      const all=this._all();
      all[sid]=g;
      if (_useRemote) {
        RS.schedule('goals', () => JSON.parse(JSON.stringify(RS.mem.goals)));
        return;
      }
      localStorage.setItem(GOALS_KEY,JSON.stringify(all));
    },
    add(sid,{title,cat='other',deadline='',note=''}) {
      const goals=this.getAll(sid);
      const g={id:uid('g'),title,cat,deadline,note,done:false,created:today()};
      goals.push(g); this._save(sid,goals); return g;
    },
    toggle(sid,gid)  { const goals=this.getAll(sid); const g=goals.find(x=>x.id===gid); if(g){ g.done=!g.done; this._save(sid,goals); } return g; },
    delete(sid,gid)  { this._save(sid,this.getAll(sid).filter(g=>g.id!==gid)); },
  };

  // ── EXAMS ─────────────────────────────────────────────────
  /*
    Quiz structure:
    {
      id, title, subject, desc, timeLimit (minutes), passPercent,
      deadline, created, assigneeIds:[],
      questions: [{id, type, text, options[], correctAnswer, marks, uploadInstructions}]
    }
    Submission structure:
    {
      id, quizId, studentId, studentName,
      answers: { questionId: answer },
      score, total, passed, submittedAt
    }
  */
  const Exams = {
    _readAll() {
      if (_useRemote) return RS.mem.exams || (RS.mem.exams = { quizzes: [], submissions: [] });
      try { return JSON.parse(localStorage.getItem(EXAMS_KEY))||{quizzes:[],submissions:[]}; } catch { return {quizzes:[],submissions:[]}; }
    },
    _write(data) {
      if (_useRemote) {
        RS.mem.exams = data;
        RS.schedule('exams', () => JSON.parse(JSON.stringify(RS.mem.exams)));
        return;
      }
      localStorage.setItem(EXAMS_KEY, JSON.stringify(data));
    },

    getQuizzes()                { return this._readAll().quizzes||[]; },
    getQuizById(qid)            { return this.getQuizzes().find(q=>q.id===qid)||null; },
    getQuizzesForStudent(sid)   { return this.getQuizzes().filter(q=>q.assigneeIds?.includes(sid)); },
    getSubmissions()            { return this._readAll().submissions||[]; },
    getSubmission(qid, sid)     { return this.getSubmissions().find(s=>s.quizId===qid&&s.studentId===sid)||null; },
    getSubmissionsForQuiz(qid)  { return this.getSubmissions().filter(s=>s.quizId===qid); },

    addQuiz({ title, subject, desc, timeLimit, passPercent, deadline, assigneeIds, questions }) {
      const data=this._readAll();
      const quiz={
        id:uid('q'), title, subject:subject||'', desc:desc||'',
        timeLimit:parseInt(timeLimit)||30,
        passPercent:parseInt(passPercent)||60,
        deadline:deadline||'', created:today(),
        assigneeIds:assigneeIds||[],
        questions:(questions||[]).map((q,i)=>({...q,id:uid('qq'+i)})),
      };
      data.quizzes.push(quiz); this._write(data); return quiz;
    },

    deleteQuiz(qid) {
      const data=this._readAll();
      data.quizzes=data.quizzes.filter(q=>q.id!==qid);
      data.submissions=data.submissions.filter(s=>s.quizId!==qid);
      this._write(data);
      /* Remote: saveExams only upserts — DB row must be deleted or quiz returns on next bootstrap. */
      if (_useRemote && RS.deleteQuizRemote) void RS.deleteQuizRemote(qid);
    },

    submitQuiz(qid, sid, answers) {
      const quiz=this.getQuizById(qid); if(!quiz) throw new Error('quiz_not_found');
      const student=Students.getById(sid);
      let score=0, total=0;
      quiz.questions.forEach(q=>{
        total+=q.marks||1;
        const ans=answers[q.id];
        if(q.type==='multiple_choice'||q.type==='true_false'){
          if(String(ans).trim().toLowerCase()===String(q.correctAnswer).trim().toLowerCase()) score+=q.marks||1;
        } else if(q.type==='fill_blank'){
          if(String(ans||'').trim().toLowerCase()===String(q.correctAnswer||'').trim().toLowerCase()) score+=q.marks||1;
        }
        // short_answer / essay / file_upload → teacher grades manually (score=0 initially)
      });
      const data=this._readAll();
      const existing=data.submissions.findIndex(s=>s.quizId===qid&&s.studentId===sid);
      const sub={
        id:uid('sub'), quizId:qid, studentId:sid,
        studentName:student?.name||sid,
        answers, score, total,
        passed:total>0?(score/total*100)>=(quiz.passPercent||60):false,
        submittedAt:new Date().toISOString(),
        needsManualGrade: quiz.questions.some(q=>['short_answer','essay','file_upload'].includes(q.type)),
      };
      if(existing>=0) data.submissions[existing]=sub; else data.submissions.push(sub);
      this._write(data); return sub;
    },

    // Teacher manually updates a score
    updateScore(subId, score) {
      const data=this._readAll();
      const sub=data.submissions.find(s=>s.id===subId); if(!sub) return null;
      const quiz=this.getQuizById(sub.quizId);
      sub.score=score;
      sub.passed=quiz?(score/sub.total*100)>=(quiz.passPercent||60):false;
      this._write(data); return sub;
    },
  };

  // ── DOCUMENTS ────────────────────────────────────────────
  /*
    Document metadata (KV `docs_meta`):
    { id, studentId, studentName, fileName, fileType, fileSize,
      category, note, uploadedAt, read, fileUrl?, storage_path? }
    রিমোট: ফাইলের বাইট Supabase Storage বাকেট `waqf-files` এ; লোকাল: madrasa_doc_<id> base64
  */
  const Docs = {
    _readMeta() {
      if (_useRemote) return RS.mem.docs || (RS.mem.docs = []);
      try { return JSON.parse(localStorage.getItem(DOCS_KEY))||[]; } catch { return []; }
    },
    _writeMeta(list) {
      if (_useRemote) {
        RS.mem.docs = list;
        RS.schedule('docs_meta', () => JSON.parse(JSON.stringify(RS.mem.docs)));
        return;
      }
      localStorage.setItem(DOCS_KEY, JSON.stringify(list));
    },

    getAll()                { return this._readMeta(); },
    getForStudent(sid)      { return this._readMeta().filter(d=>d.studentId===sid); },
    getById(id)             { return this._readMeta().find(d=>d.id===id)||null; },
    getFileData(id) {
      const meta = this.getById(id);
      if (meta && meta.fileUrl) return meta.fileUrl;
      if (_useRemote) return null;
      return localStorage.getItem('madrasa_doc_'+id)||null;
    },
    resolveFileUrl(id) {
      const meta = this.getById(id);
      if (!meta) return Promise.resolve(null);
      /* Private bucket: upload-time fileUrl expires; always refresh from storage_path when remote. */
      if (_useRemote && meta.storage_path && RS.getSignedUrlForPath)
        return RS.getSignedUrlForPath(meta.storage_path);
      if (meta.fileUrl) return Promise.resolve(meta.fileUrl);
      return Promise.resolve(this.getFileData(id));
    },

    // Upload: file is a File object, read as base64 (local) or Storage (remote)
    upload(sid, file, { category='general', note='' } = {}) {
      return new Promise((resolve, reject) => {
        const student=Students.getById(sid);
        if(!student){ reject(new Error('student_not_found')); return; }
        if(!fileWithinUploadLimit(file)){ reject(new Error('file_too_large')); return; }

        if (_useRemote) {
          const id=uid('doc');
          const path=`${sid}/${id}_${safeFilePart(file.name)}`;
          RS.uploadFile(path, file).then(res=>{
            const { fileUrl, storagePath } = RS.consumeUploadResult(res);
            const meta={
              id, studentId:sid, studentName:student.name,
              fileName:file.name, fileType:file.type, fileSize:file.size,
              category, note, uploadedAt:new Date().toISOString(), read:false,
              fileUrl, storage_path: storagePath || path, sentBy:'student',
            };
            const list=this._readMeta(); list.unshift(meta); this._writeMeta(list);
            resolve(meta);
          }).catch(err=>reject(err.message==='storage_full'?new Error('storage_full'):err));
          return;
        }

        const reader=new FileReader();
        reader.onload=e=>{
          const id=uid('doc');
          const meta={
            id, studentId:sid, studentName:student.name,
            fileName:file.name, fileType:file.type, fileSize:file.size,
            category, note, uploadedAt:new Date().toISOString(), read:false, sentBy:'student',
          };
          try {
            localStorage.setItem('madrasa_doc_'+id, e.target.result);
          } catch(storageErr) {
            reject(new Error('storage_full')); return;
          }
          const list=this._readMeta(); list.unshift(meta); this._writeMeta(list);
          resolve(meta);
        };
        reader.onerror=()=>reject(new Error('read_error'));
        reader.readAsDataURL(file);
      });
    },

    markRead(id) {
      const list=this._readMeta(); const d=list.find(x=>x.id===id);
      if(d){ d.read=true; this._writeMeta(list); }
    },

    markReviewed(id) {
      const list=this._readMeta(); const d=list.find(x=>x.id===id);
      if(d){ d.reviewStatus='done'; d.read=true; this._writeMeta(list); }
      if(_useRemote && RS.markDocReviewedRemote) RS.markDocReviewedRemote(id);
    },

    delete(id) {
      if (!_useRemote) localStorage.removeItem('madrasa_doc_'+id);
      this._writeMeta(this._readMeta().filter(d=>d.id!==id));
    },

    deleteAllForStudent(sid) {
      const list = this._readMeta();
      const keep = [];
      for (const d of list) {
        if (d.studentId === sid) {
          if (!_useRemote) localStorage.removeItem('madrasa_doc_' + d.id);
        } else keep.push(d);
      }
      this._writeMeta(keep);
    },

    unreadCount() { return this._readMeta().filter(d=>!d.read).length; },

    totalStorageKB() {
      let bytes=0;
      this._readMeta().forEach(d=>{
        if (d.fileUrl) bytes += d.fileSize || 0;
        else {
          const data=localStorage.getItem('madrasa_doc_'+d.id);
          if(data) bytes+=data.length*0.75;
        }
      });
      return Math.round(bytes/1024);
    },
  };

  // ── TEACHER CONTACT GROUPS ───────────────────────────────
  const _GROUPS_KEY = 'madrasa_groups';
  const Groups = {
    _read() {
      if (_useRemote) return RS.mem.groups || (RS.mem.groups = []);
      try { return JSON.parse(localStorage.getItem(_GROUPS_KEY)||'[]'); } catch { return []; }
    },
    _write(arr) {
      if (_useRemote) { RS.mem.groups = arr; return; }
      localStorage.setItem(_GROUPS_KEY, JSON.stringify(arr));
    },
    getAll() { return this._read(); },
    getById(gid) { return this._read().find(g => g.id === gid) || null; },
    add(name, studentIds) {
      const arr = this._read();
      const g = { id: uid('grp'), name: String(name||'').trim(), studentIds: studentIds||[], createdAt: today() };
      arr.push(g); this._write(arr);
      if (_useRemote && RS.upsertGroupRemote) RS.upsertGroupRemote(g);
      return g;
    },
    update(gid, name, studentIds) {
      const arr = this._read(); const g = arr.find(x => x.id === gid); if (!g) return null;
      g.name = String(name||'').trim(); g.studentIds = studentIds||[];
      this._write(arr);
      if (_useRemote && RS.upsertGroupRemote) RS.upsertGroupRemote(g);
      return g;
    },
    delete(gid) {
      this._write(this._read().filter(g => g.id !== gid));
      if (_useRemote && RS.deleteGroupRemote) RS.deleteGroupRemote(gid);
    },
    sendToGroup(gid, text) {
      const g = this.getById(gid); if (!g || !g.studentIds.length) return [];
      const db = DB.get(); const msgs = [];
      g.studentIds.forEach(sid => {
        if (!db.chats[sid]) db.chats[sid] = [];
        const m = { id: uid('m'), role: 'out', text, type: 'text', time: nowTime(), read: false, groupId: gid };
        db.chats[sid].push(m); msgs.push(m);
      });
      if (msgs.length) { stampNotify(db); DB.save(db); }
      return msgs;
    },
  };

  // ── TEACHER DIARY ─────────────────────────────────────────
  const _DIARY_KEY = 'madrasa_diary';
  const Diary = {
    _read() {
      if (_useRemote) return RS.mem.diary || (RS.mem.diary = []);
      try { return JSON.parse(localStorage.getItem(_DIARY_KEY)||'[]'); } catch { return []; }
    },
    _write(arr) {
      if (_useRemote) { RS.mem.diary = arr; return; }
      localStorage.setItem(_DIARY_KEY, JSON.stringify(arr));
    },
    getAll() { return this._read(); },
    add(text, date) {
      const arr = this._read();
      const entry = { id: uid('di'), date: date || today(), time: nowTime(), text: String(text||'').trim() };
      arr.unshift(entry); this._write(arr);
      if (_useRemote && RS.upsertDiaryRemote) RS.upsertDiaryRemote(entry);
      return entry;
    },
    update(id, text) {
      const arr = this._read(); const e = arr.find(x => x.id === id);
      if (e) { e.text = String(text||'').trim(); e.edited = today(); this._write(arr);
        if (_useRemote && RS.upsertDiaryRemote) RS.upsertDiaryRemote(e); }
      return e;
    },
    delete(id) {
      this._write(this._read().filter(x => x.id !== id));
      if (_useRemote && RS.deleteDiaryRemote) RS.deleteDiaryRemote(id);
    },
  };

  return {
    Auth, DB, Students, Messages, Tasks, Goals, Exams, Docs, AcademicHistory, TeacherNotes, Diary, Groups, today, nowTime, nextDate, uid,
    MAX_UPLOAD_BYTES,
    prepareFilesForUpload,
    unlockTeacherRemote(pin) {
      if (!_useRemote || !RS.unlockTeacherWithPin) return Promise.reject(new Error('not_remote'));
      return RS.unlockTeacherWithPin(pin);
    },
    loginStudentRemote(waqf, pin) {
      if (!_useRemote || !RS.unlockStudentWithWaqfPin) return Promise.reject(new Error('not_remote'));
      return RS.unlockStudentWithWaqfPin(waqf, pin);
    },
    refreshStudentLockHints() { return _useRemote && RS.refreshStudentLockHints ? RS.refreshStudentLockHints() : Promise.resolve(); },
    Pwa: {
      registerServiceWorker() {
        const win = typeof window !== 'undefined' ? window : null;
        if (!win || !win.MadrasaPwa) return Promise.resolve(null);
        return win.MadrasaPwa.register();
      },
      enableNotificationsAfterAuth(role, opts) {
        const win = typeof window !== 'undefined' ? window : null;
        if (!win || !win.MadrasaPwa) return Promise.resolve();
        return win.MadrasaPwa.enableAfterAuth(role, opts || {});
      },
      refreshPushSubscription(role, opts) {
        const win = typeof window !== 'undefined' ? window : null;
        if (!win || !win.MadrasaPwa) return Promise.resolve();
        return win.MadrasaPwa.refreshPushSubscription(role, opts || {});
      },
      enableSharedStudentDevice() {
        const win = typeof window !== 'undefined' ? window : null;
        if (!win || !win.MadrasaPwa) return Promise.resolve();
        return win.MadrasaPwa.enableSharedStudentDevice();
      },
    },
  };
})();

// `api-amal.js` এবং অন্য স্ক্রিপ্ট `window.API` দিয়ে এক্সেস করে; `const API` আলাদাভাবে `window`-এ যায় না।
if (typeof window !== 'undefined') window.API = API;

// ── Global helpers ────────────────────────────────────────
function esc(s){ return String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/\n/g,'<br>'); }
function autoResize(el){ el.style.height='auto'; el.style.height=Math.min(el.scrollHeight,120)+'px'; }
function showToast(msg,duration=2800){ const t=document.getElementById('toast'); if(!t) return; t.textContent=msg; t.classList.add('show'); setTimeout(()=>t.classList.remove('show'),duration); }
function uiViewTransition(run){
  if(typeof document==='undefined'||typeof run!=='function') return;
  if(document.startViewTransition&&!window.matchMedia('(prefers-reduced-motion: reduce)').matches) document.startViewTransition(run);
  else run();
}
function openModal(id){
  const el=document.getElementById(id);
  if(!el) return;
  el.classList.remove('modal-closing');
  el.classList.add('open');
  const sh=el.querySelector('.modal-sheet');
  if(sh&&!window.matchMedia('(prefers-reduced-motion: reduce)').matches){
    sh.style.transform='translateY(100%)';
    requestAnimationFrame(()=>{ requestAnimationFrame(()=>{ sh.style.transform=''; }); });
  }
}
function closeModal(id){
  const el=document.getElementById(id);
  if(!el||!el.classList.contains('open')) return;
  const sheet=el.querySelector('.modal-sheet');
  if(!sheet||window.matchMedia('(prefers-reduced-motion: reduce)').matches){
    el.classList.remove('open','modal-closing');
    return;
  }
  if(el.classList.contains('modal-closing')) return;
  el.classList.add('modal-closing');
  let fin=false;
  const done=()=>{
    if(fin) return;
    fin=true;
    el.classList.remove('open','modal-closing');
    sheet.removeEventListener('transitionend',onEnd);
    clearTimeout(tid);
  };
  const onEnd=e=>{
    if(e.target!==sheet||e.propertyName!=='transform') return;
    done();
  };
  sheet.addEventListener('transitionend',onEnd);
  const tid=setTimeout(done,420);
}
function formatBytes(b){ if(!b) return ''; if(b<1024) return b+' B'; if(b<1048576) return (b/1024).toFixed(1)+' KB'; return (b/1048576).toFixed(1)+' MB'; }
function formatDate(iso){ if(!iso) return ''; return new Date(iso).toLocaleDateString('bn-BD',{year:'numeric',month:'short',day:'numeric'}); }
