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
const audioModuleAddress = new URL("./generated/SidayWebAudio.wasm", import.meta.url);
const pageModuleAddress = new URL("./generated/SidayWeb.wasm", import.meta.url);

/// The Swift side's callbacks: accepts, added, loaded, progress, ended, held.
let listeners;
/// The tunes, in the order the Swift side has them: { name, file }.
const tunes = [];
let context;
/// A promise of the audio worklet's node, once the first tune has been asked for.
let node;
/// Counts requests to play. Answers to any but the latest are dropped.
let serial = 0;
let television = 0;
let songLengths;

/// The audio graph, made when the first tune is played: a browser will not start one before the
/// listener has done something on the page.
function audio() {
  node ??= (async () => {
    // SidayKit renders at 48 kHz; the browser converts if the hardware runs at another rate.
    context = new AudioContext({ sampleRate: 48000, latencyHint: "playback" });
    const [module] = await Promise.all([
      fetch(audioModuleAddress).then((response) => response.arrayBuffer()),
      context.audioWorklet.addModule(workletAddress),
    ]);
    const made = new AudioWorkletNode(context, "siday", {
      numberOfInputs: 0,
      outputChannelCount: [2],
      processorOptions: { module },
    });
    made.port.onmessage = (event) => heard(event.data);
    made.connect(context.destination);
    made.port.postMessage({ type: "television", set: television });
    if (songLengths) made.port.postMessage({ type: "songlengths", bytes: songLengths });
    return made;
  })();
  return node;
}

function heard(message) {
  if (message.serial !== serial) return;
  switch (message.type) {
    case "loaded":
      listeners?.loaded(message.plays, message.text, message.songs, message.song, message.length);
      break;
    case "progress":
      listeners?.progress(message.position, message.level);
      break;
    case "ended":
      listeners?.ended();
      break;
  }
}

async function play(index, subsong) {
  const request = ++serial;
  const tune = tunes[index];
  try {
    const [bytes, made] = await Promise.all([tune.file.arrayBuffer(), audio()]);
    if (request !== serial) return;
    const name = new TextEncoder().encode(tune.name).buffer;
    made.port.postMessage({ type: "load", serial: request, name, bytes, subsong }, [name, bytes]);
    // A browser keeps the sound back until the listener has pressed something on the page. If it is
    // still holding a moment from now, the page shows the tune as paused, and pressing play starts it.
    void context.resume();
    setTimeout(() => {
      if (request === serial && context.state !== "running") listeners?.held();
    }, 300);
  } catch (error) {
    if (request === serial) listeners?.loaded(false, error instanceof Error ? error.message : "the file could not be read", 0, 0, 0);
  }
}

async function add(chosen) {
  // HVSC's song-length database is taken for what it is and not for a tune.
  const database = chosen.find((item) => item.name.split("/").pop().toLowerCase() === "songlengths.md5");
  if (database) {
    songLengths = await database.file.arrayBuffer();
    if (node) (await node).port.postMessage({ type: "songlengths", bytes: songLengths });
  }
  const accepted = chosen
    .filter((item) => listeners?.accepts(item.name))
    .sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" }));
  if (accepted.length === 0) return;
  tunes.push(...accepted);
  listeners?.added(accepted.map((item) => item.name).join("\n"));
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
    const typing = target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement;
    if (typing || event.metaKey || event.ctrlKey || event.altKey || (event.key === " " && target instanceof HTMLButtonElement)) {
      event.stopPropagation();
    } else if (event.key === " " || event.key.startsWith("Arrow")) {
      event.preventDefault();
    }
  },
  true,
);

// What the Swift side calls.
Object.assign(globalThis, {
  sidayListen(accepts, added, loaded, progress, ended, held) {
    listeners = { accepts, added, loaded, progress, ended, held };
  },
  sidayChoose(folder) {
    (folder ? choosers.folder : choosers.files).click();
  },
  sidayPlay(index, subsong) {
    void play(index, subsong);
  },
  sidayPause(paused) {
    void (paused ? context?.suspend() : context?.resume());
  },
  sidayTelevision(set) {
    television = set;
    void node?.then((made) => made.port.postMessage({ type: "television", set }));
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
