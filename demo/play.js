// Types demo/typescope.tape into the Ghostty window demo/record.sh opened, and
// captures that window with ffmpeg from the tape's Show to its end. Real
// keystrokes, unlike VHS's, so KeyCastr sees them and lands in the capture.
//
//   osascript -l JavaScript demo/play.js <tape> <capture.mkv> [--dry-run]
//
// --dry-run prints the parsed commands and the total scripted time instead.
//
// Plays a subset of VHS's tape language: Type[@speed], Sleep, Hide/Show, the
// named keys below (with @speed and a count), and Ctrl+<key>. Set, Output and
// comments are skipped; anything else stops the run before a key is sent.

ObjC.import("AppKit");
ObjC.import("Foundation");

const TITLE = "typescope-demo"; // record.sh's --title
const DEFAULT_SPEED = 0.07; // the tape's Set TypingSpeed
const KEYCODES = { Enter: 36, Escape: 53, Left: 123, Right: 124, Up: 126, Down: 125, Backspace: 51, Tab: 48, Space: 49 };
// capture settings: hardware encoding leaves the CPU to nvim and ollama
const FFMPEG = "/opt/homebrew/bin/ffmpeg";
const ENCODE = "-c:v h264_videotoolbox -b:v 50M";

const app = Application.currentApplication();
app.includeStandardAdditions = true;
const se = Application("System Events");

function duration(s) {
  const m = /^(\d+(?:\.\d+)?)(ms|s)?$/.exec(s);
  if (!m) throw new Error(`bad duration: ${s}`);
  return m[2] === "ms" ? Number(m[1]) / 1000 : Number(m[1]);
}

// "str", `str` or 'str': everything between the first quote and the last
function quoted(s) {
  const q = s[0];
  const end = s.lastIndexOf(q);
  if (!"\"`'".includes(q) || end <= 0) throw new Error(`bad string: ${s}`);
  return s.slice(1, end);
}

function parse(text) {
  const cmds = [];
  text.split("\n").forEach((raw, i) => {
    const line = raw.trim();
    if (!line || line.startsWith("#") || /^(Set|Output|Require)\b/.test(line)) return;
    const at = (spd) => (spd ? duration(spd) : DEFAULT_SPEED);
    let m;
    if ((m = /^Type(?:@(\S+))?\s+(.+)$/.exec(line))) {
      cmds.push({ op: "type", text: quoted(m[2]), speed: at(m[1]) });
    } else if ((m = /^Sleep\s+(\S+)$/.exec(line))) {
      cmds.push({ op: "sleep", secs: duration(m[1]) });
    } else if (line === "Hide" || line === "Show") {
      cmds.push({ op: line.toLowerCase() });
    } else if ((m = /^Ctrl\+(\S)$/.exec(line))) {
      cmds.push({ op: "ctrl", key: m[1].toLowerCase() });
    } else if ((m = /^(\w+)(?:@(\S+))?(?:\s+(\d+))?$/.exec(line)) && m[1] in KEYCODES) {
      cmds.push({ op: "key", code: KEYCODES[m[1]], name: m[1], speed: at(m[2]), count: Number(m[3] || 1) });
    } else {
      throw new Error(`tape line ${i + 1}: unsupported: ${line}`);
    }
  });
  return cmds;
}

function scripted(cmds) {
  return cmds.reduce((t, c) => {
    if (c.op === "type") return t + c.text.length * c.speed;
    if (c.op === "key") return t + c.count * c.speed;
    if (c.op === "sleep") return t + c.secs;
    return t;
  }, 0);
}

// the demo window, from any Ghostty process: `open -na` starts a new one
function demoWindow() {
  for (const p of se.processes.whose({ name: "ghostty" })()) {
    for (const w of p.windows()) {
      if (w.name() === TITLE) return { proc: p, win: w };
    }
  }
  return null;
}

function frontTitle() {
  const p = se.processes.whose({ frontmost: true })[0];
  try {
    return p.windows[0].name();
  } catch (e) {
    return "";
  }
}

// keys only ever go to the demo window: if anything else took focus, stop
function guard() {
  const t = frontTitle();
  if (t !== TITLE) throw new Error(`focus left the demo window (now on "${t}"); stopped`);
}

function sh(cmd) {
  return app.doShellScript(cmd);
}

function startCapture(win, out) {
  const [x, y] = win.position();
  const [w, h] = win.size();
  const scale = $.NSScreen.mainScreen.backingScaleFactor;
  // yuv420 needs even sizes
  const even = (n) => Math.floor((n * scale) / 2) * 2;
  const crop = `crop=${even(w)}:${even(h)}:${even(x)}:${even(y)}`;
  const log = out.replace(/\.\w+$/, ".log");
  const pid = sh(
    `${FFMPEG} -y -f avfoundation -capture_cursor 0 -framerate 30 -i 'Capture screen 0:none' ` +
      `-vf '${crop}' ${ENCODE} '${out}' </dev/null >'${log}' 2>&1 & echo $!`,
  );
  // capture starts a beat after launch; wait until frames are being written
  for (let i = 0; i < 50; i++) {
    delay(0.1);
    if (Number(sh(`stat -f %z '${out}' 2>/dev/null || echo 0`)) > 0) return pid;
  }
  sh(`kill -INT ${pid} 2>/dev/null || true`);
  throw new Error(`ffmpeg didn't start; see ${log}`);
}

function stopCapture(pid) {
  sh(`kill -INT ${pid} 2>/dev/null; while kill -0 ${pid} 2>/dev/null; do sleep 0.1; done`);
}

function play(cmds, out) {
  const found = demoWindow();
  if (!found) throw new Error(`no Ghostty window titled ${TITLE}; run demo/record.sh`);
  found.proc.frontmost = true;
  delay(0.5);
  let pid = null;
  try {
    for (const c of cmds) {
      if (c.op === "sleep") {
        delay(c.secs);
        continue;
      }
      if (c.op === "hide") continue;
      if (c.op === "show") {
        if (!pid) pid = startCapture(found.win, out);
        continue;
      }
      guard();
      if (c.op === "type") {
        for (const ch of c.text) {
          se.keystroke(ch);
          delay(c.speed);
        }
      } else if (c.op === "key") {
        for (let i = 0; i < c.count; i++) {
          se.keyCode(c.code);
          delay(c.speed);
        }
      } else if (c.op === "ctrl") {
        se.keystroke(c.key, { using: "control down" });
        delay(DEFAULT_SPEED);
      }
    }
  } finally {
    if (pid) stopCapture(pid);
  }
}

function run(argv) {
  const [tape, out, flag] = argv;
  if (!tape || !out) throw new Error("usage: play.js <tape> <capture.mkv> [--dry-run]");
  const text = $.NSString.stringWithContentsOfFileEncodingError(tape, $.NSUTF8StringEncoding, null).js;
  const cmds = parse(text);
  if (flag === "--dry-run") {
    const shown = cmds.slice(cmds.findIndex((c) => c.op === "show"));
    return cmds.map((c) => JSON.stringify(c)).join("\n") + `\n\nscripted time from Show: ${scripted(shown).toFixed(1)}s`;
  }
  play(cmds, out);
  return `captured ${out}`;
}
