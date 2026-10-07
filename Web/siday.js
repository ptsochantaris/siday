// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// The browser's side of the player: the files the listener has chosen, and the audio graph. The page
// itself is Swift (Sources/SidayWeb), which calls the functions this puts on the global object and is
// called back through the listeners it registers; Sources/SidayWeb/Browser.swift says what each does.
// At the foot of the file the Swift page is loaded and started.
//
// Plain JavaScript, served as it is: there is no build step for anything in this folder but the two
// WebAssembly modules in generated/ (see build.sh).

import { instantiate } from "./generated/instantiate.js";

const workletAddress = new URL("./worklet.js", import.meta.url);
const engineAddress = new URL("./engine.js", import.meta.url);
const audioModuleAddress = new URL("./generated/SidayWebAudio.wasm", import.meta.url);
const pageModuleAddress = new URL("./generated/SidayWeb.wasm", import.meta.url);

/// The Swift side's callbacks: accepts, added, loaded, progress, rendered, ended, held, pointed.
let listeners;
/// The tunes, in the order the Swift side has them: { name, file }.
const tunes = [];
let context;
/// A promise of the two halves of the sound, once the first tune has been asked for: the engine, a
/// worker that renders the tunes (engine.js), and the output, the audio thread that plays what the
/// engine sends it (worklet.js).
let sound;
/// Counts requests to play a tune. Answers to any but the latest are dropped.
let asked = 0;
/// Counts runs of sound: one starts with each tune, and with each move to another place in one. Word
/// of any but the latest is dropped, here and on the audio thread.
let serial = 0;
/// What tunes are heard through: an output style, by its place in SidayKit's list of them, and the
/// name of the one kept from the last visit.
let style = 0;
const rememberedStyle = kept("siday.output") ?? "";
let songLengths;
/// The player's own volume, 0 to 1, kept from one visit to the next, and the node that applies it.
let volume = remembered();
let loudness;
/// True while the player is paused. The audio hardware is let go a moment after.
let silenced = false;
let letGo;

/// The half of the audio graph that belongs to the audio hardware: an audio context, the output that
/// plays what the engine sends (worklet.js), and the player's own volume after it. The context is made
/// here and now, which matters: a browser lets sound start only from something the listener did, and
/// this is called while they are doing it. The rest follows when the output's code has loaded.
function open() {
  // SidayKit renders at 48 kHz; the browser converts if the hardware runs at another rate. The
  // browser is asked to keep plenty of sound in hand, which guards against breaks in it.
  const made = new AudioContext({ sampleRate: 48000, latencyHint: "playback" });
  opened++;
  const ready = made.audioWorklet.addModule(workletAddress).then(() => {
    const output = new AudioWorkletNode(made, "siday", { numberOfInputs: 0, outputChannelCount: [2] });
    output.port.onmessage = (event) => heard(event.data);
    // The volume comes after everything else: the spectrum analyser shows the tune, however quietly
    // it is being listened to.
    const level = made.createGain();
    level.gain.value = gain(volume);
    output.connect(level);
    level.connect(made.destination);
    return { output, level };
  });
  return { context: made, ready };
}

/// Joins the engine to an output. The engine sends its sound straight to it, on a line of their own
/// that the page is not part of. If the browser will not carry such a line into the audio thread (the
/// output says when it has it), the page passes the sound along instead.
async function join(engine, output) {
  const line = new MessageChannel();
  const connected = new Promise((resolve) => (direct = resolve));
  passBack = undefined;
  output.port.postMessage({ type: "engine", port: line.port1 }, [line.port1]);
  engine.postMessage({ type: "output", output: line.port2 }, [line.port2]);
  if (!(await Promise.race([connected.then(() => true), new Promise((resolve) => setTimeout(() => resolve(false), 500))]))) {
    const relay = new MessageChannel();
    relay.port1.onmessage = (event) => output.port.postMessage(event.data, [event.data.samples.buffer]);
    passBack = (message) => relay.port1.postMessage(message);
    engine.postMessage({ type: "output", output: relay.port2 }, [relay.port2]);
  }
}

