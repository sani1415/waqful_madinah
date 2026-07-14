/* Waqful Madinah — remote-sync-write.js: relational write operations */
(function (w) {
  // Called by remote-sync.js after it sets up _RSCtx (context object)
  function init(ctx) {
    // ctx: { getPin, getStudentPin, getStudentWaqf, getStudentId, getRole, savedMsgIds }

    async function rpcOrThrow(sb, name, params) {
      const { data, error } = await sb.rpc(name, params);
      if (error) throw error;
      return data;
    }

    function stuToDB(s) {
      return { id: s.id, waqf_id: s.waqfId, name: s.name, cls: s.cls || '', roll: s.roll || '',
        pin: s.pin, color: s.color || '#128C7E', note: s.note || '',
        father_name: s.fatherName || '', father_occupation: s.fatherOccupation || '',
        contact: s.contact || '', district: s.district || '', upazila: s.upazila || '',
        blood_group: s.bloodGroup || '', enrollment_date: s.enrollmentDate || '',
        responsibility: s.responsibility || '' };
    }

    async function saveCore(sb, core) {
      if (!core) return;
      const isTeacher = ctx.getRole() === 'teacher';
      const tPin = ctx.getPin();
      if (isTeacher && tPin) {
        for (const s of (core.students || []))
          await rpcOrThrow(sb, 'madrasa_rel_upsert_student', { p_teacher_pin: tPin, p_student: stuToDB(s) });
        for (const t of (core.tasks || [])) {
          const p_task = { id: t.id, title: t.title, description: t.desc || '', type: t.type || 'onetime',
            deadline: t.deadline || '', created_at: t.created || '' };
          await rpcOrThrow(sb, 'madrasa_rel_upsert_task', { p_teacher_pin: tPin, p_task,
            p_assignee_ids: Object.keys(t.assignees || {}) });
          for (const [sid, status] of Object.entries(t.assignees || {})) {
            const cb = (t.completedBy || {})[sid] || {};
            await rpcOrThrow(sb, 'madrasa_rel_update_task_status', { p_pin: tPin, p_role: 'teacher',
              p_task_id: t.id, p_student_id: sid, p_status: status,
              p_completed_date: cb.date || null, p_completed_time: cb.time || null });
          }
        }
      }
      for (const [threadId, msgs] of Object.entries(core.chats || {})) {
        for (const msg of (msgs || [])) {
          if (ctx.savedMsgIds.has(msg.id)) continue;
          if (msg._skipRemote) { ctx.savedMsgIds.add(msg.id); continue; }
          const { id, role: r, type, text, read, time, ...extra } = msg;
          const p_message = { id, thread_id: threadId, role: r || (isTeacher ? 'out' : 'in'),
            type: type || 'text', text: text || '', extra, is_read: read || false, sent_at: null,
            ...(isTeacher ? {} : { thread_id_waqf: ctx.getStudentWaqf() }) };
          try {
            await rpcOrThrow(sb, 'madrasa_rel_insert_message', {
              p_pin: isTeacher ? tPin : ctx.getStudentPin(),
              p_role: isTeacher ? 'teacher' : 'student', p_message });
            ctx.savedMsgIds.add(id);
          } catch (e) { console.warn('msg insert:', id, e); }
        }
      }
    }

    async function saveGoals(sb, goals) {
      const sPin = ctx.getStudentPin(), sId = ctx.getStudentId();
      if (ctx.getRole() !== 'student' || !sPin || !sId) return;
      for (const g of ((goals || {})[sId] || [])) {
        const p_goal = { id: g.id, title: g.title, cat: g.cat || 'other', deadline: g.deadline || '',
          note: g.note || '', done: g.done || false, created_at: g.created || '' };
        await rpcOrThrow(sb, 'madrasa_rel_upsert_goal', { p_pin: sPin, p_student_id: sId, p_goal });
      }
    }

    async function saveExams(sb, exams) {
      const tPin = ctx.getPin();
      if (ctx.getRole() !== 'teacher' || !tPin) return;
      for (const q of (exams?.quizzes || [])) {
        const p_quiz = { id: q.id, title: q.title, subject: q.subject || '', description: q.desc || '',
          time_limit: q.timeLimit || 30, audio_limit_seconds: q.audioLimitSeconds || 120, pass_percent: q.passPercent || 60,
          deadline: q.deadline || '', created_at: q.created || '' };
        const p_questions = (q.questions || []).map(qq => ({ id: qq.id, type: qq.type, text: qq.text,
          options: qq.options || [], correct_answer: qq.correctAnswer, marks: qq.marks || 1,
          upload_instructions: qq.uploadInstructions || null }));
        await rpcOrThrow(sb, 'madrasa_rel_upsert_quiz', { p_teacher_pin: tPin, p_quiz,
          p_questions, p_assignee_ids: q.assigneeIds || [] });
      }
    }

    async function saveDocs(sb, docs) {
      const r = ctx.getRole() || 'teacher';
      const pin = r === 'teacher' ? ctx.getPin() : ctx.getStudentPin();
      if (!pin) return;
      for (const d of (docs || [])) {
        const p_doc = { id: d.id, student_id: d.studentId, student_name: d.studentName || '',
          file_name: d.fileName, file_type: d.fileType || '', file_size: d.fileSize || 0,
          category: d.category || 'general', note: d.note || '',
          storage_path: d.storage_path || null, file_url: d.fileUrl || null,
          is_read: d.read || false, uploaded_at: null,
          review_status: d.reviewStatus || (d.sentBy === 'student' ? 'pending' : 'done') };
        await rpcOrThrow(sb, 'madrasa_rel_insert_document', { p_pin: pin, p_role: r, p_doc });
      }
    }

    async function saveKVImpl(sb, key, value, usesSecure) {
      if (!usesSecure) {
        const { error } = await sb.from('waqf_app_kv').upsert(
          { key, value: value === undefined ? {} : value, updated_at: new Date().toISOString() },
          { onConflict: 'key' });
        if (error) throw error;
        return;
      }
      if (key === 'core') return saveCore(sb, value);
      if (key === 'goals') return saveGoals(sb, value);
      if (key === 'exams') return saveExams(sb, value);
      if (key === 'docs_meta') return saveDocs(sb, value);
      if (key === 'academic' || key === 'tnotes') return; // tnotes: written per-note via upsertTeacherNoteRemote
      if (key === 'teacher_pin') {
        const newPin = value?.pin ? String(value.pin) : String(value || '');
        const oldPin = ctx.getPin();
        if (newPin && oldPin) {
          await rpcOrThrow(sb, 'madrasa_rel_update_teacher_pin',
            { p_old_pin: oldPin, p_new_pin: newPin });
          ctx.setPin(newPin);
        }
      }
    }

    async function upsertCompletionRemote(sb, row, pin, roleStr) {
      if (!pin) return;
      await rpcOrThrow(sb, 'madrasa_rel_upsert_completion', {
        p_pin: pin, p_role: roleStr || 'teacher',
        p_id: row.id, p_task_id: row.task_id, p_student_id: row.student_id,
        p_date: row.date, p_status: row.status,
        p_completed_at: row.completed_at || null, p_note: row.note || '',
      });
    }

    async function deleteCompletionRemote(sb, tid, sid, date, pin, roleStr) {
      if (!pin) return;
      await rpcOrThrow(sb, 'madrasa_rel_delete_completion', {
        p_pin: pin, p_role: roleStr || 'teacher',
        p_task_id: tid, p_student_id: sid, p_date: date,
      });
    }

    return { saveCore, saveGoals, saveExams, saveDocs, saveKVImpl,
      upsertCompletionRemote, deleteCompletionRemote };
  }

  w._RSWrite = { init };
})(typeof window !== 'undefined' ? window : globalThis);
