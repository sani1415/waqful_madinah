/* Waqful Madinah — remote-sync.js (relational, madrasa_rel_* RPCs)
   Requires: remote-sync-write.js loaded first */
(function (w) {
  const BUCKET = 'waqf-files';
  const DEBOUNCE_MS = 400;
  const SIGNED_URL_SEC = 3600;
  let client = null;
  const timers = {};
  let _teacherPin = '';
  let _studentWaqf = '';
  let _studentPin = '';
  let _studentId = '';
  let realtimeChannel = null;
  const _savedMsgIds = new Set();

  const mem = {
    core: null, goals: null, exams: null,
    docs: [], academic: {}, tnotes: {},
    teacherPin: null, lockHints: [], loaded: false,
    completions: [], groups: [], diary: [],
    dailyScheduleByStudent: {},
    dailySchedule: { rows: [], pending: null },
    noteCategories: [],
    studentNotesByStudent: {},
  };

  function role() { const r = w.__MADRASA_ROLE__; return r === 'teacher' || r === 'student' ? r : ''; }
  function usesSecureKv() { return isRemote() && role() !== ''; }

  function getCreateClient() {
    const s = w.supabase;
    if (!s) return null;
    if (typeof s.createClient === 'function') return s.createClient;
    if (s.default && typeof s.default.createClient === 'function') return s.default.createClient;
    return null;
  }

  function getClient() {
    if (client) return client;
    const url = w.SUPABASE_URL, key = w.SUPABASE_ANON_KEY, create = getCreateClient();
    if (!url || !key || !create) return null;
    client = create(url, key, { auth: { persistSession: false, autoRefreshToken: false } });
    w.supabaseClient = client;
    return client;
  }

  async function rpcOrThrow(sb, name, params) {
    const { data, error } = await sb.rpc(name, params);
    if (error) throw error;
    return data;
  }

  function isRemote() { return !!(w.SUPABASE_URL && w.SUPABASE_ANON_KEY && getCreateClient()); }

  /** "001" / "waqf_001" → `waqf_001` for RPC (matches `students.waqf_id`). */
  function normalizeWaqfForRpc(raw) {
    const t = String(raw || '').trim().replace(/\s/g, '');
    if (!t) return '';
    let n;
    if (/^waqf_/i.test(t)) n = parseInt(t.slice(5), 10);
    else n = parseInt(t, 10);
    if (Number.isNaN(n) || n < 0) return t;
    return 'waqf_' + String(n).padStart(3, '0');
  }

  // Write module context — wired up at bottom
  const _write = (w._RSWrite || { init: () => ({}) }).init({
    getPin: () => _teacherPin,
    setPin: (p) => { _teacherPin = p; mem.teacherPin = p; },
    getStudentPin: () => _studentPin,
    getStudentWaqf: () => _studentWaqf,
    getStudentId: () => _studentId,
    getRole: role,
    savedMsgIds: _savedMsgIds,
  });

  // ── Field conversion: DB (snake_case) → mem (camelCase) ──────
  function stuFromDB(r) {
    return { id: r.id, waqfId: r.waqf_id, name: r.name, cls: r.cls || '', roll: r.roll || '',
      pin: r.pin, color: r.color || '#128C7E', note: r.note || '',
      fatherName: r.father_name || '', fatherOccupation: r.father_occupation || '',
      contact: r.contact || '', district: r.district || '', upazila: r.upazila || '',
      bloodGroup: r.blood_group || '', enrollmentDate: r.enrollment_date || '',
      responsibility: r.responsibility || '' };
  }

  function msgFromDB(m) {
    return { id: m.id, role: m.role, type: m.type || 'text', text: m.text || '',
      read: m.is_read || false,
      time: m.sent_at ? new Date(m.sent_at).toTimeString().slice(0, 5) : '',
      _ts: m.sent_at ? new Date(m.sent_at).getTime() : 0,
      ...(m.extra && typeof m.extra === 'object' ? m.extra : {}) };
  }

  function _parseProposalRows(pr) {
    const arr = Array.isArray(pr) ? pr : [];
    return arr.map((x, i) => ({
      id: x.id || ('p' + i),
      task: String(x.task || ''),
      time: String(x.time || ''),
      sort: i,
    }));
  }

  function buildDailyScheduleByStudent(bundle) {
    const rows = bundle.daily_schedule_rows || [];
    const props = bundle.daily_schedule_proposals || [];
    const by = {};
    for (const r of rows) {
      const sid = r.student_id;
      if (!by[sid]) by[sid] = { rows: [], pending: null };
      by[sid].rows.push({
        id: r.id,
        task: r.task_text || '',
        time: r.time_text || '',
        sort: r.sort_order,
      });
    }
    Object.keys(by).forEach(k => { by[k].rows.sort((a, b) => a.sort - b.sort); });
    for (const p of props) {
      const sid = p.student_id;
      if (!by[sid]) by[sid] = { rows: [], pending: null };
      by[sid].pending = {
        rows: _parseProposalRows(p.proposed_rows),
        status: p.status,
        submittedAt: p.submitted_at || '',
        teacherNote: p.teacher_note || '',
      };
    }
    return by;
  }

  function buildStudentDailySchedule(bundle, sid) {
    const rows = (bundle.daily_schedule_rows || [])
      .filter(r => r.student_id === sid)
      .map(r => ({
        id: r.id,
        task: r.task_text || '',
        time: r.time_text || '',
        sort: r.sort_order,
      }));
    rows.sort((a, b) => a.sort - b.sort);
    const props = bundle.daily_schedule_proposals || [];
    const p = Array.isArray(props) ? props.find(x => x.student_id === sid) : null;
    let pending = null;
    if (p && p.status) {
      pending = {
        rows: _parseProposalRows(p.proposed_rows),
        status: p.status,
        submittedAt: p.submitted_at || '',
        teacherNote: p.teacher_note || '',
      };
    }
    return { rows, pending };
  }

  // ── Assemble relational teacher bundle → mem ─────────────────
  function assembleTeacherBundle(bundle) {
    const cfg = bundle.config || {};
    const students = (bundle.students || []).map(stuFromDB);
    const chats = { _bc: [] };
    students.forEach(s => { chats[s.id] = []; });
    (bundle.messages || []).forEach(m => {
      _savedMsgIds.add(m.id);
      const msg = msgFromDB(m);
      if (m.thread_id === '_bc') chats._bc.push(msg);
      else { if (!chats[m.thread_id]) chats[m.thread_id] = []; chats[m.thread_id].push(msg); }
    });
    const asByTask = {};
    (bundle.task_assignments || []).forEach(ta => {
      (asByTask[ta.task_id] = asByTask[ta.task_id] || []).push(ta);
    });
    const tasks = (bundle.tasks || []).map(t => {
      const assignees = {}, completedBy = {};
      (asByTask[t.id] || []).forEach(ta => {
        assignees[ta.student_id] = ta.status;
        if (ta.completed_date || ta.completed_time)
          completedBy[ta.student_id] = { date: ta.completed_date || '', time: ta.completed_time || '' };
      });
      return { id: t.id, title: t.title, desc: t.description || '', type: t.type || 'onetime',
        deadline: t.deadline || '', created: t.created_at || '', assignees, completedBy };
    });
    const goals = {};
    (bundle.goals || []).forEach(g => {
      (goals[g.student_id] = goals[g.student_id] || []).push(
        { id: g.id, title: g.title, cat: g.cat, deadline: g.deadline || '',
          note: g.note || '', done: g.done || false, created: g.created_at || '' });
    });
    const qByQ = {}, aByQ = {};
    (bundle.quiz_questions || []).forEach(q => {
      (qByQ[q.quiz_id] = qByQ[q.quiz_id] || []).push({ id: q.id, type: q.type, text: q.text,
        options: q.options || [], correctAnswer: q.correct_answer, marks: q.marks || 1,
        uploadInstructions: q.upload_instructions });
    });
    (bundle.quiz_assignees || []).forEach(qa => {
      (aByQ[qa.quiz_id] = aByQ[qa.quiz_id] || []).push(qa.student_id);
    });
    const quizzes = (bundle.quizzes || []).map(q => ({
      id: q.id, title: q.title, subject: q.subject || '', desc: q.description || '',
      timeLimit: q.time_limit || 30, passPercent: q.pass_percent || 60,
      deadline: q.deadline || '', created: q.created_at || '',
      questions: qByQ[q.id] || [], assigneeIds: aByQ[q.id] || [] }));
    const submissions = (bundle.quiz_submissions || []).map(qs => ({
      id: qs.id, quizId: qs.quiz_id, studentId: qs.student_id, studentName: qs.student_name || '',
      answers: qs.answers || {}, score: qs.score || 0, total: qs.total || 0,
      passed: qs.passed || false, needsManualGrade: qs.needs_manual_grade || false }));
    const docs = (bundle.documents || []).map(d => ({
      id: d.id, studentId: d.student_id, studentName: d.student_name || '',
      fileName: d.file_name, fileType: d.file_type || '', fileSize: d.file_size || 0,
      category: d.category || 'general', note: d.note || '',
      storage_path: d.storage_path, fileUrl: d.file_url, read: d.is_read || false,
      uploadedAt: d.uploaded_at || '', reviewStatus: d.review_status || 'done' }));
    const academic = {}, tnotes = {};
    (bundle.academic_history || []).forEach(ah => {
      (academic[ah.student_id] = academic[ah.student_id] || []).push(
        { id: ah.id, yearClass: ah.year_class, grade: ah.grade, addedAt: ah.added_at || '' });
    });
    (bundle.teacher_notes || []).forEach(tn => {
      (tnotes[tn.student_id] = tnotes[tn.student_id] || []).push(
        { id: tn.id, text: tn.text, date: tn.note_date || '', time: tn.note_time || '' });
    });
    mem.core = { teacher: { name: cfg.teacher_name || '', madrasa: cfg.madrasa_name || 'وقف المدينة' },
      students, chats, tasks };
    mem.goals = goals; mem.exams = { quizzes, submissions };
    mem.docs = docs; mem.academic = academic; mem.tnotes = tnotes;
    mem.teacherPin = cfg.teacher_pin ? String(cfg.teacher_pin) : null;
    mem.completions = Array.isArray(bundle.completions)
      ? bundle.completions.map(tc => ({
        id: tc.id,
        task_id: tc.task_id,
        student_id: tc.student_id,
        date: (tc.comp_date || tc.date || ''),
        status: tc.status || 'done',
        completed_at: tc.completed_at || null,
        note: tc.note || '',
        created_at: tc.created_at || null,
      }))
      : [];
    mem.dailyScheduleByStudent = buildDailyScheduleByStudent(bundle);
    mem.noteCategories = (bundle.note_categories || []).map((c, i) => ({
      id: c.id, label: c.label || '', sort: typeof c.sort_order === 'number' ? c.sort_order : i,
    }));
    const notesBy = {};
    (bundle.student_notes || []).forEach(n => {
      const sid = n.student_id;
      if (!sid) return;
      (notesBy[sid] = notesBy[sid] || []).push({
        id: n.id, studentId: sid,
        categoryId: n.category_id || 'general',
        date: n.note_date || '', time: n.note_time || '',
        title: n.title || '', text: n.text || '',
      });
    });
    mem.studentNotesByStudent = notesBy;
  }

  // ── Assemble relational student bundle → mem ─────────────────
  function assembleStudentBundle(bundle) {
    const stu = bundle.student ? stuFromDB(bundle.student) : null;
    const cfg = bundle.config || {};
    const chats = { _bc: [] };
    if (stu) chats[stu.id] = [];
    (bundle.messages || []).forEach(m => {
      _savedMsgIds.add(m.id);
      const msg = msgFromDB(m);
      if (m.thread_id === '_bc') chats._bc.push(msg);
      else { if (!chats[m.thread_id]) chats[m.thread_id] = []; chats[m.thread_id].push(msg); }
    });
    const tasks = (bundle.tasks || []).filter(Boolean).map(item => {
      const t = item.task || item, ta = item.assignment || {};
      return { id: t.id, title: t.title, desc: t.description || '', type: t.type || 'onetime',
        deadline: t.deadline || '', created: t.created_at || '',
        assignees: stu ? { [stu.id]: ta.status || 'pending' } : {},
        completedBy: stu && (ta.completed_date || ta.completed_time)
          ? { [stu.id]: { date: ta.completed_date || '', time: ta.completed_time || '' } } : {} };
    });
    const goals = {};
    (bundle.goals || []).forEach(g => {
      (goals[g.student_id] = goals[g.student_id] || []).push(
        { id: g.id, title: g.title, cat: g.cat, deadline: g.deadline || '',
          note: g.note || '', done: g.done || false, created: g.created_at || '' });
    });
    const quizzes = (bundle.quizzes || []).filter(Boolean).map(item => {
      const q = item.quiz || item;
      return { id: q.id, title: q.title, subject: q.subject || '', desc: q.description || '',
        timeLimit: q.time_limit || 30, passPercent: q.pass_percent || 60,
        deadline: q.deadline || '', created: q.created_at || '',
        questions: (item.questions || []).map(qq => ({ id: qq.id, type: qq.type, text: qq.text,
          options: qq.options || [], correctAnswer: qq.correct_answer, marks: qq.marks || 1 })),
        assigneeIds: stu ? [stu.id] : [] };
    });
    const submissions = (bundle.quizzes || []).filter(Boolean)
      .map(i => i.submission).filter(Boolean).map(qs => ({
        id: qs.id, quizId: qs.quiz_id, studentId: qs.student_id, studentName: qs.student_name || '',
        answers: qs.answers || {}, score: qs.score || 0, total: qs.total || 0,
        passed: qs.passed || false, needsManualGrade: qs.needs_manual_grade || false }));
    const docs = (bundle.documents || []).map(d => ({
      id: d.id, studentId: d.student_id, studentName: d.student_name || '',
      fileName: d.file_name, fileType: d.file_type || '', fileSize: d.file_size || 0,
      category: d.category || 'general', note: d.note || '',
      storage_path: d.storage_path, fileUrl: d.file_url, read: d.is_read || false,
      uploadedAt: d.uploaded_at || '', reviewStatus: d.review_status || 'done' }));
    const academic = {};
    (bundle.academic_history || []).forEach(ah => {
      (academic[ah.student_id] = academic[ah.student_id] || []).push(
        { id: ah.id, yearClass: ah.year_class, grade: ah.grade, addedAt: ah.added_at || '' });
    });
    mem.core = { teacher: { name: cfg.teacher_name || '', madrasa: cfg.madrasa || 'وقف المدينة' },
      students: stu ? [stu] : [], chats, tasks };
    mem.goals = goals; mem.exams = { quizzes, submissions };
    mem.docs = docs; mem.academic = academic; mem.tnotes = {};
    mem.teacherPin = null;
    mem.completions = Array.isArray(bundle.completions)
      ? bundle.completions.map(tc => ({
        id: tc.id,
        task_id: tc.task_id,
        student_id: tc.student_id,
        date: (tc.comp_date || tc.date || ''),
        status: tc.status || 'done',
        completed_at: tc.completed_at || null,
        note: tc.note || '',
        created_at: tc.created_at || null,
      }))
      : [];
    mem.dailySchedule = stu ? buildStudentDailySchedule(bundle, stu.id) : { rows: [], pending: null };
    mem.noteCategories = (bundle.note_categories || []).map((c, i) => ({
      id: c.id, label: c.label || '', sort: typeof c.sort_order === 'number' ? c.sort_order : i,
    }));
    const notesBy = {};
    (bundle.student_notes || []).forEach(n => {
      const sid = n.student_id || (stu && stu.id);
      if (!sid) return;
      (notesBy[sid] = notesBy[sid] || []).push({
        id: n.id, studentId: sid,
        categoryId: n.category_id || 'general',
        date: n.note_date || '', time: n.note_time || '',
        title: n.title || '', text: n.text || '',
      });
    });
    mem.studentNotesByStudent = notesBy;
  }

  // ── Schedule / flush ─────────────────────────────────────────
  function schedule(key, getter) {
    const sb = getClient(); if (!sb) return;
    clearTimeout(timers[key]);
    timers[key] = setTimeout(async () => {
      delete timers[key];
      try { await _write.saveKVImpl(sb, key, typeof getter === 'function' ? getter() : getter, usesSecureKv()); }
      catch (e) { console.error('RemoteSync save failed:', key, e); }
    }, DEBOUNCE_MS);
  }

  async function flushKey(key, value) {
    const sb = getClient(); if (!sb) return;
    clearTimeout(timers[key]); delete timers[key];
    await _write.saveKVImpl(sb, key, value, usesSecureKv());
  }

  async function flushAllFromMem() {
    const sb = getClient(); if (!sb) return;
    try {
      await _write.saveCore(sb, mem.core);
      await _write.saveGoals(sb, mem.goals);
      await _write.saveExams(sb, mem.exams);
      await _write.saveDocs(sb, mem.docs);
    } catch (e) { console.error('flushAllFromMem:', e); }
  }

  async function markDocReviewedRemote(docId) {
    if (!usesSecureKv()) return;
    const sb = getClient(); if (!sb) throw new Error('remote_unavailable');
    const pin = _teacherPin; if (!pin) throw new Error('missing_pin');
    await rpcOrThrow(sb, 'madrasa_rel_mark_doc_reviewed', { p_teacher_pin: pin, p_doc_id: docId });
    const d = (mem.docs || []).find(x => x.id === docId);
    if (d) { d.reviewStatus = 'done'; d.read = true; }
  }

  async function markMessagesReadRemote(threadId, roleStr) {
    const sb = getClient(); if (!sb || !usesSecureKv()) return;
    const r = roleStr || role();
    const pin = r === 'teacher' ? _teacherPin : _studentPin;
    if (!pin) return;
    try {
      await rpcOrThrow(sb, 'madrasa_rel_mark_messages_read', { p_pin: pin, p_role: r, p_thread_id: threadId });
      applyReadReceiptPatch(threadId, r);
      sendReadReceiptBroadcast(threadId, r);
    }
    catch (e) { console.warn('markMessagesReadRemote:', e); }
  }

  // ── Bootstrap ────────────────────────────────────────────────
  async function _publicBranding(sb) {
    const { data, error } = await sb.rpc('madrasa_rel_public_branding');
    if (error) throw error;
    return data?.madrasa ? String(data.madrasa) : 'وقف المدينة';
  }

  async function bootstrapTeacherIdle() {
    const sb = getClient(); if (!sb) throw new Error('Supabase client unavailable');
    const madrasa = await _publicBranding(sb);
    mem.core = { teacher: { name: '', madrasa }, students: [], chats: { _bc: [] }, tasks: [], allowEmptyStudents: true };
    mem.goals = {}; mem.exams = { quizzes: [], submissions: [] };
    mem.docs = []; mem.academic = {}; mem.tnotes = {};
    mem.teacherPin = null; mem.lockHints = []; _teacherPin = ''; mem.loaded = true;
    mem.dailyScheduleByStudent = {};
    mem.noteCategories = []; mem.studentNotesByStudent = {};
  }

  async function bootstrapStudentIdle() {
    const sb = getClient(); if (!sb) throw new Error('Supabase client unavailable');
    const madrasa = await _publicBranding(sb);
    mem.core = { teacher: { name: '', madrasa }, students: [], chats: { _bc: [] }, tasks: [] };
    mem.goals = {}; mem.exams = { quizzes: [], submissions: [] };
    mem.docs = []; mem.academic = {}; mem.tnotes = {};
    mem.teacherPin = null; _studentWaqf = ''; _studentPin = ''; _studentId = '';
    const { data: hints, error: hErr } = await sb.rpc('madrasa_rel_student_lock_hints');
    mem.lockHints = hErr ? [] : (Array.isArray(hints) ? hints : []);
    mem.loaded = true;
    mem.dailySchedule = { rows: [], pending: null };
    mem.noteCategories = []; mem.studentNotesByStudent = {};
  }

  async function bootstrapLegacy() {
    const sb = getClient(); if (!sb) throw new Error('Supabase client unavailable');
    const keys = ['core', 'goals', 'exams', 'docs_meta', 'academic', 'tnotes', 'teacher_pin'];
    const rows = await Promise.all(keys.map(k =>
      sb.from('waqf_app_kv').select('value').eq('key', k).maybeSingle().then(r => r.data?.value)));
    const [core, goals, exams, docs, academic, tnotes, tp] = rows;
    mem.core = core || null; mem.goals = goals || {};
    mem.exams = exams || { quizzes: [], submissions: [] };
    mem.docs = Array.isArray(docs) ? docs : [];
    mem.academic = academic || {}; mem.tnotes = tnotes || {};
    mem.teacherPin = tp?.pin ? String(tp.pin) : null;
    mem.lockHints = []; mem.loaded = true;
  }

  function bootstrap() {
    if (!usesSecureKv()) return bootstrapLegacy();
    if (role() === 'teacher') return bootstrapTeacherIdle();
    if (role() === 'student') return bootstrapStudentIdle();
    return bootstrapLegacy();
  }

  async function fetchGroupsRemote() {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb) return;
    try {
      const { data, error } = await sb.rpc('madrasa_rel_get_groups', { p_teacher_pin: _teacherPin });
      if (error || !data) return;
      const raw = typeof data === 'string' ? JSON.parse(data) : data;
      mem.groups = (Array.isArray(raw) ? raw : []).map(g => ({
        id: g.id, name: g.name,
        studentIds: Array.isArray(g.student_ids) ? g.student_ids : [],
        createdAt: g.created_at || '',
      }));
    } catch (e) { console.warn('fetchGroupsRemote:', e); }
  }

  async function upsertGroupRemote(g) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb) return;
    await rpcOrThrow(sb, 'madrasa_rel_upsert_group', {
      p_teacher_pin: _teacherPin,
      p_id: g.id, p_name: g.name,
      p_student_ids: g.studentIds || [],
    });
  }

  async function deleteGroupRemote(gid) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb) return;
    await rpcOrThrow(sb, 'madrasa_rel_delete_group', { p_teacher_pin: _teacherPin, p_group_id: gid });
  }

  async function fetchDiaryRemote() {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb) return;
    try {
      const { data, error } = await sb.rpc('madrasa_rel_get_diary', { p_teacher_pin: _teacherPin });
      if (error || !data) return;
      const raw = typeof data === 'string' ? JSON.parse(data) : data;
      mem.diary = (Array.isArray(raw) ? raw : []).map(d => ({
        id: d.id, date: d.date || '', time: d.time || '',
        text: d.text || '', edited: d.edited || null,
      }));
    } catch (e) { console.warn('fetchDiaryRemote:', e); }
  }

  async function upsertDiaryRemote(entry) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb) return;
    await rpcOrThrow(sb, 'madrasa_rel_upsert_diary', {
      p_teacher_pin: _teacherPin,
      p_id: entry.id, p_date: entry.date || '', p_time: entry.time || '',
      p_text: entry.text || '', p_edited: entry.edited || null,
    });
  }

  async function deleteDiaryRemote(id) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb) return;
    await rpcOrThrow(sb, 'madrasa_rel_delete_diary', { p_teacher_pin: _teacherPin, p_id: id });
  }

  async function unlockTeacherWithPin(pin) {
    const sb = getClient(); if (!sb) throw new Error('Supabase client unavailable');
    const { data, error } = await sb.rpc('madrasa_rel_teacher_bootstrap', { p_teacher_pin: pin });
    if (error) throw error;
    assembleTeacherBundle(data);
    _teacherPin = (mem.teacherPin && mem.teacherPin !== '') ? mem.teacherPin : String(pin);
    mem.loaded = true;
    void fetchGroupsRemote();
    void fetchDiaryRemote();
  }

  async function unlockStudentWithWaqfPin(waqfRaw, pin) {
    const sb = getClient(); if (!sb) throw new Error('Supabase client unavailable');
    const waqfNorm = normalizeWaqfForRpc(waqfRaw);
    const { data, error } = await sb.rpc('madrasa_rel_student_bootstrap',
      { p_waqf: waqfNorm, p_pin: String(pin || '') });
    if (error) throw error;
    assembleStudentBundle(data);
    mem.teacherPin = null;
    const stu = mem.core?.students?.[0];
    _studentWaqf = stu?.waqfId || waqfNorm;
    _studentPin = String(pin || '');
    _studentId = stu?.id || '';
    mem.lockHints = []; mem.loaded = true;
  }

  async function refreshStudentLockHints() {
    // lock screen-এ কেউ login না করলেও hints দরকার — role check বাদ দিই
    if (!isRemote()) return;
    const sb = getClient(); if (!sb) return;
    const { data, error } = await sb.rpc('madrasa_rel_student_lock_hints');
    mem.lockHints = error ? [] : (Array.isArray(data) ? data : []);
  }

  async function pullRemoteSnapshot() {
    if (!isRemote() || !mem.loaded) return;
    const sb = getClient(); if (!sb) return;
    try {
      if (usesSecureKv() && role() === 'teacher' && _teacherPin) {
        const { data, error } = await sb.rpc('madrasa_rel_teacher_bootstrap', { p_teacher_pin: _teacherPin });
        if (!error) assembleTeacherBundle(data);
      } else if (usesSecureKv() && role() === 'student' && _studentWaqf && _studentPin) {
        const { data, error } = await sb.rpc('madrasa_rel_student_bootstrap',
          { p_waqf: _studentWaqf, p_pin: _studentPin });
        if (!error) { assembleStudentBundle(data); mem.teacherPin = null; }
      } else if (usesSecureKv() && role() === 'student') {
        await refreshStudentLockHints();
      }
    } catch (e) { console.warn('pullRemoteSnapshot:', e); }
    if (w.dispatchEvent) w.dispatchEvent(new CustomEvent('madrasa-remote-sync'));
  }

  function applyRealtimeMessagePatch(payload) {
    const row = payload && payload.new;
    if (!mem.loaded || !mem.core || !mem.core.chats || !row || payload.eventType !== 'UPDATE') return false;
    const threadId = row.thread_id === '_bc' ? '_bc' : row.thread_id;
    const thread = mem.core.chats[threadId];
    if (!Array.isArray(thread)) return false;
    const idx = thread.findIndex(m => m && m.id === row.id);
    if (idx < 0) return false;
    thread[idx] = msgFromDB(row);
    _savedMsgIds.add(row.id);
    if (w.dispatchEvent) w.dispatchEvent(new CustomEvent('madrasa-remote-sync'));
    return true;
  }

  function applyReadReceiptPatch(threadId, readerRole) {
    if (!mem.loaded || !mem.core || !mem.core.chats || !threadId) return false;
    const thread = mem.core.chats[threadId === '_broadcast' ? '_bc' : threadId];
    if (!Array.isArray(thread)) return false;
    const msgRole = readerRole === 'teacher' ? 'in' : 'out';
    let changed = false;
    thread.forEach(m => {
      if (m && m.role === msgRole && !m.read) {
        m.read = true;
        changed = true;
      }
    });
    if (changed && w.dispatchEvent) w.dispatchEvent(new CustomEvent('madrasa-remote-sync'));
    return changed;
  }

  function sendReadReceiptBroadcast(threadId, readerRole) {
    if (!realtimeChannel || !threadId || !readerRole) return;
    try {
      const sent = realtimeChannel.send({
        type: 'broadcast',
        event: 'read_receipt',
        payload: { threadId, readerRole },
      });
      if (sent && typeof sent.catch === 'function') sent.catch(e => console.warn('sendReadReceiptBroadcast:', e));
    } catch (e) { console.warn('sendReadReceiptBroadcast:', e); }
  }

  function startRealtimeSync() {
    if (!isRemote()) return;
    const sb = getClient(); if (!sb || realtimeChannel) return;
    const pull = () => setTimeout(() => void pullRemoteSnapshot(), 200);
    const onMessageChange = (payload) => {
      if (applyRealtimeMessagePatch(payload)) {
        setTimeout(() => void pullRemoteSnapshot(), 1200);
        return;
      }
      pull();
    };
    realtimeChannel = sb.channel('madrasa_rel_changes')
      .on('broadcast', { event: 'read_receipt' }, payload => {
        const p = payload && payload.payload;
        if (p) applyReadReceiptPatch(p.threadId, p.readerRole);
      })
      .on('postgres_changes', { event: '*', schema: 'public', table: 'messages' }, onMessageChange)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'students' }, pull)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'tasks' }, pull)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'task_assignments' }, pull)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'task_completions' }, pull)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'quizzes' }, pull)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'daily_schedule_rows' }, pull)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'daily_schedule_proposals' }, pull)
      .subscribe();
  }

  // ── File storage ──────────────────────────────────────────────
  async function uploadFile(path, file) {
    if (!file || typeof file.size !== 'number' || file.size > 10 * 1024 * 1024) throw new Error('file_too_large');
    const sb = getClient();
    const { error } = await sb.storage.from(BUCKET).upload(path, file,
      { upsert: true, contentType: file.type || 'application/octet-stream' });
    if (error) throw error;
    const { data, error: e2 } = await sb.storage.from(BUCKET).createSignedUrl(path, SIGNED_URL_SEC);
    if (e2) throw e2;
    return { url: data.signedUrl, path };
  }

  async function getSignedUrlForPath(path) {
    const sb = getClient(); if (!sb || !path) return null;
    const { data, error } = await sb.storage.from(BUCKET).createSignedUrl(path, SIGNED_URL_SEC);
    if (error) { console.error('Signed URL failed:', path, error); return null; }
    return data.signedUrl;
  }

  function consumeUploadResult(res) {
    if (res && typeof res === 'object' && res.url) return { fileUrl: res.url, storagePath: res.path };
    return { fileUrl: res, storagePath: null };
  }

  async function upsertCompletionRemote(row) {
    if (!usesSecureKv()) return;
    const sb = getClient(); if (!sb) return;
    const r = role(), pin = r === 'teacher' ? _teacherPin : _studentPin;
    return _write.upsertCompletionRemote(sb, row, pin, r);
  }

  async function deleteCompletionRemote(tid, sid, date) {
    if (!usesSecureKv()) return;
    const sb = getClient(); if (!sb) return;
    const r = role(), pin = r === 'teacher' ? _teacherPin : _studentPin;
    return _write.deleteCompletionRemote(sb, tid, sid, date, pin, r);
  }

  async function clearStudentDataRemote(sid) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb) throw new Error('remote_unavailable');
    await rpcOrThrow(sb, 'madrasa_rel_clear_student_data', { p_teacher_pin: _teacherPin, p_student_id: sid });
  }

  async function deleteStudentRemote(sid) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb) throw new Error('remote_unavailable');
    await rpcOrThrow(sb, 'madrasa_rel_delete_student', { p_teacher_pin: _teacherPin, p_student_id: sid });
    if (Array.isArray(mem.lockHints)) mem.lockHints = mem.lockHints.filter(s => s.id !== sid);
  }

  async function deleteQuizRemote(qid) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb) throw new Error('remote_unavailable');
    if (!qid) throw new Error('invalid_quiz');
    await rpcOrThrow(sb, 'madrasa_rel_delete_quiz', { p_teacher_pin: _teacherPin, p_quiz_id: qid });
  }

  async function getBroadcastReadCounts() {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return [];
    const sb = getClient(); if (!sb) return [];
    try {
      const { data, error } = await sb.rpc('madrasa_rel_broadcast_read_counts', { p_teacher_pin: _teacherPin });
      if (error) return [];
      return Array.isArray(data) ? data : [];
    } catch { return []; }
  }

  async function deleteMessageRemote(mid) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb || !mid) return;
    try {
      await rpcOrThrow(sb, 'madrasa_rel_delete_message', { p_teacher_pin: _teacherPin, p_message_id: mid });
    } catch (e) { console.warn('deleteMessageRemote:', e); }
  }

  async function updateMessageTextRemote(mid, text) {
    if (!usesSecureKv() || !mid) return;
    const sb = getClient(); if (!sb) throw new Error('remote_unavailable');
    const r = role();
    const pin = r === 'teacher' ? _teacherPin : _studentPin;
    if (!pin) throw new Error('missing_pin');
    await rpcOrThrow(sb, 'madrasa_rel_update_message_text', {
      p_pin: pin,
      p_role: r === 'teacher' ? 'teacher' : 'student',
      p_message_id: mid,
      p_new_text: String(text || ''),
    });
  }

  async function updateStudentPinRemote(newPin) {
    if (!usesSecureKv() || role() !== 'student' || !_studentWaqf || !_studentPin) return;
    const sb = getClient(); if (!sb) return;
    await rpcOrThrow(sb, 'madrasa_rel_student_update_pin', {
      p_waqf: normalizeWaqfForRpc(_studentWaqf),
      p_old_pin: String(_studentPin),
      p_new_pin: String(newPin),
    });
    _studentPin = String(newPin);
  }

  async function sendMessageRemote(threadId, msg) {
    if (!usesSecureKv()) return;
    const sb = getClient(); if (!sb) throw new Error('remote_unavailable');
    const r = role();
    const pin = r === 'teacher' ? _teacherPin : _studentPin;
    if (!pin) throw new Error('missing_pin');
    if (!msg || !msg.id) throw new Error('invalid_message');
    if (msg._skipRemote) return;
    const { id, role: msgRole, type, text, read, time, ...extra } = msg;
    const p_message = { id, thread_id: threadId,
      role: msgRole || (r === 'teacher' ? 'out' : 'in'),
      type: type || 'text', text: text || '',
      extra, is_read: read || false, sent_at: null,
      ...(r === 'student' ? { thread_id_waqf: _studentWaqf } : {}),
    };
    await rpcOrThrow(sb, 'madrasa_rel_insert_message', { p_pin: pin, p_role: r, p_message });
    _savedMsgIds.add(id);
  }

  async function deleteOwnMessageRemote(mid) {
    if (!usesSecureKv() || !mid) return;
    const sb = getClient(); if (!sb) throw new Error('remote_unavailable');
    const r = role();
    const pin = r === 'teacher' ? _teacherPin : _studentPin;
    if (!pin) throw new Error('missing_pin');
    await rpcOrThrow(sb, 'madrasa_rel_delete_own_message', {
      p_pin: pin,
      p_role: r === 'teacher' ? 'teacher' : 'student',
      p_message_id: mid,
    });
  }

  async function saveTaskRemote(task) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb || !task) return;
    const p_task = { id: task.id, title: task.title, description: task.desc || '',
      type: task.type || 'onetime', deadline: task.deadline || '', created_at: task.created || '' };
    await rpcOrThrow(sb, 'madrasa_rel_upsert_task', {
      p_teacher_pin: _teacherPin, p_task,
      p_assignee_ids: Object.keys(task.assignees || {}),
    });
    for (const [sid, status] of Object.entries(task.assignees || {})) {
      const cb = (task.completedBy || {})[sid] || {};
      await rpcOrThrow(sb, 'madrasa_rel_update_task_status', {
        p_pin: _teacherPin, p_role: 'teacher',
        p_task_id: task.id, p_student_id: sid, p_status: status,
        p_completed_date: cb.date || null, p_completed_time: cb.time || null,
      });
    }
  }

  async function saveQuizRemote(quiz) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin || !quiz) return;
    const sb = getClient(); if (!sb) return;
    await _write.saveExams(sb, { quizzes: [quiz], submissions: [] });
  }

  async function saveStudentRemote(student) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb || !student) return;
    const stuToDB = s => ({
      id: s.id, waqf_id: s.waqfId, name: s.name, cls: s.cls || '', roll: s.roll || '',
      pin: s.pin, color: s.color || '#128C7E', note: s.note || '',
      father_name: s.fatherName || '', father_occupation: s.fatherOccupation || '',
      contact: s.contact || '', district: s.district || '', upazila: s.upazila || '',
      blood_group: s.bloodGroup || '', enrollment_date: s.enrollmentDate || '',
      responsibility: s.responsibility || '',
    });
    await rpcOrThrow(sb, 'madrasa_rel_upsert_student', { p_teacher_pin: _teacherPin, p_student: stuToDB(student) });
  }

  async function deleteTaskRemote(tid) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb) throw new Error('remote_unavailable');
    if (!tid) throw new Error('invalid_task');
    await rpcOrThrow(sb, 'madrasa_rel_delete_task', { p_teacher_pin: _teacherPin, p_task_id: tid });
    if (mem.core && Array.isArray(mem.core.tasks))
      mem.core.tasks = mem.core.tasks.filter(t => t.id !== tid);
  }

  async function submitDailyScheduleProposalRemote(rows) {
    if (!usesSecureKv() || role() !== 'student' || !_studentWaqf || !_studentPin) return;
    const sb = getClient(); if (!sb) return;
    try {
      await rpcOrThrow(sb, 'madrasa_rel_submit_daily_schedule_proposal', {
        p_waqf: normalizeWaqfForRpc(_studentWaqf),
        p_pin: String(_studentPin || ''),
        p_rows: rows,
      });
      await pullRemoteSnapshot();
    } catch (e) { console.warn('submitDailyScheduleProposalRemote:', e); throw e; }
  }

  async function setDailyScheduleTeacherRemote(sid, rows) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb) return;
    try {
      await rpcOrThrow(sb, 'madrasa_rel_set_daily_schedule', {
        p_teacher_pin: _teacherPin,
        p_student_id: sid,
        p_rows: rows,
      });
      await pullRemoteSnapshot();
    } catch (e) { console.warn('setDailyScheduleTeacherRemote:', e); throw e; }
  }

  async function upsertTeacherNoteRemote(note, sid) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb) return;
    await rpcOrThrow(sb, 'madrasa_rel_upsert_teacher_note', {
      p_teacher_pin: _teacherPin,
      p_id: note.id,
      p_student_id: sid,
      p_text: note.text || '',
      p_date: note.date || null,
      p_time: note.time || '',
      p_edited_at: note.edited || null,
    });
  }

  async function deleteTeacherNoteRemote(nid) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb || !nid) return;
    await rpcOrThrow(sb, 'madrasa_rel_delete_teacher_note', { p_teacher_pin: _teacherPin, p_id: nid });
  }

  async function updateConfigRemote(info) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb) return;
    await rpcOrThrow(sb, 'madrasa_rel_update_config', {
      p_teacher_pin: _teacherPin,
      p_teacher_name: String(info?.name || ''),
      p_madrasa_name: String(info?.madrasa || ''),
    });
  }

  async function upsertAcademicHistoryRemote(sid, record) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb) return;
    await rpcOrThrow(sb, 'madrasa_rel_upsert_academic_history', {
      p_teacher_pin: _teacherPin,
      p_student_id: sid,
      p_record: {
        id: record.id,
        year_class: record.yearClass || '',
        grade: record.grade || '',
        added_at: record.addedAt || '',
      },
    });
  }

  async function deleteAcademicHistoryRemote(sid, id) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb) return;
    await rpcOrThrow(sb, 'madrasa_rel_delete_academic_history', {
      p_teacher_pin: _teacherPin,
      p_student_id: sid,
      p_id: id,
    });
  }

  async function upsertGoalRemote(goal, sid) {
    if (!usesSecureKv() || role() !== 'student' || !_studentPin) return;
    const sb = getClient(); if (!sb) return;
    await rpcOrThrow(sb, 'madrasa_rel_upsert_goal', {
      p_pin: _studentPin,
      p_student_id: sid,
      p_goal: {
        id: goal.id,
        title: goal.title,
        cat: goal.cat || 'other',
        deadline: goal.deadline || '',
        note: goal.note || '',
        done: !!goal.done,
        created_at: goal.created || '',
      },
    });
  }

  async function deleteGoalRemote(sid, gid) {
    if (!usesSecureKv() || role() !== 'student' || !_studentPin) return;
    const sb = getClient(); if (!sb) return;
    await rpcOrThrow(sb, 'madrasa_rel_delete_goal', {
      p_pin: _studentPin,
      p_student_id: sid,
      p_goal_id: gid,
    });
  }

  function _patchNoteInMem(note, sid) {
    const by = mem.studentNotesByStudent || (mem.studentNotesByStudent = {});
    const list = by[sid] || (by[sid] = []);
    const ix = list.findIndex(n => n.id === note.id);
    const row = {
      id: note.id, studentId: sid,
      categoryId: note.categoryId || 'general',
      date: note.date || '', time: note.time || '',
      title: note.title || '', text: note.text || '',
    };
    if (ix >= 0) list[ix] = row; else list.unshift(row);
  }

  async function upsertStudentNoteRemote(note, sid) {
    if (!usesSecureKv() || role() !== 'student' || !_studentPin) {
      throw new Error('note_save_unavailable');
    }
    const sb = getClient();
    if (!sb) throw new Error('note_save_unavailable');
    await rpcOrThrow(sb, 'madrasa_rel_upsert_student_note', {
      p_pin: _studentPin,
      p_student_id: sid,
      p_note: {
        id: note.id,
        category_id: note.categoryId || 'general',
        date: note.date || '',
        time: note.time || '',
        title: note.title || '',
        text: note.text || '',
      },
    });
    _patchNoteInMem(note, sid);
  }

  async function deleteStudentNoteRemote(sid, noteId) {
    if (!usesSecureKv()) throw new Error('note_delete_unavailable');
    const sb = getClient();
    if (!sb) throw new Error('note_delete_unavailable');
    if (role() === 'student' && _studentPin) {
      await rpcOrThrow(sb, 'madrasa_rel_delete_student_note', {
        p_pin: _studentPin,
        p_student_id: sid,
        p_note_id: noteId,
      });
    } else if (role() === 'teacher' && _teacherPin) {
      await rpcOrThrow(sb, 'madrasa_rel_teacher_delete_student_note', {
        p_teacher_pin: _teacherPin,
        p_note_id: noteId,
      });
    } else {
      throw new Error('note_delete_unavailable');
    }
    const by = mem.studentNotesByStudent || {};
    if (by[sid]) by[sid] = by[sid].filter(n => n.id !== noteId);
  }

  async function upsertNoteCategoryRemote(cat) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb) return;
    await rpcOrThrow(sb, 'madrasa_rel_upsert_note_category', {
      p_teacher_pin: _teacherPin,
      p_id: cat.id,
      p_label: cat.label,
      p_sort_order: typeof cat.sort === 'number' ? cat.sort : null,
    });
    const list = mem.noteCategories || (mem.noteCategories = []);
    const ix = list.findIndex(c => c.id === cat.id);
    const row = { id: cat.id, label: cat.label, sort: typeof cat.sort === 'number' ? cat.sort : list.length };
    if (ix >= 0) list[ix] = row; else list.push(row);
  }

  async function deleteNoteCategoryRemote(id) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb) return;
    await rpcOrThrow(sb, 'madrasa_rel_delete_note_category', {
      p_teacher_pin: _teacherPin,
      p_id: id,
    });
    mem.noteCategories = (mem.noteCategories || []).filter(c => c.id !== id);
    const by = mem.studentNotesByStudent || {};
    Object.keys(by).forEach(sid => {
      by[sid] = (by[sid] || []).map(n =>
        n.categoryId === id ? { ...n, categoryId: 'general' } : n
      );
    });
  }

  async function deleteDocumentRemote(id) {
    if (!usesSecureKv() || !id) return;
    const sb = getClient(); if (!sb) return;
    const r = role();
    const pin = r === 'teacher' ? _teacherPin : _studentPin;
    if (!pin) return;
    await rpcOrThrow(sb, 'madrasa_rel_delete_document', {
      p_pin: pin,
      p_role: r,
      p_doc_id: id,
    });
  }

  async function saveDocumentRemote(doc) {
    if (!usesSecureKv() || !doc) return;
    const sb = getClient(); if (!sb) return;
    await _write.saveDocs(sb, [doc]);
  }

  async function submitQuizRemote(submission) {
    if (!usesSecureKv() || role() !== 'student' || !_studentPin || !submission) return;
    const sb = getClient(); if (!sb) return;
    await rpcOrThrow(sb, 'madrasa_rel_submit_quiz', {
      p_student_pin: _studentPin,
      p_student_id: submission.studentId,
      p_submission: {
        id: submission.id,
        quiz_id: submission.quizId,
        student_name: submission.studentName || '',
        answers: submission.answers || {},
        score: submission.score || 0,
        total: submission.total || 0,
        passed: !!submission.passed,
        needs_manual_grade: !!submission.needsManualGrade,
        submitted_at: submission.submittedAt || null,
      },
    });
  }

  async function updateQuizScoreRemote(submissionId, score) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb) return;
    await rpcOrThrow(sb, 'madrasa_rel_update_quiz_score', {
      p_teacher_pin: _teacherPin,
      p_submission_id: submissionId,
      p_score: Number(score) || 0,
    });
  }

  async function updateTaskStatusRemote(taskId, sid, status, completed) {
    if (!usesSecureKv()) return;
    const sb = getClient(); if (!sb) return;
    const r = role();
    const pin = r === 'teacher' ? _teacherPin : _studentPin;
    if (!pin) return;
    await rpcOrThrow(sb, 'madrasa_rel_update_task_status', {
      p_pin: pin,
      p_role: r,
      p_task_id: taskId,
      p_student_id: sid,
      p_status: status,
      p_completed_date: completed?.date || null,
      p_completed_time: completed?.time || null,
    });
  }

  async function completeOnetimeTaskRemote(row) {
    if (!usesSecureKv() || !row) return;
    const sb = getClient(); if (!sb) return;
    const r = role();
    const pin = r === 'teacher' ? _teacherPin : _studentPin;
    if (!pin) return;
    await rpcOrThrow(sb, 'madrasa_rel_complete_onetime_task', {
      p_pin: pin,
      p_role: r,
      p_completion_id: row.id,
      p_task_id: row.task_id,
      p_student_id: row.student_id,
      p_date: row.date,
      p_completed_at: row.completed_at || null,
    });
  }

  async function resolveDailyScheduleProposalRemote(sid, approve, note) {
    if (!usesSecureKv() || role() !== 'teacher' || !_teacherPin) return;
    const sb = getClient(); if (!sb) return;
    try {
      await rpcOrThrow(sb, 'madrasa_rel_resolve_daily_schedule_proposal', {
        p_teacher_pin: _teacherPin,
        p_student_id: sid,
        p_approve: !!approve,
        p_note: String(note || ''),
      });
      await pullRemoteSnapshot();
    } catch (e) { console.warn('resolveDailyScheduleProposalRemote:', e); throw e; }
  }

  w.RemoteSync = {
    isRemote, usesSecureKv, getClient,
    mem,
    bootstrap, bootstrapLegacy, bootstrapTeacherIdle, bootstrapStudentIdle,
    unlockTeacherWithPin, unlockStudentWithWaqfPin,
    refreshStudentLockHints,
    schedule, flushKey, flushAllFromMem,
    sendMessageRemote,
    markDocReviewedRemote, markMessagesReadRemote, clearStudentDataRemote, deleteStudentRemote, deleteQuizRemote, deleteTaskRemote, deleteMessageRemote, updateMessageTextRemote, deleteOwnMessageRemote, getBroadcastReadCounts,
    upsertCompletionRemote, deleteCompletionRemote,
    fetchGroupsRemote, upsertGroupRemote, deleteGroupRemote,
    fetchDiaryRemote, upsertDiaryRemote, deleteDiaryRemote,
    upsertTeacherNoteRemote, deleteTeacherNoteRemote,
    updateConfigRemote, upsertAcademicHistoryRemote, deleteAcademicHistoryRemote,
    upsertGoalRemote, deleteGoalRemote, saveDocumentRemote, deleteDocumentRemote,
    upsertStudentNoteRemote, deleteStudentNoteRemote,
    upsertNoteCategoryRemote, deleteNoteCategoryRemote,
    submitQuizRemote, updateQuizScoreRemote, updateTaskStatusRemote, completeOnetimeTaskRemote,
    saveTaskRemote, saveQuizRemote, saveStudentRemote, updateStudentPinRemote,
    submitDailyScheduleProposalRemote, setDailyScheduleTeacherRemote, resolveDailyScheduleProposalRemote,
    uploadFile, getSignedUrlForPath, consumeUploadResult,
    BUCKET, startRealtimeSync, pullRemoteSnapshot,
  };
})(typeof window !== 'undefined' ? window : globalThis);