/// The audio graph, made when the first tune is played: a browser will not start one before the
/// listener has done something on the page.
function audio() {
  sound ??= (async () => {
    const outlet = open();
    context = outlet.context;
    const [module, { output, level }] = await Promise.all([
      fetch(audioModuleAddress).then((response) => response.arrayBuffer()),
      outlet.ready,
    ]);
    loudness = level;
    const engine = new Worker(engineAddress);
    const ready = new Promise((resolve) => (engine.onmessage = resolve));
    engine.postMessage({ type: "start", module }, [module]);
    await ready;
    engine.onmessage = (event) => heard(event.data);
    await join(engine, output);
    engine.postMessage({ type: "style", style });
    if (songLengths) engine.postMessage({ type: "songlengths", bytes: songLengths });
    return { engine, output };
  })();
  return sound;
}

/// Replaces the hardware's half of the graph with a new one. The engine, and the song it has
/// rendered, stay as they are; with `resume`, the song is taken up where it had got to.
///
/// This is for when the sound is sent somewhere else, a pair of headphones put on or taken off. A
/// browser carries on with the audio context it has, but not always cleanly: the sound can come to
/// lag behind what the browser says of it, and the display with it. A context made afresh for where
/// the sound now goes has no such history, which is why loading the page again cures it; this does as
/// much without losing the place.
function renew(resume) {
  const before = sound, old = context;
  const outlet = open();
  context = outlet.context;
  void context.resume();
  settled = undefined;
  renewedAt = performance.now();
  // Nothing more is shown of what the old output was playing.
  serial++;
  const renewed = (sound = (async () => {
    const { engine } = await before;
    const { output, level } = await outlet.ready;
    loudness = level;
    await join(engine, output);
    void old.close();
    return { engine, output };
  })());
  if (!resume) return;
  void renewed.then(({ engine, output }) => {
    if (sound !== renewed) return;
    const run = ++serial;
    output.port.postMessage({ type: "seek", serial: run });
    if (silenced) output.port.postMessage({ type: "pause", paused: true });
    engine.postMessage({ type: "seek", serial: run, position: shownFor === asked ? shownPosition : 0 });
    // Made without the listener's doing anything, the new context may not be let start. Then the
    // page shows the tune as paused, and pressing play starts it.
    setTimeout(() => {
      if (sound === renewed && !silenced && context.state !== "running") listeners?.held();
    }, 300);
  });
}

/// The sound is going somewhere else than it was, or seems to be.
let changing;
function moved() {
  clearTimeout(changing);
  changing = setTimeout(() => {
    if (!sound) return;
    if (silenced) {
      // Nothing is playing: a new start is made when something is.
      clearTimeout(letGo);
      released = true;
      void context.suspend();
    } else {
      renew(true);
    }
  }, 300);
}
navigator.mediaDevices?.addEventListener?.("devicechange", moved);

/// Called when the output says the engine's line has reached it.
let direct = () => {};
/// When the page is passing the sound along, how word of a played chunk gets back to the engine.
let passBack;
/// How many times the hardware's half of the graph has been made.
let opened = 0;
/// True when the audio hardware has been let go, after a pause: it is made afresh to play again.
let released = false;
/// Where the song had got to when the display last showed it, and which request to play that was.
let shownPosition = 0, shownFor = 0;

/// Seconds between a sound being made and its being heard, as far as the browser says. It says most
/// while the sound is running: a browser may report nothing for a context that is at rest.
function delay() {
  return (context?.baseLatency || 0) + (context?.outputLatency || 0);
}

