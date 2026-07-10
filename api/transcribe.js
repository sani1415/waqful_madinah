/**
 * POST /api/transcribe
 * Body JSON: { audioBase64: string, mimeType?: string }
 * Model: gemini-3.1-flash-lite — key from GEMINI_API_KEY (never sent to browser).
 */
const fs = require('fs');
const path = require('path');

const MODEL = 'gemini-3.1-flash-lite';
const MAX_BYTES = 8 * 1024 * 1024;

/** Local preview: vercel dev sometimes misses .env.local until restart — load if needed. */
function ensureGeminiEnv() {
  if (process.env.GEMINI_API_KEY) return;
  try {
    const envPath = path.join(process.cwd(), '.env.local');
    if (!fs.existsSync(envPath)) return;
    for (const line of fs.readFileSync(envPath, 'utf8').split(/\r?\n/)) {
      const t = line.trim();
      if (!t || t.startsWith('#') || !t.includes('=')) continue;
      const i = t.indexOf('=');
      const key = t.slice(0, i).trim();
      let val = t.slice(i + 1).trim();
      if (
        (val.startsWith('"') && val.endsWith('"')) ||
        (val.startsWith("'") && val.endsWith("'"))
      ) {
        val = val.slice(1, -1);
      }
      if (process.env[key] === undefined) process.env[key] = val;
    }
  } catch (_) {}
}

function json(res, status, body) {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  res.end(JSON.stringify(body));
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > 12 * 1024 * 1024) {
        reject(new Error('payload_too_large'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function normalizeMime(mime) {
  const m = String(mime || 'audio/webm').trim().toLowerCase();
  if (m.startsWith('audio/webm')) return 'audio/webm';
  if (m.startsWith('audio/ogg')) return 'audio/ogg';
  if (m.startsWith('audio/mp4') || m === 'audio/m4a') return 'audio/mp4';
  if (m.startsWith('audio/mpeg') || m === 'audio/mp3') return 'audio/mpeg';
  if (m.startsWith('audio/wav') || m === 'audio/x-wav') return 'audio/wav';
  if (m.startsWith('audio/aac')) return 'audio/aac';
  return null;
}

function extractText(data) {
  const parts =
    data && data.candidates && data.candidates[0] && data.candidates[0].content
      ? data.candidates[0].content.parts
      : null;
  if (!Array.isArray(parts)) return '';
  return parts
    .map((p) => (typeof p.text === 'string' ? p.text : ''))
    .join('')
    .trim();
}

module.exports = async function handler(req, res) {
  if (req.method === 'OPTIONS') {
    res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
    return json(res, 204, {});
  }
  if (req.method !== 'POST') {
    return json(res, 405, { ok: false, error: 'শুধু POST অনুমোদিত।' });
  }

  ensureGeminiEnv();
  const apiKey = process.env.GEMINI_API_KEY || '';
  if (!apiKey) {
    return json(res, 500, { ok: false, error: 'GEMINI_API_KEY সেট করা নেই।' });
  }

  let body;
  try {
    body = typeof req.body === 'object' && req.body ? req.body : JSON.parse(await readBody(req));
  } catch (e) {
    if (e && e.message === 'payload_too_large') {
      return json(res, 413, { ok: false, error: 'অডিও খুব বড়।' });
    }
    return json(res, 400, { ok: false, error: 'অবৈধ JSON।' });
  }

  const b64 = typeof body.audioBase64 === 'string' ? body.audioBase64.replace(/\s/g, '') : '';
  if (!b64) return json(res, 400, { ok: false, error: 'অডিও পাওয়া যায়নি।' });

  let buf;
  try {
    buf = Buffer.from(b64, 'base64');
  } catch {
    return json(res, 400, { ok: false, error: 'অডিও ডিকোড হয়নি।' });
  }
  if (!buf.length) return json(res, 400, { ok: false, error: 'অডিও খালি।' });
  if (buf.length > MAX_BYTES) {
    return json(res, 413, { ok: false, error: 'অডিও খুব বড় (সর্বোচ্চ ~২ মিনিট)।' });
  }

  const mimeType = normalizeMime(body.mimeType);
  if (!mimeType) {
    return json(res, 400, { ok: false, error: 'অসমর্থিত অডিও ফরম্যাট।' });
  }

  const url =
    'https://generativelanguage.googleapis.com/v1beta/models/' +
    encodeURIComponent(MODEL) +
    ':generateContent?key=' +
    encodeURIComponent(apiKey);

  const prompt =
    'You are a strict speech-to-text engine for Bengali (bn), which may include Arabic phrases or Quranic words.\n' +
    'Rules:\n' +
    '1) Transcribe EXACTLY what was spoken — word-for-word. Do not paraphrase, summarize, correct grammar, or change wording.\n' +
    '2) Keep the speaker\'s vocabulary and phrasing unchanged; do not "improve" or rewrite.\n' +
    '3) Add proper punctuation where natural pauses and sentence ends occur: দাঁড়ি (।), প্রশ্নবোধক (?), বিস্ময়বোধক (!), কমা (,), কোলন (:), উদ্ধৃতি যেখানে প্রযোজ্য।\n' +
    '4) Use Bengali punctuation conventions for Bengali speech; keep Arabic phrases as spoken.\n' +
    '5) Preserve numbers, names, and Islamic terms as heard.\n' +
    '6) Output ONLY the transcript text — no title, no markdown, no quotes around the whole text, no commentary.\n' +
    '7) If there is no clear speech, output an empty string.';

  let geminiRes;
  try {
    geminiRes = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        contents: [
          {
            role: 'user',
            parts: [
              { text: prompt },
              { inline_data: { mime_type: mimeType, data: b64 } },
            ],
          },
        ],
        generationConfig: {
          temperature: 0.2,
          maxOutputTokens: 4096,
        },
      }),
    });
  } catch (e) {
    console.error('[transcribe] fetch failed', e);
    return json(res, 502, { ok: false, error: 'Gemini-এ সংযোগ হয়নি।' });
  }

  const data = await geminiRes.json().catch(() => ({}));
  if (!geminiRes.ok) {
    const msg = (data.error && data.error.message) || 'ট্রান্সক্রিপশন ব্যর্থ।';
    console.error('[transcribe] gemini error', geminiRes.status, msg);
    return json(res, 502, { ok: false, error: msg });
  }

  const text = extractText(data);
  if (!text) {
    return json(res, 200, {
      ok: true,
      text: '',
      warning: 'কোনো স্পষ্ট বক্তৃতা শনাক্ত হয়নি।',
    });
  }
  return json(res, 200, { ok: true, text: text, model: MODEL });
};
