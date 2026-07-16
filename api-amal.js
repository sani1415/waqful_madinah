/* Waqful Madinah — api-amal.js: আমল ট্র্যাকিং মডিউল (api.js-এর আগে load হয়) */
(function (w) {
  const COMP_KEY = 'madrasa_completions';

  function _isRemote() { return !!(w.RemoteSync && w.RemoteSync.isRemote()); }
  function _RS()       { return w.RemoteSync || null; }
  // বাংলাদেশ সময় (Asia/Dhaka, UTC+6, DST নেই) — ডিভাইসের টাইমজোন যাই থাকুক
  const BD_OFFSET_MS = 6 * 60 * 60 * 1000;
  function _bdNow()    { return new Date(Date.now() + BD_OFFSET_MS); }
  function _today()    { return _bdNow().toISOString().split('T')[0]; }
  function _uid(p)     { return (p||'tc')+Date.now()+Math.random().toString(36).slice(2,5); }
  function _pad(n)     { return String(n).padStart(2,'0'); }

  function _weekStart() {
    const d = _bdNow(), day = d.getUTCDay();
    d.setUTCDate(d.getUTCDate() - ((day+1)%7)); // back to last Saturday
    return d.toISOString().split('T')[0];
  }
  function _monthStart() {
    const d = _bdNow();
    return `${d.getUTCFullYear()}-${_pad(d.getUTCMonth()+1)}-01`;
  }
  function _dateAdd(date, delta) {
    const d = new Date((date || _today()) + 'T12:00:00Z');
    d.setUTCDate(d.getUTCDate() + delta);
    return d.toISOString().split('T')[0];
  }
  function getWeekStart(dateStr) {
    const d = new Date((dateStr || _today()) + 'T12:00:00Z');
    const day = d.getUTCDay();
    d.setUTCDate(d.getUTCDate() - ((day + 1) % 7)); // Saturday
    return d.toISOString().split('T')[0];
  }
  function getWeekDates(dateStr) {
    const start = getWeekStart(dateStr || _today());
    return Array.from({ length: 7 }, (_, i) => _dateAdd(start, i));
  }
  function _daysBetween(from, to) {
    return Math.round((new Date(to) - new Date(from)) / 86400000);
  }

  // ── Completions submodule ─────────────────────────────────────
  const Completions = {
    _all() {
      if (_isRemote()) { const RS=_RS(); return RS.mem.completions||(RS.mem.completions=[]); }
      try { return JSON.parse(localStorage.getItem(COMP_KEY)||'[]'); } catch { return []; }
    },
    _save(list) {
      if (_isRemote()) { _RS().mem.completions=list; return; }
      localStorage.setItem(COMP_KEY, JSON.stringify(list));
    },
    find(tid, sid, date) {
      return this._all().find(c=>c.task_id===tid&&c.student_id===sid&&c.date===date)||null;
    },
    prepare({ task_id, student_id, date, status, note='' }) {
      const list=this._all();
      const idx=list.findIndex(c=>c.task_id===task_id&&c.student_id===student_id&&c.date===date);
      const now=new Date().toISOString();
      return { id:idx>=0?list[idx].id:_uid('tc'),
        task_id, student_id, date, status, completed_at:now, note,
        created_at:idx>=0?list[idx].created_at:now };
    },
    commit(row) {
      const list=this._all();
      const idx=list.findIndex(c=>c.task_id===row.task_id&&c.student_id===row.student_id&&c.date===row.date);
      if (idx>=0) list[idx]=row; else list.push(row);
      this._save(list);
      return row;
    },
    async upsert({ task_id, student_id, date, status, note='' }) {
      const row=this.prepare({task_id,student_id,date,status,note});
      const RS=_RS();
      if (_isRemote()&&RS&&RS.upsertCompletionRemote) await RS.upsertCompletionRemote(row);
      return this.commit(row);
    },
    async delete(tid, sid, date) {
      const RS=_RS();
      if (_isRemote()&&RS&&RS.deleteCompletionRemote) await RS.deleteCompletionRemote(tid,sid,date);
      const list=this._all().filter(c=>!(c.task_id===tid&&c.student_id===sid&&c.date===date));
      this._save(list);
    },
    getForStudent(sid, from=null, to=null) {
      let list=this._all().filter(c=>c.student_id===sid);
      if (from) list=list.filter(c=>c.date>=from);
      if (to)   list=list.filter(c=>c.date<=to);
      return list;
    },
    getForDate(date) { return this._all().filter(c=>c.date===date); },
    clearStudent(sid) {
      const list=this._all().filter(c=>c.student_id!==sid);
      this._save(list);
    },
  };

  // ── Private accessors (lazy — called after api.js loads) ─────
  function _api() { return (typeof API !== 'undefined' ? API : null) || w.API || null; }
  function _allTasks() {
    const A = _api();
    if (A?.Tasks) return A.Tasks.getAll();
    try { return JSON.parse(localStorage.getItem('madrasa_db')||'{}').tasks||[]; } catch { return []; }
  }
  function _tasksFor(sid)      { return _allTasks().filter(t=>t.assignees&&t.assignees[sid]); }
  function _dailyTasksFor(sid) { return _tasksFor(sid).filter(t=>t.type==='daily'); }
  function _allStudents() {
    const A = _api();
    if (A?.Students) return A.Students.getAll();
    try { return JSON.parse(localStorage.getItem('madrasa_db')||'{}').students||[]; } catch { return []; }
  }

  // ── Public helpers ────────────────────────────────────────────

  async function markCompleted(tid, sid, { date, status='done', note='' }={}) {
    return Completions.upsert({ task_id:tid, student_id:sid, date:date||_today(), status, note });
  }
  async function unmarkCompleted(tid, sid, date) { return Completions.delete(tid, sid, date||_today()); }
  function isCompleted(tid, sid, date)     { return Completions.find(tid, sid, date||_today())?.status==='done'; }

  function syncTodayFromCompletions(tasks) {
    const today=_today(), comps=Completions.getForDate(today);
    return (tasks||[]).map(t=>{
      if (t.type!=='daily') return t;
      const assignees={...t.assignees};
      Object.keys(assignees).forEach(sid=>{
        assignees[sid]=comps.find(c=>c.task_id===t.id&&c.student_id===sid&&c.status==='done')?'done':'pending';
      });
      return {...t, assignees};
    });
  }

  function getStreak(sid, tid=null) {
    const today=_today();
    const checkTasks=tid?_tasksFor(sid).filter(t=>t.id===tid):_dailyTasksFor(sid);
    if (!checkTasks.length) return { current:0, longest:0 };
    let streak=0, longest=0;
    for (let i=1; i<=365; i++) {
      const d=_bdNow(); d.setUTCDate(d.getUTCDate()-i);
      const dateStr=d.toISOString().split('T')[0];
      const dayComps=Completions.getForDate(dateStr).filter(c=>c.student_id===sid&&c.status==='done');
      if (checkTasks.some(t=>dayComps.find(c=>c.task_id===t.id))) {
        streak++; if (streak>longest) longest=streak;
      } else break;
    }
    const todayComps=Completions.getForDate(today).filter(c=>c.student_id===sid&&c.status==='done');
    const current=checkTasks.some(t=>todayComps.find(c=>c.task_id===t.id))?streak+1:streak;
    return { current, longest:Math.max(longest,current) };
  }

  function getProgressSummary(sid) {
    const today=_today(), wS=_weekStart(), mS=_monthStart();
    const tasks=_dailyTasksFor(sid), total=tasks.length;
    const empty={done:0,total:0,percent:0};
    const pct=(a,b)=>b>0?Math.round(a/b*100):0;
    if (!total) return { today:empty, week:empty, month:empty, all:empty };
    const isMine=c=>c.status==='done'&&tasks.find(t=>t.id===c.task_id);
    const todayDone=Completions.getForDate(today).filter(c=>c.student_id===sid&&isMine(c)).length;
    const wC=Completions.getForStudent(sid,wS,today).filter(isMine);
    const mC=Completions.getForStudent(sid,mS,today).filter(isMine);
    const wD=_daysBetween(wS,today)+1, mD=_daysBetween(mS,today)+1;
    // «শুরু থেকে» = ভর্তির তারিখ → আজ (enrollmentDate না থাকলে ০%)
    const student=_allStudents().find(s=>s.id===sid)||null;
    const en=student&&student.enrollmentDate;
    const enrollFrom=en&&/^\d{4}-\d{2}-\d{2}/.test(String(en))?String(en).slice(0,10):null;
    const all=enrollFrom?getRangeProgress(sid,enrollFrom,today):empty;
    return {
      today: { done:todayDone, total, percent:pct(todayDone,total) },
      week:  { done:wC.length, total:total*wD, percent:pct(wC.length,total*wD) },
      month: { done:mC.length, total:total*mD, percent:pct(mC.length,total*mD) },
      all:   { done:all.done, total:all.total, percent:all.percent },
    };
  }

  /** from–to (YYYY-MM-DD) পর্যন্ত দৈনিক আমলের সামগ্রিক % */
  function getRangeProgress(sid, from, to) {
    const today=_today();
    let start=from||today, end=to||today;
    if (start>today) start=today;
    if (end>today) end=today;
    const z={ done:0, total:0, percent:0, from:start, to:end };
    if (!start||start>end) return z;
    const tasks=_dailyTasksFor(sid), n=tasks.length;
    if (!n) return z;
    const days=_daysBetween(start,end)+1;
    if (days<1) return z;
    const done=Completions.getForStudent(sid,start,end)
      .filter(c=>c.status==='done'&&tasks.find(t=>t.id===c.task_id)).length;
    const total=n*days;
    return { done, total, percent:total>0?Math.round(done/total*100):0, from:start, to:end };
  }

  /** শিক্ষক তালিকা: সেটিংস অনুযায়ী শুরু → আজ */
  function getListProgress(sid) {
    const A=_api();
    const student=_allStudents().find(s=>s.id===sid)||null;
    const from=A?.ProgressSettings?.resolveFrom?.(student)||null;
    if (!from) return { done:0, total:0, percent:0, from:null, to:_today() };
    return getRangeProgress(sid, from, _today());
  }

  function getTodayOverview(dateStr) {
    const date=dateStr||_today(), comps=Completions.getForDate(date);
    return _allTasks().map(task=>{
      const asgn=Object.keys(task.assignees||{});
      const completed=asgn.filter(sid=>comps.find(c=>c.task_id===task.id&&c.student_id===sid&&c.status==='done'));
      const pending=asgn.filter(sid=>!comps.find(c=>c.task_id===task.id&&c.student_id===sid));
      return { task, completed, pending, percent:asgn.length>0?Math.round(completed.length/asgn.length*100):0 };
    });
  }

  function getLeaderboard(period='week') {
    const today=_today(), from=period==='week'?_weekStart():_monthStart();
    const allTasks=_allTasks().filter(t=>t.type==='daily');
    const days=_daysBetween(from,today)+1;
    return _allStudents().map(s=>{
      const myTasks=allTasks.filter(t=>t.assignees&&t.assignees[s.id]);
      const done=Completions.getForStudent(s.id,from,today).filter(c=>c.status==='done'&&myTasks.find(t=>t.id===c.task_id)).length;
      const total=myTasks.length*days;
      return { sid:s.id, name:s.name, waqfId:s.waqfId, color:s.color,
        responsibility:s.responsibility||'',
        done, total, percent:total>0?Math.round(done/total*100):0, streak:getStreak(s.id).current };
    }).sort((a,b)=>b.percent-a.percent||b.streak-a.streak);
  }

  function getCalendarData(sid, year, month) {
    const tasks=_dailyTasksFor(sid); if (!tasks.length) return {};
    const today=_today(), total=tasks.length;
    const from=`${year}-${_pad(month)}-01`;
    const dInM=new Date(year,month,0).getDate();
    const to=`${year}-${_pad(month)}-${_pad(dInM)}`;
    const comps=Completions.getForStudent(sid,from,to);
    const result={};
    for (let d=1; d<=dInM; d++) {
      const date=`${year}-${_pad(month)}-${_pad(d)}`;
      if (date>today) continue;
      const dayComps=comps.filter(c=>c.date===date);
      const doneN=dayComps.filter(c=>c.status==='done'&&tasks.find(t=>t.id===c.task_id)).length;
      const percent=total>0?Math.round(doneN/total*100):0;
      const status=doneN===0?'miss':doneN<total?'partial':'done';
      result[date]={ status, percent, done:doneN, total };
    }
    return result;
  }

  w.ApiAmal = { Completions, markCompleted, unmarkCompleted, isCompleted,
    syncTodayFromCompletions, getStreak, getProgressSummary, getRangeProgress,
    getListProgress, getTodayOverview, getLeaderboard, getCalendarData,
    getWeekStart, getWeekDates };

})(typeof window!=='undefined'?window:globalThis);