/// The delay the browser has been reporting while this context plays, once it has held steady, and
/// how long a different one has been seen. A browser does not always say when the sound is sent
/// somewhere else, but the delay it reports changes: headphones without wires are a sixth of a second
/// or so behind a loudspeaker.
let settled, steady = 0, strayed = 0;
/// When the hardware's half of the graph was last made anew. A delay that will not settle is not
/// answered with one new start after another.
let renewedAt = -Infinity;
function watch(seconds) {
  if (settled === undefined || Math.abs(seconds - settled) <= 0.05) {
    strayed = 0;
    // A second of agreement settles it.
    if (settled === undefined && ++steady >= 47) settled = seconds;
    else if (settled !== undefined) steady = 0;
    return;
  }
  // Half a second of something else, and the sound has moved.
  if (++strayed >= 24) {
    strayed = 0;
    steady = 0;
    settled = undefined;
    if (performance.now() - renewedAt > 10000) moved();
  }
}

// Adding ?timing to the page's address shows, at its foot, what the browser says of the sound's
// journey while a tune plays: for finding out what it knows about a pair of wireless headphones.
let timing;
if (new URLSearchParams(location.search).has("timing")) {
  const ms = (seconds) => `${Math.round((seconds || 0) * 1000)} ms`;
  setInterval(() => {
    if (!context || !timing) return;
    document.body.dataset.timing = `Timing: while playing, the browser reported ${ms(timing.base)} of its own and ` +
      `${ms(timing.output)} for the output, and the display waited ${ms(timing.base + timing.output)}. ` +
      `The sound is ${context.state}; its output has been set up ${opened === 1 ? "once" : `${opened} times`}.`;
  }, 500);
}

/// Something kept from the last visit, and keeping it. A browser may refuse to keep such things:
/// then there is nothing.
function kept(name) {
  try {
    return localStorage.getItem(name);
  } catch {
    return null;
  }
}
function keep(name, value) {
  try {
    localStorage.setItem(name, value);
  } catch {}
}

/// The volume from the last visit, or full.
function remembered() {
  const level = Number.parseFloat(kept("siday.volume"));
  return level >= 0 && level <= 1 ? level : 1;
}

/// How much of the sound to let through for a volume: the ear hears it rise evenly when the sound
/// itself rises as the square.
function gain(level) {
  return level * level;
}

function setVolume(level) {
  volume = Math.max(0, Math.min(1, level));
  // Eased over a few hundredths of a second, so that moving the slider makes no zipper of a noise.
  if (loudness) loudness.gain.setTargetAtTime(gain(volume), context.currentTime, 0.015);
  keep("siday.volume", String(volume));
}

function heard(message) {
  if (message.type === "connected") return direct();
  // What the engine has to say of a tune is marked with the tune, and the rest with the run of sound.
  if ("tune" in message ? message.tune !== asked : message.serial !== serial) return;
  switch (message.type) {
    case "loaded":
      listeners?.loaded(message.plays, message.text, message.songs, message.song, message.length);
      break;
    case "rendered":
      listeners?.rendered(message.seconds, message.length);
      break;
    case "again":
      void again(message.tune);
      break;
    case "progress": {
      // This is news of sound that has been made but not yet heard: it is shown when its sound
      // comes out of the speakers, as near as the browser can say when that is.
      const seconds = delay();
      watch(seconds);
      timing = { base: context.baseLatency || 0, output: context.outputLatency || 0 };
      setTimeout(() => {
        if (message.serial !== serial || silenced) return;
        shownPosition = message.position;
        shownFor = asked;
        listeners?.progress(message.position, Array.from(message.bars, (bar) => bar / 255));
      }, seconds * 1000);
      break;
    }
    case "ended":
      listeners?.ended();
      break;
    case "played":
      passBack?.(message);
      break;
  }
}

/// The last request to play, until it has been passed to the engine.
let starting = Promise.resolve();

