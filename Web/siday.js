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
/// And those that find files that come with others, the tunes of playlists and the companions of
/// tunes: given, listed, missed.
let finding;
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
/// What tunes are heard through: an output style, by its place in SidayPlayer's list of them, and the
/// name of the one kept from the last visit.
let style = 0;
const rememberedStyle = kept("siday.output") ?? "";
let songLengths;
/// The listener's settings: a number for each of SidayPlayer's, as the Swift side last gave them, and
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
    // A second engine, which plays the songs of tunes through to find how long they are, so that the
    // first need not hold up the sound for it (see engine.js); the two talk to each other.
    const measurer = new Worker(engineAddress);
    measurer.postMessage({ type: "start", module: module.slice(0) });
    const engine = new Worker(engineAddress);
    const ready = new Promise((resolve) => (engine.onmessage = resolve));
    engine.postMessage({ type: "start", module }, [module]);
    await ready;
    engine.onmessage = (event) => heard(event.data);
    const between = new MessageChannel();
    engine.postMessage({ type: "measurer", port: between.port1 }, [between.port1]);
    measurer.postMessage({ type: "measuring", port: between.port2 }, [between.port2]);
    await join(engine, output);
    // The files kept, which the engines are given first of all.
    measuring = measurer;
    for (const stored of await keptFiles()) {
      engine.postMessage({ type: "keep", bytes: stored.bytes, answer: true, token: stored.name });
      measurer.postMessage({ type: "keep", bytes: stored.bytes });
    }
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

/// The files the listener gave once that siday keeps (see `KeptFiles` in SidayPlayer): the ROMs of an
/// MT-32 of the LAPC-I's kind, those of an SC-55, and HVSC's Songlengths.md5. They are kept in the browser's IndexedDB, which
/// holds files of a megabyte as they are, from one visit to the next, under the names the engine gives
/// them; a file just given is kept under a name of its own until the engine has said what it is. What
/// the engine last said is kept too, as text, to be shown before it has started.
const keptSizes = [32768, 65536, 131072, 262144, 524288, 1048576];
let keptSummary = (kept("siday.kept") ?? "").split("\n").filter((line) => line);
let toldKept;
let keptGiven = 0;
/// The other worker, which plays songs through, and needs the ROMs too.
let measuring;
function keptStore(mode, use) {
  return new Promise((resolve) => {
    try {
      const opening = indexedDB.open("siday-kept", 1);
      opening.onupgradeneeded = () => opening.result.createObjectStore("files");
      opening.onerror = () => resolve(null);
      opening.onsuccess = () => {
        const store = opening.result.transaction("files", mode).objectStore("files");
        const asked = use(store);
        store.transaction.oncomplete = () => resolve(asked?.result ?? null);
        store.transaction.onerror = () => resolve(null);
      };
    } catch {
      resolve(null);
    }
  });
}
async function keptFiles() {
  const names = (await keptStore("readonly", (store) => store.getAllKeys())) ?? [];
  const files = (await keptStore("readonly", (store) => store.getAll())) ?? [];
  return names.map((name, which) => ({ name, bytes: files[which] }));
}
/// Hands a file to the engines, which say what it is: it is then kept under the engine's name for it,
/// or not at all. If no tune has been played yet, the engines are started for it, and are given every
/// file kept as they start, this one among them. (The sound itself starts only when a tune is played:
/// a browser lets it start only from something the listener did.)
function offerKept(stored) {
  if (!sound) return void audio();
  void sound.then(({ engine }) => {
    engine.postMessage({ type: "keep", bytes: stored.bytes, answer: true, token: stored.name });
    measuring?.postMessage({ type: "keep", bytes: stored.bytes });
  });
}
async function keptAnswer({ token, name, summary }) {
  if (name !== token) {
    const bytes = (await keptFiles()).find((stored) => stored.name === token)?.bytes;
    await keptStore("readwrite", (store) => store.delete(token));
    if (name && bytes) await keptStore("readwrite", (store) => store.put(bytes, name));
  }
  keptSummary = summary;
  keep("siday.kept", summary.join("\n"));
  toldKept?.(summary.join("\n"));
}
/// Takes, of what was chosen, the files that may be ones siday keeps: by their size, or how they begin.
async function takeKept(chosen) {
  // (A file that came in a drop is only an entry in a folder, and is opened here to be looked at: all
  // of them at once, since there may be many that are neither tunes nor anything kept.)
  const others = chosen.filter((item) => kindOf(item.name) === 0);
  const opened = await Promise.all(
    others.map((item) =>
      item.file instanceof Blob ? item.file : new Promise((resolve) => item.file.file(resolve, () => resolve(null))),
    ),
  );
  for (const file of opened) {
    if (!file) continue;
    const start = new Uint8Array(await file.slice(0, 16).arrayBuffer());
    const text = new TextDecoder().decode(start).replace(/^\uFEFF/, "");
    if (!keptSizes.includes(file.size) && !text.startsWith("[Database]") && !text.startsWith(";")) continue;
    const stored = { name: `given-${Date.now()}-${keptGiven++}`, bytes: await file.arrayBuffer() };
    await keptStore("readwrite", (store) => store.put(stored.bytes, stored.name));
    offerKept(stored);
  }
}

