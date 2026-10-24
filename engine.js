// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// The player's engine, in a worker of its own. It holds the SidayWebAudio WebAssembly module, which is
// SidayPlayer's `SongKeeper` (see Engine.swift there): it renders each song the page sends whole, as
// fast as the machine will go, and keeps it, so the listener can move to any place in it, and sends
// it in chunks to the audio thread (worklet.js), a little ahead of what is being heard. It is the
// arrangement the command-line player has: one thread makes the sound and another only plays it.
// What is here only carries word to the module and from it, and gives it its turns and the time.
//
// Nothing is loaded or rendered on the audio thread itself. Loading a tune can take a good part of a
// second, and an audio thread held up for that long does not merely leave a gap: a browser may play
// catch-up afterwards, and everything after it is then heard late.

/// How long to render before seeing whether there is anything else to do, in milliseconds.
const turn = 10;
/// Frames in a chunk, as the module sends them (`SongKeeper.chunkFrames`).
const chunkFrames = 1024;

let core;
/// The way to the audio thread, and back from it.
let output;
/// The way to the other worker that holds the module, `askedBy` in it: some tunes' songs are played
/// through to find how long they are, which can take a second or two, and the sound is not to wait
/// for that. This worker plays through as many as it needs to start (see `SongInfo.pending`), and the
/// other plays them all through and says what it found. In the other, the way back.
let measurer;
let askedBy;
/// What the other was last asked to play through, if it has not yet: only the latest, if it was asked
/// for several while it was busy.
let wanted;
/// The tune last loaded, as the page sent it: { tune, name, bytes, companions }, for the other worker.
let file;
/// True while `work` has another turn coming.
let working = false;
/// The time the module last asked to be woken at, and the timer that will.
let wakeAt = -1;
let waking;

/// The time, for the module: in seconds.
function now() {
  return performance.now() / 1000;
}

/// Copies bytes into the module's memory, calls `use(pointer, length)` and frees them again.
function withBytes(buffer, use) {
  const bytes = new Uint8Array(buffer);
  const pointer = core.siday_alloc(bytes.length);
  new Uint8Array(core.memory.buffer, pointer, bytes.length).set(bytes);
  const result = use(pointer, bytes.length);
  core.siday_free(pointer);
  return result;
}

/// Gives the module the files a tune needs beside its own: those that were found, and a place for
/// those that were not.
function giveCompanions(companions) {
  core.siday_companion(0, -1, 0);
  for (const companion of companions) {
    if (companion) withBytes(companion, (data, length) => core.siday_companion(data, length, 1));
    else core.siday_companion(0, 0, 0);
  }
}

/// Reads a message the module has packed, of `length` bytes (see `Packed` in Engine.swift).
function unpack(length) {
  const at = core.siday_packed();
  const view = new DataView(core.memory.buffer, at, length);
  let place = 0;
  return {
    number() {
      const value = view.getFloat64(place, true);
      place += 8;
      return value;
    },
    bytes() {
      const count = view.getInt32(place, true);
      place += 4;
      if (count < 0) return null;
      const bytes = new Uint8Array(core.memory.buffer, at + place, count).slice();
      place += count;
      return bytes;
    },
    text() {
      return new TextDecoder().decode(this.bytes());
    },
  };
}

/// Sends on everything the module has for the audio thread and the page, and sees that it is given
/// its turns and woken when it asks to be.
function pass() {
  for (let length; (length = core.siday_take_sent()) !== 0; ) {
    const message = unpack(length);
    const serial = message.number();
    message.number();
    const position = message.number(), last = message.number() === 1;
    const bars = message.bytes(), voices = message.bytes(), scopes = message.bytes();
    const samples = new Float32Array(core.memory.buffer, core.siday_samples(), chunkFrames * 2).slice();
    output.postMessage({ type: "chunk", serial, samples, position, bars, voices, scopes, last }, [samples.buffer]);
  }
  for (let length; (length = core.siday_take_event()) !== 0; ) {
    const message = unpack(length);
    const kind = message.number(), tune = message.number();
    switch (kind) {
      case 1: {
        const plays = message.number() === 1, songs = message.number(), song = message.number(), length = message.number();
        self.postMessage({ type: "loaded", tune, plays, songs, song, length, text: message.text(), levelKey: message.text() });
        break;
      }
      case 2:
        self.postMessage({ type: "level", tune, key: message.text(), text: message.text() });
        break;
      case 3:
        self.postMessage({ type: "rendered", tune, seconds: message.number(), length: message.number() });
        break;
      case 4:
        self.postMessage({ type: "remaking", tune, busy: message.number() === 1 });
        break;
      case 5:
        self.postMessage({ type: "muted", tune, marks: Array.from(message.bytes()) });
        break;
      case 6:
        if (file?.tune === tune) measurer?.postMessage(file);
        break;
      case 7:
        self.postMessage({ type: "songs", tune, text: message.text() });
        break;
    }
  }
  // Rendering is done a turn at a time, with a message to itself between turns, so that word from
  // the page and from the audio thread is heard promptly however long the song.
  if (!working && core.siday_working() === 1) {
    working = true;
    turns.port2.postMessage(0);
  }
  const at = core.siday_wakes_at();
  if (at !== wakeAt) {
    wakeAt = at;
    clearTimeout(waking);
    if (at >= 0) waking = setTimeout(wake, Math.max(0, (at - now()) * 1000) + 10);
  }
}