async function play(index, subsong) {
  const request = ++asked;
  const tune = tunes[index];
  // The audio hardware was let go while the player was paused: it is taken up again now, while the
  // listener is pressing something.
  if (released) {
    released = false;
    renew(false);
  }
  try {
    const [bytes, { engine, output }] = await Promise.all([tune.file.arrayBuffer(), audio()]);
    if (request !== asked) return;
    // The output drops what it was playing at once; the engine starts on the new tune.
    const run = ++serial;
    output.port.postMessage({ type: "tune", serial: run });
    const name = new TextEncoder().encode(tune.name).buffer;
    engine.postMessage({ type: "load", tune: request, serial: run, name, bytes, subsong }, [name, bytes]);
    // A browser keeps the sound back until the listener has pressed something on the page. If it is
    // still holding a moment from now, the page shows the tune as paused, and pressing play starts it.
    pause(false);
    setTimeout(() => {
      if (request === asked && context.state !== "running") listeners?.held();
    }, 300);
  } catch (error) {
    if (request === asked) listeners?.loaded(false, error instanceof Error ? error.message : "the file could not be read", 0, 0, 0);
  }
}

/// Moves to another place in the song that is playing. The engine has the song, or will have: the
/// output drops what it was about to play, and the engine sends from the new place. A paused player
/// stays paused, and starts from there.
async function seek(seconds) {
  if (!sound) return;
  // A tune that has been asked for and is still being read is the one meant.
  await starting;
  const { engine, output } = await sound;
  const run = ++serial;
  shownPosition = seconds;
  shownFor = asked;
  output.port.postMessage({ type: "seek", serial: run });
  engine.postMessage({ type: "seek", serial: run, position: seconds });
}

/// The engine is to render the playing song again, because what it is heard through has changed in a
/// way that changes what the chip makes. Like a move within the song, to the place it had got to: the
/// output drops what it was about to play, and the engine sends from there once it has rendered that far.
async function again(tune) {
  const { engine, output } = await sound;
  if (tune !== asked) return;
  const run = ++serial;
  output.port.postMessage({ type: "seek", serial: run });
  engine.postMessage({ type: "again", serial: run, position: shownFor === asked ? shownPosition : 0 });
}

async function add(chosen) {
  // HVSC's song-length database is taken for what it is and not for a tune.
  const database = chosen.find((item) => item.name.split("/").pop().toLowerCase() === "songlengths.md5");
  if (database) {
    songLengths = await database.file.arrayBuffer();
    if (sound) (await sound).engine.postMessage({ type: "songlengths", bytes: songLengths });
  }
  const accepted = chosen
    .filter((item) => listeners?.accepts(item.name))
    .sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" }));
  if (accepted.length === 0) return;
  tunes.push(...accepted);
  listeners?.added(accepted.map((item) => item.name).join("\n"));
}

/// Pausing fades the sound out in the audio thread and only then lets the audio hardware go. Stopped
/// dead, the browser would keep the sound it had in hand and play it when started again: a moment of
/// the old tune at the head of the next one.
///
/// Once the hardware has been let go, playing again starts with a new audio context, not the old one
/// woken up: the listener may have put headphones on in the meantime (see `renew`).
function pause(paused) {
  silenced = paused;
  clearTimeout(letGo);
  if (!paused && released) {
    released = false;
    renew(true);
    return;
  }
  void sound?.then(({ output }) => output.port.postMessage({ type: "pause", paused }));
  if (paused) {
    // Long enough for the silence to have pushed out everything that was waiting.
    letGo = setTimeout(() => {
      released = true;
      void context?.suspend();
    }, 1200 + delay() * 2000);
  } else {
    void context?.resume();
  }
}

// A file chooser of each kind, kept out of sight and clicked on the listener's behalf.
function chooser(folder) {
  const input = document.createElement("input");
  input.type = "file";
  input.multiple = true;
  if (folder) input.webkitdirectory = true;
  input.hidden = true;
  input.addEventListener("change", () => {
    void add(Array.from(input.files ?? [], (file) => ({ name: file.webkitRelativePath || file.name, file })));
    input.value = "";
  });
  document.body.append(input);
  return input;
}
const choosers = { files: chooser(false), folder: chooser(true) };

