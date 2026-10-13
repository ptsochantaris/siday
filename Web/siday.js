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

/// The Swift side's callbacks: kind, added, loaded, progress, rendered, ended, held, pointed.
let listeners;
/// And those that read playlists: sought, listed, missed.
let playlists;
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
/// The listener's settings: a number for each of SidayKit's, as the Swift side last gave them, and
/// what is waiting to pass a change of them on to the engine.
let settings;
let settling;
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
    if (settings) engine.postMessage({ type: "settings", values: settings });
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

/// What the page was last told of the playing song (see "progress" below), and which of its lights
/// the listener has muted, as the engine said the moment one was pressed. What comes with the
/// sound says that too, but a moment late: it is shown as its sound is heard.
let told;
let mutedNow;

/// Tells the page where the song has got to and what its voices are doing.
function tell() {
  if (!told) return;
  const voices = Array.from(told.voices);
  const lights = voices.length / 6;
  if (mutedNow && mutedNow.length === lights) voices.splice(lights * 5, lights, ...mutedNow);
  listeners?.progress(told.position, [...told.bars, ...voices], lights);
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
    case "muted":
      // A light has been pressed. It is shown at once, playing or not.
      mutedNow = message.marks;
      tell();
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
        // (One list and not two: handed two, the Swift side gets them the wrong way round.)
        told = { position: message.position, bars: message.bars, voices: message.voices ?? [] };
        tell();
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
    // (Another song: every voice of it is heard, whatever was muted in the last.)
    told = undefined;
    mutedNow = undefined;
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

/// Every tune the page has been given since it was opened, by its name: where a playlist's tunes are
/// looked for. A web page can only read the files it is given, so a playlist cannot be followed to
/// its tunes on the disk as it is by a program: they have to be here, handed over with it or before
/// it. (A tune taken out of the list is still here.)
const given = new Map();

/// The tunes that playlists name, found among some that are known: for each list its tunes in its
/// order, each with what the list says about it and whether it is a tune beside the list or below
/// it. With them, how many tunes the lists name in all and how many of those were not found. The
/// lists are read on the Swift side, which is told what there is to find among and then given each
/// list as text with a letter for each of its bytes.
async function listed(lists, known) {
  const texts = await Promise.all(
    lists.map(async (list) => {
      const bytes = new Uint8Array(await list.file.arrayBuffer());
      let text = "";
      for (let at = 0; at < bytes.length; at += 8192) text += String.fromCharCode.apply(null, bytes.subarray(at, at + 8192));
      return text;
    }),
  );
  const found = { lists: lists.map(() => []), named: lists.map(() => 0), missing: lists.map(() => 0) };
  if (!playlists) return found;
  playlists.sought(known.map((item) => item.name).join("\n"));
  texts.forEach((text, which) => {
    const [counts, ...lines] = playlists.listed(lists[which].name, text).split("\n");
    [found.named[which], found.missing[which]] = counts.split(" ").map(Number);
    for (const line of lines) {
      const [entry, place, below, note] = line.split("\t");
      if (note !== undefined) found.lists[which].push({ ...known[Number(place)], note, below: below === "1", entry: Number(entry) });
    }
  });
  playlists.sought("");
  return found;
}

/// The playlists last read that name tunes which were not found, each with the entries of it that
/// were: they are finished when the listener says where the rest are (see `finish`).
let unfinished = [];

/// Playlists have been read: those with tunes still to find are kept for later, and the Swift side
/// is told how it came out, and what the list is called if it is one list.
function reckon(lists, found, before = []) {
  unfinished = lists
    .map((list, which) => ({ list, had: new Set([...(before[which] ?? []), ...found.lists[which].map((item) => item.entry)]) }))
    .filter((_, which) => found.missing[which] > 0);
  const sum = (numbers) => numbers.reduce((total, number) => total + number, 0);
  playlists?.missed(sum(found.missing), sum(found.named), lists.length === 1 ? lists[0].name.split("/").pop() : "");
}

/// The listener has chosen the folder where the tunes of the unfinished playlists are. It is looked
/// in and not added to the list: what is added is the tunes of those playlists that had not been
/// found, in the order the lists have them. (The folder's tunes are known from now on, as any are
/// that the page has been given.)
async function finish(chosen) {
  const here = chosen.filter((item) => listeners?.kind(item.name) === 1);
  const lists = unfinished.map((item) => item.list);
  const before = unfinished.map((item) => item.had);
  if (lists.length === 0 || here.length === 0) return;
  const found = await listed(lists, [...here, ...Array.from(given, ([name, file]) => ({ name, file }))]);
  for (const item of here) given.set(item.name, item.file);
  const accepted = found.lists.flatMap((items, which) => items.filter((item) => !before[which].has(item.entry)));
  if (accepted.length > 0) {
    tunes.push(...accepted);
    listeners?.added(accepted.map((item) => `${item.name}\t${item.note ?? ""}`).join("\n"));
  }
  reckon(lists, found, before);
}

async function add(chosen) {
  // HVSC's song-length database is taken for what it is and not for a tune.
  const database = chosen.find((item) => item.name.split("/").pop().toLowerCase() === "songlengths.md5");
  if (database) {
    songLengths = await database.file.arrayBuffer();
    if (sound) (await sound).engine.postMessage({ type: "songlengths", bytes: songLengths });
  }
  // Tunes and playlists, in the order of their names.
  const sorted = chosen
    .map((item) => ({ ...item, kind: listeners?.kind(item.name) ?? 0 }))
    .filter((item) => item.kind > 0)
    .sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" }));
  const tunesHere = sorted.filter((item) => item.kind === 1);
  const lists = sorted.filter((item) => item.kind === 2);
  const own = lists.filter((item) => item.own);
  const known = () => [...tunesHere, ...Array.from(given, ([name, file]) => ({ name, file }))];
  let accepted = tunesHere;
  let found = null;
  if (own.length > 0) {
    // A playlist that was itself dropped is played as it is written: its tunes, in its order. A
    // folder dropped with it is where its tunes are looked for, and is not itself added to the list;
    // tunes dropped with it, each for itself, come after the list's, but for those it has named.
    found = await listed(own, known());
    const named = new Set(found.lists.flat().map((item) => item.file));
    accepted = [...found.lists.flat(), ...tunesHere.filter((item) => item.own && !named.has(item.file))];
  } else if (lists.length > 0) {
    // A folder is played in the order of its names, and a playlist in it is the order of the tunes
    // beside it and below it: those it names come where the list is, as it has them. The tunes a
    // list names from somewhere else are added only if the folder does not hold them, which here
    // can only be tunes the page was given before.
    found = await listed(lists, known());
    const below = new Map(lists.map((list, which) => [list, found.lists[which].filter((item) => item.below)]));
    const ordered = new Set(Array.from(below.values()).flat().map((item) => item.file));
    const held = new Set();
    accepted = [];
    const take = (item) => {
      if (held.has(item.file)) return;
      held.add(item.file);
      accepted.push(item);
    };
    for (const item of sorted) {
      if (item.kind === 2) below.get(item).forEach(take);
      else if (!ordered.has(item.file)) take(item);
    }
    found.lists.flat().filter((item) => !item.below).forEach(take);
  }
  for (const item of tunesHere) given.set(item.name, item.file);
  if (accepted.length > 0) {
    tunes.push(...accepted);
    listeners?.added(accepted.map((item) => `${item.name}\t${item.note ?? ""}`).join("\n"));
  }
  if (found) reckon(own.length > 0 ? own : lists, found);
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

/// A tune is taken out of the list. Those after it move up a place, here as on the Swift side.
function remove(index) {
  tunes.splice(index, 1);
}

/// Nothing is to be played: the tune that was playing has been taken out of the list, and there is
/// none after it. The sound stops as it does for a pause, and the engine lets the song go.
function stop() {
  asked++;
  pause(true);
  void sound?.then(({ engine }) => engine.postMessage({ type: "stop" }));
}

// A file chooser of each kind, kept out of sight and clicked on the listener's behalf.
function chooser(folder, then) {
  const input = document.createElement("input");
  input.type = "file";
  input.multiple = true;
  if (folder) input.webkitdirectory = true;
  input.hidden = true;
  input.addEventListener("change", () => {
    void then(Array.from(input.files ?? [], (file) => ({ name: file.webkitRelativePath || file.name, file, own: !folder })));
    input.value = "";
  });
  document.body.append(input);
  return input;
}
// (The third is for the folder that a playlist's tunes are in, which is looked in and not added.)
const choosers = { files: chooser(false, add), folder: chooser(true, add), tunes: chooser(true, finish) };

/// Everything in what was dropped, folders included. A file that was dropped itself, and did not
/// come in a folder, is marked as its own.
async function dropped(items) {
  const found = [];
  async function walk(entry, own) {
    if (entry.isFile) {
      const file = await new Promise((resolve, reject) => entry.file(resolve, reject));
      found.push({ name: entry.fullPath.replace(/^\//, ""), file, own });
    } else if (entry.isDirectory) {
      const reader = entry.createReader();
      // A folder is read in batches until a batch comes back empty.
      for (;;) {
        const batch = await new Promise((resolve, reject) => reader.readEntries(resolve, reject));
        if (batch.length === 0) break;
        for (const child of batch) await walk(child, false);
      }
    }
  }
  // Both have to be taken before the first await: the list is emptied when the event is over. A
  // file that comes with no entry (not every browser gives one) is taken as it is.
  const taken = Array.from(items)
    .filter((item) => item.kind === "file")
    .map((item) => ({ entry: item.webkitGetAsEntry?.() ?? null, file: item.getAsFile() }));
  for (const { entry, file } of taken) {
    if (entry) await walk(entry, true);
    else if (file) found.push({ name: file.name, file, own: true });
  }
  return found;
}

document.addEventListener("dragover", (event) => event.preventDefault());
document.addEventListener("drop", (event) => {
  event.preventDefault();
  if (event.dataTransfer) void dropped(event.dataTransfer.items).then(add);
});

// What the README says of a format, shown over the page when the format's name is pressed. The
// README is the one place it is written: the site carries a copy, fetched when first asked for, and
// the chapter wanted is found in it by its heading and set out as it would be on GitHub.
const source = "https://github.com/ptsochantaris/siday";
let readme;
let story;

/// A chapter of the README's "How it is built": the one whose heading begins with this word.
function chapter(text, word) {
  const lines = text.split("\n");
  const heading = new RegExp(`^### ${word.replace(/[^A-Za-z0-9]/g, "")}(?![A-Za-z0-9])`);
  const start = lines.findIndex((line) => heading.test(line));
  if (start < 0) return null;
  let end = lines.findIndex((line, place) => place > start && /^##+ /.test(line));
  if (end < 0) end = lines.length;
  return { title: lines[start].slice(4), lines: lines.slice(start + 1, end) };
}

/// A piece of the README's text as it is to be read: what is between backquotes as code, between
/// asterisks as stressed, and a link as a link.
function written(text, into) {
  let at = 0;
  for (const found of text.matchAll(/`([^`]+)`|\*\*([^*]+)\*\*|\*([^*\s][^*]*)\*|\[([^\]]+)\]\(((?:https?:|#)[^)\s]*)\)/g)) {
    into.append(text.slice(at, found.index));
    const [, code, strong, stressed, link, address] = found;
    const piece = document.createElement(code !== undefined ? "code" : strong !== undefined ? "strong" : stressed !== undefined ? "em" : "a");
    piece.textContent = code ?? strong ?? stressed ?? link;
    if (address !== undefined) {
      // A link to another part of the README goes to it where it is whole.
      piece.href = address.startsWith("#") ? source + address : address;
      piece.target = "_blank";
      piece.rel = "noopener";
    }
    into.append(piece);
    at = found.index + found[0].length;
  }
  into.append(text.slice(at));
}

/// A chapter's lines as paragraphs and lists. Lines with nothing between them are one paragraph.
function setOut(lines, into) {
  let block = [];
  const end = () => {
    if (block.length === 0) return;
    const item = /^(\d+\.|-)\s+/;
    if (item.test(block[0])) {
      const list = into.appendChild(document.createElement(block[0].startsWith("-") ? "ul" : "ol"));
      for (const line of block) {
        if (item.test(line)) written(line.replace(item, ""), list.appendChild(document.createElement("li")));
        else if (list.lastChild) written(" " + line.trim(), list.lastChild);
      }
    } else {
      written(block.join(" "), into.appendChild(document.createElement("p")));
    }
    block = [];
  };
  for (const line of lines) {
    if (line.trim() === "") end();
    else block.push(line);
  }
  end();
}

async function about(word) {
  readme ??= fetch(new URL("./generated/README.md", import.meta.url)).then((reply) => (reply.ok ? reply.text() : Promise.reject(new Error("no README"))));
  let found;
  try {
    found = chapter(await readme, word);
  } catch {
    // It can be asked for again.
    readme = undefined;
  }
  if (!found) return;
  if (!story) {
    story = document.body.appendChild(document.createElement("dialog"));
    story.className = "about";
    story.innerHTML = `<header><h2></h2><button title="Close (Esc)" aria-label="Close">×</button></header><div class="text" tabindex="0" autofocus></div><footer>From <a target="_blank" rel="noopener">siday's README</a>, which tells of every format.</footer>`;
    story.querySelector("a").href = `${source}#how-it-is-built`;
    story.querySelector("button").addEventListener("click", () => story.close());
    // A press outside it puts it away. (All of the dialog itself is covered by what is in it.)
    story.addEventListener("click", (event) => {
      if (event.target === story) story.close();
    });
  }
  story.querySelector("h2").textContent = found.title;
  const text = story.querySelector(".text");
  text.replaceChildren();
  setOut(found.lines, text);
  if (!story.open) story.showModal();
  text.scrollTop = 0;
}

// The player's keys belong to the page, but not while the listener is typing in a field, and a space
// on a button is that button's. While a format's story is up, the arrows are for reading it.
document.addEventListener(
  "keydown",
  (event) => {
    const target = event.target;
    const typing = target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement || target instanceof HTMLSelectElement;
    const reading = story?.open && (event.key.startsWith("Arrow") || event.key.startsWith("Page") || event.key === "Home" || event.key === "End");
    if (reading || typing || event.metaKey || event.ctrlKey || event.altKey || (event.key === " " && target instanceof HTMLButtonElement)) {
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

// The lights. Each is a button for its voice: a press mutes the voice or brings it back, and a right
// click (on a Mac, a click with Control held is one too) or a press held for half a second has it
// heard alone, or brings the others back if it already is. The engine is told which light, counted
// along the row, and works out the rest: it knows which voices are muted, and says so with the
// sound it sends, which is how the lights come to show it.
function lightAt(event) {
  const light = event.target instanceof Element ? event.target.closest(".light") : null;
  return light ? Array.prototype.indexOf.call(light.parentElement.children, light) : -1;
}
function mute(light, solo) {
  void sound?.then(({ engine }) => engine.postMessage({ type: "mute", light, solo }));
}
/// A press that is being held, and the light whose press was last held long enough to count, with
/// when: a held press ends in a click, and on some phones in a right click as well, neither of
/// which is to undo what it did.
let holding;
let held = { light: -1, at: 0 };
function wasHeld(light) {
  return held.light === light && performance.now() - held.at < 800;
}
function release() {
  clearTimeout(holding);
  holding = undefined;
}
document.addEventListener("pointerdown", (event) => {
  const light = lightAt(event);
  release();
  if (light < 0 || event.button !== 0 || event.ctrlKey) return;
  holding = setTimeout(() => {
    held = { light, at: performance.now() };
    mute(light, true);
  }, 500);
});
for (const over of ["pointerup", "pointercancel", "pointerleave", "scroll"]) document.addEventListener(over, release, true);
document.addEventListener("click", (event) => {
  const light = lightAt(event);
  // (A click with Control held is a right click on a Mac, and is seen to as one.)
  if (light >= 0 && !event.ctrlKey && !wasHeld(light)) mute(light, false);
});
document.addEventListener("contextmenu", (event) => {
  const light = lightAt(event);
  if (light < 0) return;
  event.preventDefault();
  if (!wasHeld(light)) mute(light, true);
});
document.addEventListener("keydown", (event) => {
  // From the keyboard: Return on a light mutes its voice, and with Shift has it heard alone.
  if (event.key !== "Enter" || !(event.target instanceof Element) || !event.target.classList.contains("light")) return;
  event.preventDefault();
  mute(lightAt(event), event.shiftKey);
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

// The picture to listen by. The Swift side paints it; it is asked to once for each frame the screen
// draws, while the picture is on the page and the page can be seen, and told how big a space the
// picture has, which only the browser knows.
function drawn(now) {
  requestAnimationFrame(drawn);
  const canvas = document.querySelector("canvas.picture");
  if (canvas && !document.hidden) listeners?.frame(now / 1000, canvas.clientWidth, canvas.clientHeight);
}
requestAnimationFrame(drawn);

/// Fills the screen with the picture and its few controls, or puts them back in the page.
function fillScreen() {
  const panel = document.querySelector(".visual");
  if (document.fullscreenElement ?? document.webkitFullscreenElement) {
    (document.exitFullscreen ?? document.webkitExitFullscreen)?.call(document);
  } else if (panel) {
    (panel.requestFullscreen ?? panel.webkitRequestFullscreen)?.call(panel);
  }
}

// While the picture fills the screen, its controls and the pointer go out of sight when the pointer
// has been still for a few seconds, and come back when it moves.
let stillness;
function stirred() {
  delete document.documentElement.dataset.still;
  clearTimeout(stillness);
  stillness = setTimeout(() => (document.documentElement.dataset.still = ""), 2500);
}
document.addEventListener("pointermove", stirred);
document.addEventListener("pointerdown", stirred);
document.addEventListener("fullscreenchange", stirred);

// What the Swift side calls.
Object.assign(globalThis, {
  sidayListen(kind, added, loaded, progress, rendered, ended, held, pointed, scrolled, frame) {
    listeners = { kind, added, loaded, progress, rendered, ended, held, pointed, scrolled, frame };
  },
  sidayAbout(word) {
    void about(word);
  },
  sidayPlaylists(sought, listed, missed) {
    playlists = { sought, listed, missed };
  },
  sidayPaint(address, width, height) {
    const canvas = document.querySelector("canvas.picture");
    if (!canvas || !pageMemory) return;
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width;
      canvas.height = height;
    }
    // The picture is shown from where the Swift side painted it, with no copy made on the way here.
    const dots = new Uint8ClampedArray(pageMemory.buffer, address, width * height * 4);
    canvas.getContext("2d").putImageData(new ImageData(dots, width, height), 0, 0);
  },
  sidayFillScreen() {
    fillScreen();
  },
  sidayPicture(name) {
    keep("siday.picture", name);
  },
  sidayRememberedPicture() {
    return kept("siday.picture") ?? "";
  },
  sidayChoose(folder) {
    (folder ? choosers.folder : choosers.files).click();
  },
  sidayChooseTunes() {
    choosers.tunes.click();
  },
  sidayPlay(index, subsong) {
    starting = play(index, subsong);
  },
  sidayPause(paused) {
    pause(paused);
  },
  sidayRemove(index) {
    remove(index);
  },
  sidayRemoveAll() {
    tunes.length = 0;
    unfinished = [];
  },
  sidayStop() {
    stop();
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
    // A list that has just been brought back is not on the page yet: it is looked for again for a moment.
    const scroll = (tries) => {
      const list = document.querySelector(".rows");
      if (list) list.scrollTop = top;
      else if (tries > 0) setTimeout(() => scroll(tries - 1), 30);
    };
    scroll(10);
  },
  sidayHidden(names) {
    keep("siday.away", names);
  },
  sidayRememberedHidden() {
    // The picture to listen by is away until it is asked for.
    return kept("siday.away") ?? "picture";
  },
  sidayOutput(name, place) {
    style = place;
    keep("siday.output", name);
    void sound?.then(({ engine }) => engine.postMessage({ type: "style", style: place }));
  },
  sidayRememberedOutput() {
    return rememberedStyle;
  },
  sidaySettings(values, remembered) {
    settings = values.split(",").map(Number);
    keep("siday.settings", remembered);
    // A setting that is being dragged along its scale changes many times a second, and each change
    // may mean rendering the song again: the engine is told when it has been left alone for a moment.
    clearTimeout(settling);
    settling = setTimeout(() => void sound?.then(({ engine }) => engine.postMessage({ type: "settings", values: settings })), 250);
  },
  sidayRememberedSettings() {
    return kept("siday.settings") ?? "";
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
