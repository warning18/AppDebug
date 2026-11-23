'use strict';
// Parses Firebase Analytics debug lines from logcat (tags FA / FA-SVC).
const PARAM_SPLIT = /, (?=[A-Za-z_]\w*(?:\(\w+\))?=)/;

function parseBundle(text) {
  const m = text.match(/Bundle\[\{([\s\S]*)\}\]/);
  const params = {};
  if (!m || !m[1].trim()) return params;
  for (const part of m[1].split(PARAM_SPLIT)) {
    const i = part.indexOf('=');
    if (i < 0) continue;
    const key = part.slice(0, i).replace(/\(\w+\)$/, '');
    params[key] = part.slice(i + 1);
  }
  return params;
}

function stripShort(name) { return name.replace(/\(\w+\)$/, '').trim(); }

// Returns {time, name, params, kind} or null.
function parseLine(line) {
  const t = line.match(/^(\d\d-\d\d \d\d:\d\d:\d\d\.\d+)/);
  const time = t ? t[1] : '';
  let m = line.match(/Logging event(?: \(FE\))?: (?:origin=\w+,)?(?:name=)?([^,\s]+?(?:\(\w+\))?)(?:,\s*(?:params=)?)(Bundle\[.*)$/);
  if (m) return { time, kind: 'event', name: stripShort(m[1]), params: parseBundle(m[2]) };
  m = line.match(/Setting user property(?: \(FE\))?: ([^,]+), (.*)$/);
  if (m) return { time, kind: 'user_property', name: stripShort(m[1]), params: { value: m[2].trim() } };
  return null;
}

module.exports = { parseLine, parseBundle };

// ---- FA-SVC batch parser (multi-line "event { name: ... param { ... } }" dumps) ----
const SVC_LINES = [
  /^\d\d-\d\d\s+(\d\d:\d\d:\d\d\.\d+)\s+[A-Z]\/FA-SVC\s*\(\s*\d+\):\s*(.*)$/,   // -v time
  /^\d\d-\d\d\s+(\d\d:\d\d:\d\d\.\d+)\s+\d+\s+\d+\s+[A-Z]\s+FA-SVC\s*:\s*(.*)$/, // -v threadtime
];
const unq = (s) => s.trim().replace(/^"(.*)"$/, '$1');

// feed(line) returns [{type:'event',event}|{type:'batch-end'}]
function createBatchParser() {
  let inEvent = false, inParam = false, name = '', time = '', params = {}, raw = [], pName = '', pVal = '';
  return {
    feed(line) {
      let m = null;
      for (const re of SVC_LINES) { m = line.match(re); if (m) break; }
      if (!m) return [];
      const t = m[1], msg = m[2].trim();
      if (msg === 'event {') { inEvent = true; inParam = false; name = ''; time = t; params = {}; raw = ['event {']; return []; }
      if (inEvent) {
        raw.push(msg);
        if (msg === 'param {') { inParam = true; pName = ''; pVal = ''; }
        else if (inParam) {
          let x;
          if ((x = msg.match(/^name:\s*(.+)$/))) pName = unq(x[1]);
          else if ((x = msg.match(/^(?:string|int|double|float)_value:\s*(.+)$/))) pVal = unq(x[1]);
          else if (msg === '}') { if (pName) params[pName] = pVal; inParam = false; }
        } else if ((m = msg.match(/^name:\s*(.+)$/))) name = unq(m[1]);
        else if (msg === '}') {
          inEvent = false;
          return [{ type: 'event', event: { time, kind: 'event', name, params, full: raw.join(' ') } }];
        }
        return [];
      }
      if (/End-of-batch/.test(msg)) return [{ type: 'batch-end', time: t }];
      return [];
    },
  };
}
module.exports.createBatchParser = createBatchParser;