/// Everything in what was dropped, folders included.
async function dropped(items) {
  const found = [];
  async function walk(entry) {
    if (entry.isFile) {
      const file = await new Promise((resolve, reject) => entry.file(resolve, reject));
      found.push({ name: entry.fullPath.replace(/^\//, ""), file });
    } else if (entry.isDirectory) {
      const reader = entry.createReader();
      // A folder is read in batches until a batch comes back empty.
      for (;;) {
        const batch = await new Promise((resolve, reject) => reader.readEntries(resolve, reject));
        if (batch.length === 0) break;
        for (const child of batch) await walk(child);
      }
    }
  }
  // Both have to be taken before the first await: the list is emptied when the event is over. A
  // file that comes with no entry (not every browser gives one) is taken as it is.
  const taken = Array.from(items)
    .filter((item) => item.kind === "file")
    .map((item) => ({ entry: item.webkitGetAsEntry?.() ?? null, file: item.getAsFile() }));
  for (const { entry, file } of taken) {
    if (entry) await walk(entry);
    else if (file) found.push({ name: file.name, file });
  }
  return found;
}

document.addEventListener("dragover", (event) => event.preventDefault());
document.addEventListener("drop", (event) => {
  event.preventDefault();
  if (event.dataTransfer) void dropped(event.dataTransfer.items).then(add);
});

// The player's keys belong to the page, but not while the listener is typing in a field, and a space
// on a button is that button's.
document.addEventListener(
  "keydown",
  (event) => {
    const target = event.target;
    const typing = target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement || target instanceof HTMLSelectElement;
    if (typing || event.metaKey || event.ctrlKey || event.altKey || (event.key === " " && target instanceof HTMLButtonElement)) {
      event.stopPropagation();
    } else if (event.key === " " || event.key.startsWith("Arrow")) {
      event.preventDefault();
    }
  },
  true,
);

// A choice made from a list with the pointer leaves the list holding the keyboard, and the next press
// of space would open it again instead of pausing the tune. So it gives the keyboard up, unless it
// was the keyboard that made the choice.
let pressed = false;
document.addEventListener("pointerdown", (event) => (pressed = event.target instanceof HTMLSelectElement), true);
document.addEventListener("keydown", () => (pressed = false), true);
document.addEventListener("change", (event) => {
  if (pressed && event.target instanceof HTMLSelectElement) event.target.blur();
  pressed = false;
});

// The time bar. The page draws it and decides what pointing at it and pressing it mean; what it
// cannot know is where on the bar the pointer is, since only the browser knows how wide the bar has
// come out. So that much is worked out here: anything marked "seek" is a bar, and the Swift side is
// told how far along it the pointer is, from 0 to 1.
let pointing = false;
function along(event) {
  const bar = event.target instanceof Element ? event.target.closest(".seek") : null;
  if (!bar) return null;
  const box = bar.getBoundingClientRect();
  return box.width > 0 ? Math.max(0, Math.min(1, (event.clientX - box.left) / box.width)) : null;
}
function point(event) {
  // A finger has no place it points at between presses.
  const place = event.pointerType === "touch" ? null : along(event);
  if (place === null && !pointing) return;
  pointing = place !== null;
  listeners?.pointed(place ?? -1, false);
}
document.addEventListener("pointermove", point);
document.addEventListener("pointerover", point);
document.documentElement.addEventListener("pointerleave", () => {
  if (pointing) listeners?.pointed(-1, false);
  pointing = false;
});
document.addEventListener("click", (event) => {
  const place = along(event);
  if (place !== null) listeners?.pointed(place, true);
});

// The list of tunes. The page draws only the rows that can be seen, so it has to know where the list
// has been scrolled to and how much of it shows, which again only the browser knows. Scrolling is
// reported once a frame at most; a page that is not in front is given few frames or none, so a
// moment's wait serves as well. (The event does not rise through the page, so it is caught on its
// way down.)
let listWaiting = false;
function listMoved(list) {
  if (listWaiting) return;
  listWaiting = true;
  const report = () => {
    if (!listWaiting) return;
    listWaiting = false;
    listeners?.scrolled(list.scrollTop, list.clientHeight);
  };
  requestAnimationFrame(report);
  setTimeout(report, 120);
}
document.addEventListener("scroll", (event) => {
  if (event.target instanceof Element && event.target.classList.contains("rows")) listMoved(event.target);
}, true);
window.addEventListener("resize", () => {
  const list = document.querySelector(".rows");
  if (list) listMoved(list);
});

// What the Swift side calls.
Object.assign(globalThis, {
  sidayListen(accepts, added, loaded, progress, rendered, ended, held, pointed, scrolled) {
    listeners = { accepts, added, loaded, progress, rendered, ended, held, pointed, scrolled };
  },
  sidayChoose(folder) {
    (folder ? choosers.folder : choosers.files).click();
  },
  sidayPlay(index, subsong) {
    starting = play(index, subsong);
  },
  sidayPause(paused) {
    pause(paused);
  },
  sidaySeek(seconds) {
    void seek(seconds);
  },
  sidayVolume(level) {
    setVolume(level);
  },
  sidayRememberedVolume() {
    return volume;
  },
  sidayListHeight() {
    return document.querySelector(".rows")?.clientHeight ?? 0;
  },
  sidayScrollList(top) {
    const list = document.querySelector(".rows");
    if (list) list.scrollTop = top;
  },
  sidayOutput(name, place) {
    style = place;
    keep("siday.output", name);
    void sound?.then(({ engine }) => engine.postMessage({ type: "style", style: place }));
  },
  sidayRememberedOutput() {
    return rememberedStyle;
  },
});

// MARK: Starting the page

// The Swift page is a WebAssembly module built for WASI, the system interface programs outside a
// browser use. It asks for a handful of its functions and has little use for any of them, so they are
// given here and no library is needed: somewhere for `print` to go, and random numbers for Swift's
// hash tables.
let pageMemory;
let line = "";
const system = {
  wasiImport: {
    fd_write(descriptor, vectors, count, written) {
      const view = new DataView(pageMemory.buffer);
      let total = 0;
      for (let index = 0; index < count; index++) {
        const pointer = view.getUint32(vectors + index * 8, true), length = view.getUint32(vectors + index * 8 + 4, true);
        line += new TextDecoder().decode(new Uint8Array(pageMemory.buffer, pointer, length));
        total += length;
      }
      const lines = line.split("\n");
      line = lines.pop();
      for (const text of lines) (descriptor === 2 ? console.error : console.log)(text);
      view.setUint32(written, total, true);
      return 0;
    },
    random_get(pointer, length) {
      crypto.getRandomValues(new Uint8Array(pageMemory.buffer, pointer, length));
      return 0;
    },
    // The three standard streams are terminals (type 2, with no rights to seek), which makes the C
    // library pass each printed line on as it is finished. There are no other files: 8 is "bad file descriptor".
    fd_fdstat_get(descriptor, status) {
      if (descriptor > 2) return 8;
      new Uint8Array(pageMemory.buffer, status, 24).fill(0);
      new DataView(pageMemory.buffer).setUint8(status, 2);
      return 0;
    },
    fd_close: () => 8,
    // 70 is "cannot seek".
    fd_seek: () => 70,
  },
  initialize(instance) {
    pageMemory = instance.exports.memory;
    instance.exports._initialize?.();
  },
  setInstance(instance) {
    pageMemory = instance.exports.memory;
  },
};

const pageModule = await WebAssembly.compileStreaming(fetch(pageModuleAddress));
// Anything else the module asks of the system answers "not supported" (52).
for (const wanted of WebAssembly.Module.imports(pageModule)) {
  if (wanted.module === "wasi_snapshot_preview1" && wanted.kind === "function") system.wasiImport[wanted.name] ??= () => 52;
}
await instantiate({ module: pageModule, getImports: () => ({}), wasi: system });