/// The levels of songs measured in this browser (see `SongLevel`), by what each is kept under: read
/// once, when one is first wanted. Only so many are kept, the oldest let go first.
let levels;
const levelsKept = 20000;
function levelOf(key) {
  if (!levels) {
    try {
      levels = JSON.parse(kept("siday.levels") ?? "{}");
    } catch {}
    if (typeof levels !== "object" || levels === null) levels = {};
  }
  return levels[key];
}
function keepLevel(key, text) {
  levelOf(key);
  delete levels[key];
  levels[key] = text;
  const keys = Object.keys(levels);
  for (const old of keys.slice(0, Math.max(0, keys.length - levelsKept))) delete levels[old];
  keep("siday.levels", JSON.stringify(levels));
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

// While the song is being made again for something the listener changed (a voice muted or brought
// back, mono or stereo, a setting), what they hear is still the song as it was. The controls that
// lead to that are shown as busy (see style.css) until the change can be heard: from a quarter of a second in, so
// that a short tune, which is made again at once, shows nothing; and once shown, for half a second
// at least, so that it does not blink.
let remakingWait;
let remakingSince;
function remaking(busy) {
  clearTimeout(remakingWait);
  const root = document.documentElement.classList;
  if (busy) {
    if (remakingSince === undefined) {
      remakingWait = setTimeout(() => {
        remakingSince = performance.now();
        root.add("remaking");
      }, 250);
    }
  } else if (remakingSince !== undefined) {
    remakingWait = setTimeout(() => {
      remakingSince = undefined;
      root.remove("remaking");
    }, Math.max(0, 500 - (performance.now() - remakingSince)));
  }
}

function heard(message) {
  if (message.type === "connected") return direct();
  // A song's level is kept whichever song is playing now.
  if (message.type === "level") return keepLevel(message.key, message.text);
  if (message.type === "kept") return void keptAnswer(message);
  // What the engine has to say of a tune is marked with the tune, and the rest with the run of sound.
  if ("tune" in message ? message.tune !== asked : message.serial !== serial) return;
  switch (message.type) {
    case "loaded": {
      // The song's level, if it was measured before, so that it need not be measured again; or
      // word that it was not, for the engine waits a moment to hear which before it sends sound.
      if (message.levelKey) {
        const text = levelOf(message.levelKey) ?? "";
        void sound?.then(({ engine }) => engine.postMessage({ type: "level", key: message.levelKey, text }));
      }
      listeners?.loaded(message.plays, message.text, message.songs, message.song, message.length);
      break;
    }
    case "songs":
      listeners?.songs(message.text);
      break;
    case "rendered":
      listeners?.rendered(message.seconds, message.length);
      break;
    case "remaking":
      remaking(message.busy);
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
        told = { position: message.position, bars: message.bars, voices: message.voices ?? [], scopes: message.scopes ?? null };
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

async function play(index, subsong, companions) {
  const request = ++asked;
  remaking(false);
  const tune = tunes[index];
  // The audio hardware was let go while the player was paused: it is taken up again now, while the
  // listener is pressing something.
  if (released) {
    released = false;
    renew(false);
  }
  // One made before any tune was played, for the files kept (see `offerKept`), is let start now.
  if (context?.state === "suspended") void context.resume();
  try {
    // With the tune, the files it needs beside its own that were found among those known, by their
    // places there (-1 for one that was not found, which is sent as nothing; and for a folder, the
    // places of its files, which are sent as one).
    const [bytes, { engine, output }, ...beside] = await Promise.all([
      read(tune.file),
      audio(),
      ...companions.map((place) => (Array.isArray(place) ? readFolder(place) : known[place] ? read(known[place].file) : null)),
    ]);
    if (request !== asked) return;
    // The output drops what it was playing at once; the engine starts on the new tune.
    const run = ++serial;
    output.port.postMessage({ type: "tune", serial: run });
    const name = new TextEncoder().encode(tune.name).buffer;
    // (Another song: every voice of it is heard, whatever was muted in the last.)
    told = undefined;
    mutedNow = undefined;
    engine.postMessage({ type: "load", tune: request, serial: run, name, bytes, companions: beside, subsong }, [name, bytes, ...beside.filter((item) => item)]);
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

/// Every file the page has been given since it was opened that is a tune or a tune's companion (a
/// file it keeps its samples or takes its instruments from), in the order it was given: { name, file }.
/// It is where a playlist's tunes and a tune's companions are looked for. A web page can only read
/// the files it is given, so neither can be fetched from the disk as a program fetches them: they
/// have to be here, handed over with the file that wants them or before it. The Swift side knows
/// them by their names, and finds what is wanted among them by its place here. (A tune taken out of
/// the list is still here.)
const known = [];
/// The place in `known` of each name.
const knownAt = new Map();

/// The page has been given files: the tunes and companions among them are known from now on, and
/// the Swift side is told their names. A file of a name that was known already takes the place of
/// the one that had it.
function remember(items) {
  const added = [];
  for (const item of items) {
    const place = knownAt.get(item.name);
    if (place !== undefined) {
      known[place] = { name: item.name, file: item.file };
    } else {
      knownAt.set(item.name, known.length);
      known.push({ name: item.name, file: item.file });
      added.push(item.name);
    }
  }
  // (In pieces: a whole collection is more than a browser will take as one piece of text at once.)
  for (let at = 0; at < added.length; at += 10000) finding?.given(added.slice(at, at + 10000).join("\n"));
}

/// The tunes that playlists name, found among those that are known: for each list its tunes in its
/// order, each with what the list says about it and whether it is a tune beside the list or below
/// it. With them, how many tunes the lists name in all and how many of those were not found. The
/// lists are read on the Swift side, which is given each list as text with a letter for each of its
/// bytes.
async function listed(lists) {
  const texts = await Promise.all(lists.map((list) => textOf(list.file)));
  const found = { lists: lists.map(() => []), named: lists.map(() => 0), missing: lists.map(() => 0) };
  if (!finding) return found;
  texts.forEach((text, which) => {
    const [counts, ...lines] = finding.listed(lists[which].name, text).split("\n");
    [found.named[which], found.missing[which]] = counts.split(" ").map(Number);
    for (const line of lines) {
      const [entry, place, below, note] = line.split("\t");
      if (note !== undefined) found.lists[which].push({ ...known[Number(place)], note, below: below === "1", entry: Number(entry) });
    }
  });
  return found;
}

/// A playlist's file as text with a letter for each of its bytes, as the Swift side reads them.
async function textOf(file) {
  const bytes = new Uint8Array(await read(file));
  let text = "";
  for (let at = 0; at < bytes.length; at += 8192) text += String.fromCharCode.apply(null, bytes.subarray(at, at + 8192));
  return text;
}

/// The playlists last read that name tunes which were not found, each with the entries of it that
/// were: they are finished when the listener says where the rest are (see `finish`).
let unfinished = [];

/// Playlists have been read (by `listed`): those with tunes still to find are kept for later, and
/// the Swift side is told how it came out, and what the list is called if it is one list.
function reckon(lists, found, before = []) {
  unfinished = lists
    .map((list, which) => ({ list, had: new Set([...(before[which] ?? []), ...found.lists[which].map((item) => item.entry)]) }))
    .filter((_, which) => found.missing[which] > 0);
  const sum = (numbers) => numbers.reduce((total, number) => total + number, 0);
  finding?.missed(sum(found.missing), sum(found.named), lists.length === 1 ? lists[0].name.split("/").pop() : "");
}

/// The listener has chosen the folder where the tunes of the unfinished playlists are, or the
/// companion of a tune that was not found. It is looked in and not added to the list: what is added
/// is the tunes of those playlists that had not been found, in the order the lists have them. (The
/// folder's tunes and companions are known from now on, as any are that the page has been given, and
/// a tune that was waiting for its companion is played, if it has been found.)
async function finish(chosen) {
  const here = chosen.filter((item) => kindOf(item.name) === 1 || kindOf(item.name) === 3);
  remember(here);
  const lists = unfinished.map((item) => item.list);
  const before = unfinished.map((item) => item.had);
  if (lists.length === 0 || here.length === 0) return;
  const found = await listed(lists);
  const accepted = found.lists.flatMap((items, which) => items.filter((item) => !before[which].has(item.entry)));
  if (accepted.length > 0) put(accepted);
  reckon(lists, found, before);
}

// While tunes are being taken in, which for a folder of a whole collection can take some seconds, a
// small notice at the foot of the window says so, and how far it has got. It comes only if the work
// is still going after a moment, so that a few tunes come and go with nothing shown; and its wheel
// turns on the browser's own, so it goes on turning while the page is busy with the list.
let adding;
let addingSince;
let addingWait;

/// Says what is being done, from the moment it has been going on for a third of a second.
function busy(text) {
  addingSince ??= performance.now();
  const show = () => {
    if (!adding) {
      adding = document.createElement("div");
      adding.className = "adding";
      adding.setAttribute("role", "status");
      adding.append(Object.assign(document.createElement("span"), { className: "wheel" }), document.createElement("span"));
      document.body.append(adding);
    }
    adding.lastChild.textContent = text;
  };
  clearTimeout(addingWait);
  if (adding || performance.now() - addingSince >= 300) show();
  else addingWait = setTimeout(show, 300 - (performance.now() - addingSince));
}

/// The tunes are in: the notice goes.
function idle() {
  clearTimeout(addingWait);
  adding?.remove();
  adding = undefined;
  addingSince = undefined;
}

/// Lets the browser show what has changed before the page goes on with work that holds it up. (A
/// page that is out of sight is shown nothing, and is not kept waiting for it.)
function breathe() {
  return new Promise((resolve) => {
    requestAnimationFrame(() => setTimeout(resolve, 0));
    setTimeout(resolve, 100);
  });
}

/// A count as the page writes them: 165,139.
function counted(count) {
  return count.toLocaleString("en-US");
}

/// What kind of file a name is: 1 for a tune, 2 for a playlist, 3 for a tune's companion, 0 for none
/// of those (see `listeners.kind`).
/// That goes by what follows the name's last full stop, so the page is asked once for each ending
/// and not once for each file: a whole collection is a great many files and few endings. A few
/// companions are known by the whole of their name and not by an ending (as `Companions.names` has
/// them), and a name with no full stop has no ending: those are asked about each time.
const kinds = new Map();
const companionsByName = new Set(["songplay", "wantedteam.bin"]);
function kindOf(name) {
  if (!listeners) return 0;
  const leaf = name.slice(name.lastIndexOf("/") + 1);
  const stop = leaf.lastIndexOf(".");
  if (stop < 0 || companionsByName.has(leaf.toLowerCase())) return listeners.kind(name);
  const ending = leaf.slice(stop + 1);
  let kind = kinds.get(ending);
  if (kind === undefined) {
    kind = listeners.kind(name);
    kinds.set(ending, kind);
  }
  return kind;
}

/// The order of names: as people count, so that a "2" comes before a "10", and with no difference
/// made between capitals and small letters. (One of these, made once, is far quicker over a long
/// list than asking each pair of names to be compared afresh.)
const names = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" });

/// Takes in what was chosen or dropped, saying so while it does.
async function take(chosen, how = add) {
  try {
    if (chosen.length > 0) {
      busy(`Adding ${counted(chosen.length)} files…`);
      await breathe();
    }
    await how(chosen);
  } finally {
    idle();
  }
}

/// Puts tunes in the list, here and on the Swift side: just before `anchor`, a tune already in it, or
/// after all of them if there is none (or it has been taken out meanwhile).
function put(accepted, anchor = null) {
  const at = anchor ? tunes.indexOf(anchor) : -1;
  // (One at a time: a whole collection is more than a browser will take as the arguments of one call.)
  const after = at >= 0 ? tunes.splice(at) : [];
  for (const item of accepted) tunes.push(item);
  for (const item of after) tunes.push(item);
  listeners?.added(accepted.map((item) => `${item.name}\t${item.note ?? ""}`).join("\n"), at);
}

/// Takes in what was chosen or dropped: just before `anchor`, a tune in the list, if one is given.
async function add(chosen, anchor = null) {
  // The files siday keeps, the MT-32's ROMs and the song lengths, known by what is in them.
  await takeKept(chosen);
  // HVSC's song-length database is taken for what it is and not for a tune.
  const database = chosen.find((item) => item.name.split("/").pop().toLowerCase() === "songlengths.md5");
  if (database) {
    songLengths = await read(database.file);
    if (sound) (await sound).engine.postMessage({ type: "songlengths", bytes: songLengths });
  }
  // Tunes, playlists and companions, in the order of their names. The tunes and companions are
  // known from now on, and are what the playlists' tunes are found among, with those given before.
  const sorted = chosen
    .map((item) => ({ ...item, kind: kindOf(item.name) }))
    .filter((item) => item.kind > 0)
    .sort((a, b) => names.compare(a.name, b.name));
  remember(sorted.filter((item) => item.kind === 1 || item.kind === 3));
  if (!finding) return;
  // The Swift side reads the playlists, and puts the tunes in the order they are played: a playlist
  // that was itself given is played as it is written, and a folder in the order of its names, with
  // the tunes a playlist in it names where the list is (see `gather` in Browser.swift).
  const lists = sorted.filter((item) => item.kind === 2);
  const texts = await Promise.all(lists.map((list) => textOf(list.file)));
  lists.forEach((list, which) => finding.read(list.name, texts[which]));
  const order = sorted
    .filter((item) => item.kind === 1 || item.kind === 2)
    .map((item) => `${item.kind}\t${item.own ? 1 : 0}\t${item.kind === 1 ? knownAt.get(item.name) : item.name}`);
  const [counts, ...lines] = finding.gather(order.join("\n")).split("\n");
  const accepted = [];
  const unfound = [];
  for (const line of lines) {
    const [first, second, third] = line.split("\t");
    if (first === "!") unfound.push({ which: Number(second), had: new Set(third ? third.split(",").map(Number) : []) });
    else accepted.push({ ...known[Number(first)], note: second ?? "" });
  }
  if (accepted.length > 0) put(accepted, anchor);
  // The lists that name tunes which were not found are kept, to be finished when the listener says
  // where the rest are; and the Swift side is told how it came out.
  if (lists.length > 0) {
    const own = lists.filter((item) => item.own);
    const read = own.length > 0 ? own : lists;
    unfinished = unfound.map(({ which, had }) => ({ list: read[which], had }));
    const [missing, named] = counts.split(" ").map(Number);
    finding.missed(missing, named, read.length === 1 ? read[0].name.split("/").pop() : "");
  }
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
  remaking(false);
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
const choosers = { files: chooser(false, take), folder: chooser(true, take), tunes: chooser(true, (chosen) => take(chosen, finish)) };

/// The files of a folder that is a tune's companion, by their places in `known`, as SidayKit's
/// `CompanionFolder.pack` puts them together: for each, its name's length and the name in UTF-8, and
/// its length and its bytes, each length in four bytes with the highest first. Null if there are none.
async function readFolder(places) {
  const files = places.filter((place) => known[place]).map((place) => known[place]);
  if (files.length === 0) return null;
  const read_ = await Promise.all(files.map((item) => read(item.file)));
  const names = files.map((item) => new TextEncoder().encode(item.name.split("/").pop()));
  const packed = new Uint8Array(names.reduce((sum, name, at) => sum + 8 + name.length + read_[at].byteLength, 0));
  const view = new DataView(packed.buffer);
  let at = 0;
  names.forEach((name, which) => {
    view.setUint32(at, name.length);
    packed.set(name, at + 4);
    at += 4 + name.length;
    view.setUint32(at, read_[which].byteLength);
    packed.set(new Uint8Array(read_[which]), at + 4);
    at += 4 + read_[which].byteLength;
  });
  return packed.buffer;
}

/// The bytes of a file: one that was chosen, or one that came in a drop, which is only an entry in
/// a folder until it is wanted (see `dropped`).
async function read(file) {
  if (file instanceof Blob) return file.arrayBuffer();
  const opened = await new Promise((resolve, reject) => file.file(resolve, reject));
  return opened.arrayBuffer();
}

/// Everything in what was dropped, folders included. A file that was dropped itself, and did not
/// come in a folder, is marked as its own.
///
/// What is kept of a file in a folder is its entry, and the file is opened only when it is played
/// or read as a playlist: a drop of a whole collection is many thousands of files, and opening each
/// of them as it is found was most of the time it took. (A file that cannot be read is found out
/// when it is played, and is said to be unreadable then.)
async function dropped(items) {
  const found = [];
  const itemOf = (entry, own) => ({ name: entry.fullPath.replace(/^\//, ""), file: entry, own });
  let told = 0;
  async function walk(entry, own) {
    if (entry.isFile) {
      found.push(itemOf(entry, own));
    } else if (entry.isDirectory) {
      const reader = entry.createReader();
      // A folder is read in batches until a batch comes back empty, and the folders in each are gone
      // into one after another.
      for (;;) {
        const batch = await new Promise((resolve, reject) => reader.readEntries(resolve, reject));
        if (batch.length === 0) break;
        for (const child of batch) if (child.isFile) found.push(itemOf(child, false));
        if (found.length - told >= 250) {
          told = found.length;
          busy(`Looking through folders… ${counted(found.length)} files found`);
        }
        for (const child of batch) if (child.isDirectory) await walk(child, false);
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

/// Where in the list what is being dragged over the page would go: the row it is over, and whether
/// before it or after it, by which half of the row it is over; nil when it is over no row.
function dropPlace(event) {
  const row = event.target instanceof Element ? event.target.closest(".rows li[data-index]") : null;
  if (!row) return null;
  const box = row.getBoundingClientRect();
  return { row, after: event.clientY > box.top + box.height / 2 };
}

/// The row that shows where what is dragged would go, by a line above or below it.
let dropRow = null;
function markDrop(place) {
  if (dropRow && dropRow !== place?.row) dropRow.removeAttribute("data-drop");
  dropRow = place?.row ?? null;
  dropRow?.setAttribute("data-drop", place.after ? "after" : "before");
}

document.addEventListener("dragover", (event) => {
  event.preventDefault();
  markDrop(dropPlace(event));
});
document.addEventListener("dragleave", (event) => {
  // (Off the page altogether.)
  if (!event.relatedTarget) markDrop(null);
});
document.addEventListener("drop", (event) => {
  event.preventDefault();
  markDrop(null);
  if (!event.dataTransfer) return;
  // Dropped on a row, it goes in the list there, just before the tune it is put before, wherever that
  // tune is by the time it has been looked through.
  const place = dropPlace(event);
  const anchor = place ? (tunes[Number(place.row.dataset.index) + (place.after ? 1 : 0)] ?? null) : null;
  // (Taken before anything is awaited: the list is emptied when the event is over.)
  const looking = dropped(event.dataTransfer.items);
  busy("Looking through what was dropped…");
  void looking.then((chosen) => take(chosen, (taken) => add(taken, anchor)), idle);
});

// What FORMATS.md says of a format, shown over the page when the format's name is pressed. The
// file is the one place it is written: the site carries a copy, fetched when first asked for, and
// the part wanted is found in it by its heading and set out as it would be on GitHub.
const source = "https://github.com/ptsochantaris/siday";
const formats = `${source}/blob/main/FORMATS.md`;
let readme;
let story;

/// A part of FORMATS.md: the one whose heading begins with this word, up to the next such heading
/// (its own headings, of three marks, are part of it).
function chapter(text, word) {
  const lines = text.split("\n");
  const heading = new RegExp(`^## ${word.replace(/[^A-Za-z0-9]/g, "")}(?![A-Za-z0-9])`);
  const start = lines.findIndex((line) => heading.test(line));
  if (start < 0) return null;
  let end = lines.findIndex((line, place) => place > start && /^## /.test(line));
  if (end < 0) end = lines.length;
  return { title: lines[start].replace(/^#+ /, ""), lines: lines.slice(start + 1, end) };
}

/// A piece of FORMATS.md's text as it is to be read: what is between backquotes as code, between
/// asterisks as stressed, and a link as a link.
function written(text, into) {
  let at = 0;
  for (const found of text.matchAll(/`([^`]+)`|\*\*([^*]+)\*\*|\*([^*\s][^*]*)\*|\[([^\]]+)\]\(((?:https?:|#)[^)\s]*)\)/g)) {
    into.append(text.slice(at, found.index));
    const [, code, strong, stressed, link, address] = found;
    const piece = document.createElement(code !== undefined ? "code" : strong !== undefined ? "strong" : stressed !== undefined ? "em" : "a");
    piece.textContent = code ?? strong ?? stressed ?? link;
    if (address !== undefined) {
      // A link to another part of the file goes to it where it is whole.
      piece.href = address.startsWith("#") ? formats + address : address;
      piece.target = "_blank";
      piece.rel = "noopener";
    }
    into.append(piece);
    at = found.index + found[0].length;
  }
  into.append(text.slice(at));
}

/// A chapter's lines as paragraphs, lists and headings. Lines with nothing between them are one paragraph.
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
    else if (/^###+ /.test(line)) {
      end();
      written(line.replace(/^#+ /, ""), into.appendChild(document.createElement("h3")));
    } else block.push(line);
  }
  end();
}

async function about(word) {
  readme ??= fetch(new URL("./generated/FORMATS.md", import.meta.url)).then((reply) => (reply.ok ? reply.text() : Promise.reject(new Error("no FORMATS.md"))));
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
    story.innerHTML = `<header><h2></h2><button title="Close (Esc)" aria-label="Close">×</button></header><div class="text" tabindex="0" autofocus></div><footer>From <a target="_blank" rel="noopener">siday's FORMATS.md</a>, which tells of every format.</footer>`;
    story.querySelector("a").href = formats;
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
  if (!document.hidden) drawScopes();
}

// The scopes: each voice's wave as the engine sent it with the sound now being heard (see
// `ChannelWaves`), 64 points a voice, drawn across its place in the colour of its lamp. Paused, or
// with nothing heard yet, each is a flat line. A scope is drawn again only when there is something
// new to draw in it.
function drawScopes() {
  const canvases = document.querySelectorAll("canvas.scope");
  if (canvases.length === 0) return;
  const scopes = silenced ? null : told?.scopes ?? null;
  const ratio = window.devicePixelRatio || 1;
  canvases.forEach((canvas, voice) => {
    const width = Math.round(canvas.clientWidth * ratio), height = Math.round(canvas.clientHeight * ratio);
    if (width === 0 || height === 0) return;
    const cell = canvas.parentElement;
    const look = `${width} ${height} ${cell.className}`;
    if (canvas.drawnFrom === scopes && canvas.look === look) return;
    canvas.drawnFrom = scopes;
    canvas.look = look;
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width;
      canvas.height = height;
    }
    const pen = canvas.getContext("2d");
    pen.clearRect(0, 0, width, height);
    const colour = getComputedStyle(cell).getPropertyValue("--trace").trim() || "#ff4a30";
    const margin = 4 * ratio, middle = height / 2, reach = height / 2 - margin;
    pen.lineWidth = 1.5 * ratio;
    pen.lineJoin = "round";
    pen.strokeStyle = colour;
    pen.shadowColor = colour;
    pen.shadowBlur = 4 * ratio;
    pen.beginPath();
    for (let point = 0; point < 64; point++) {
      const at = voice * 64 + point;
      const value = scopes && at < scopes.length ? (scopes[at] - 128) / 127 : 0;
      const x = margin + (point / 63) * (width - 2 * margin);
      if (point === 0) pen.moveTo(x, middle - value * reach);
      else pen.lineTo(x, middle - value * reach);
    }
    pen.stroke();
  });
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
// The browser's own Now Playing (a phone's lock screen, a computer's media controls): what is playing,
// with the picture of its chip; and what its buttons, and the media keys, do. A browser without it is
// let be. Most show it only while a media element plays, and the sound here goes through Web Audio
// alone: so while a tune plays, so does an element of silence, over and over, beside it.
let shownArtwork = null;
let quiet = null;

// Ten seconds of silence, as a WAV file of 8-bit samples, 8,000 a second, and an element to play it
// over and over. (Chrome counts a sound of less than five seconds as a notification's, and shows no
// controls for it.)
function silence() {
  const rate = 8000;
  const count = rate * 10;
  const bytes = new Uint8Array(44 + count);
  const view = new DataView(bytes.buffer);
  const write = (at, word) => [...word].forEach((letter, index) => (bytes[at + index] = letter.charCodeAt(0)));
  write(0, "RIFF");
  view.setUint32(4, 36 + count, true);
  write(8, "WAVEfmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, rate, true);
  view.setUint32(28, rate, true);
  view.setUint16(32, 1, true);
  view.setUint16(34, 8, true);
  write(36, "data");
  view.setUint32(40, count, true);
  bytes.fill(128, 44);
  const element = new Audio(URL.createObjectURL(new Blob([bytes], { type: "audio/wav" })));
  element.loop = true;
  return element;
}

function nowPlaying(title, author, album, artwork, length, position, playing) {
  const session = navigator.mediaSession;
  if (!session) return;
  if (title === "") {
    quiet?.pause();
    session.metadata = null;
    session.playbackState = "none";
    shownArtwork = null;
    return;
  }
  // (The browser may not let it start until the listener has pressed something on the page, as with
  // the sound itself; it is tried again the next time.)
  if (playing) {
    quiet ??= silence();
    quiet.play().catch(() => {});
  } else {
    quiet?.pause();
  }
  const shown = session.metadata;
  if (!shown || shown.title !== title || shown.artist !== author || shown.album !== album || shownArtwork !== artwork) {
    const pictures = artwork === "" ? [] : [{ src: new URL(artwork, document.baseURI).href, sizes: "512x512", type: "image/jpeg" }];
    session.metadata = new MediaMetadata({ title, artist: author, album, artwork: pictures });
    shownArtwork = artwork;
  }
  session.playbackState = playing ? "playing" : "paused";
  if (length > 0) {
    try {
      session.setPositionState({ duration: length, playbackRate: 1, position: Math.max(0, Math.min(position, length)) });
    } catch {}
  }
}

function mediaKeys(pressed) {
  const session = navigator.mediaSession;
  if (!session) return;
  // (A browser that does not have one of these says so by throwing.)
  const handle = (action, act) => {
    try {
      session.setActionHandler(action, act);
    } catch {}
  };
  handle("play", () => pressed(0, 0));
  handle("pause", () => pressed(1, 0));
  handle("nexttrack", () => pressed(2, 0));
  handle("previoustrack", () => pressed(3, 0));
  handle("seekto", (details) => pressed(4, details.seekTime ?? 0));
}

Object.assign(globalThis, {
  sidayNowPlaying(title, author, album, artwork, length, position, playing) {
    nowPlaying(title, author, album, artwork, length, position, playing);
  },
  sidayMediaKeys(pressed) {
    mediaKeys(pressed);
  },
  sidayListen(kind, added, loaded, songs, progress, rendered, ended, held, pointed, scrolled, frame) {
    listeners = { kind, added, loaded, songs, progress, rendered, ended, held, pointed, scrolled, frame };
  },
  sidayAbout(word) {
    void about(word);
  },
  sidayFiles(given, listed, read, gather, missed) {
    finding = { given, listed, read, gather, missed };
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
  sidayPlay(index, subsong, companions) {
    // (A folder's files are "f" and their places with commas between.)
    const entry = (item) => (item.startsWith("f") ? item.slice(1).split(",").filter((place) => place !== "").map(Number) : Number(item));
    starting = play(index, subsong, companions === "" ? [] : companions.split(" ").map(entry));
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
  sidayMove(from, to) {
    const [item] = tunes.splice(from, 1);
    tunes.splice(to > from ? to - 1 : to, 0, item);
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
    // The picture to listen by is away until it is asked for. (So are the scopes, by a mark of their
    // own, which holds for a listener who has been here before them too: see `Player.hidden`.)
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
  sidayListenKept(told) {
    toldKept = told;
    told(keptSummary.join("\n"));
  },
  sidayForgetKept() {
    keptSummary = [];
    keep("siday.kept", "");
    void keptStore("readwrite", (store) => store.clear());
    void sound?.then(({ engine }) => {
      engine.postMessage({ type: "forgetkept" });
      measuring?.postMessage({ type: "forgetkept" });
    });
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