function wake() {
  wakeAt = -1;
  core.siday_work(0, now());
  pass();
}

const turns = new MessageChannel();
turns.port1.onmessage = work;

function work() {
  const until = performance.now() + turn;
  while (core.siday_working() === 1 && performance.now() < until) {
    core.siday_work(1, now());
    pass();
  }
  working = core.siday_working() === 1;
  if (working) turns.port2.postMessage(0);
}

/// In the other worker: plays the songs of the tune last asked for through, and sends what was found.
function measureWanted() {
  const request = wanted;
  if (!request) return;
  // (Asked before the module has been started here: it is asked again in a moment.)
  if (!core) return void setTimeout(measureWanted, 50);
  wanted = undefined;
  giveCompanions(request.companions);
  const length = withBytes(request.name, (name, nameLength) =>
    withBytes(request.bytes, (data, dataLength) => core.siday_measure(data, dataLength, name, nameLength)),
  );
  if (length === 0) return;
  const found = new Uint8Array(core.memory.buffer, core.siday_packed(), length).slice();
  askedBy.postMessage({ tune: request.tune, found }, [found.buffer]);
}

self.onmessage = async (event) => {
  const message = event.data;
  switch (message.type) {
    case "start": {
      const { instance } = await WebAssembly.instantiate(message.module, {
        wasi_snapshot_preview1: {
          // Swift seeds its hash tables with this.
          random_get(pointer, length) {
            crypto.getRandomValues(new Uint8Array(core.memory.buffer, pointer, length));
            return 0;
          },
        },
      });
      core = instance.exports;
      core._initialize();
      self.postMessage({ type: "ready" });
      return;
    }
    case "measurer":
      // The way to the worker that plays songs through (see `measurer`): what it found is kept, and
      // if it is of the tune that is loaded, the page is told how long its songs are.
      measurer = message.port;
      measurer.onmessage = ({ data: { tune, found } }) => {
        if (!core) return;
        withBytes(found, (data, length) => core.siday_adopt(data, length, tune));
        pass();
      };
      return;
    case "measuring":
      // This worker is that one: it plays the songs of the tunes it is sent through, the latest first.
      askedBy = message.port;
      askedBy.onmessage = (event) => {
        wanted = event.data;
        setTimeout(measureWanted, 0);
      };
      return;
    case "output":
      // The way to the audio thread: a line of the engine's own to it, or one through the page. It is
      // given again when the page makes a new audio thread.
      output = message.output;
      output.onmessage = ({ data }) => {
        core.siday_played(data.serial, now());
        pass();
      };
      return;
    case "load":
      file = { tune: message.tune, name: message.name, bytes: message.bytes, companions: message.companions ?? [] };
      giveCompanions(file.companions);
      withBytes(file.name, (name, nameLength) =>
        withBytes(file.bytes, (data, length) =>
          core.siday_load(data, length, name, nameLength, message.tune, message.serial, message.subsong ?? -1, now()),
        ),
      );
      break;
    case "seek":
      core.siday_seek(message.position, message.serial, now());
      break;
    case "mute":
      core.siday_mute(message.light, message.solo ? 1 : 0);
      break;
    case "style":
      core.siday_set_output(message.style);
      break;
    case "settings": {
      const values = Float64Array.from(message.values);
      withBytes(values.buffer, (pointer) => core.siday_set_settings(pointer, values.length));
      break;
    }
    case "stop":
      file = undefined;
      core.siday_stop();
      break;
    case "level": {
      // The level the page kept for the song, from when it was measured before, or none.
      const key = new TextEncoder().encode(message.key), level = new TextEncoder().encode(message.text ?? "");
      withBytes(key.buffer, (keyAt, keyLength) => withBytes(level.buffer, (levelAt, levelLength) => core.siday_set_kept_level(keyAt, keyLength, levelAt, levelLength, now())));
      break;
    }
    case "songlengths":
      withBytes(message.bytes, (data, length) => core.siday_set_songlengths(data, length));
      break;
  }
  if (core) pass();
};
