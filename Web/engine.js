// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// The player's engine, in a worker of its own. It holds the SidayWebAudio WebAssembly module (SidayKit
// and nothing else), loads the tunes the page sends, and renders a little way ahead of what is being
// heard, handing the sound in chunks to the audio thread (worklet.js). It is the arrangement the
// command-line player has: one thread makes the sound and another only plays it.
//
// Nothing is loaded or rendered on the audio thread itself. Loading a tune can take a good part of a
// second, and an audio thread held up for that long does not merely leave a gap: a browser may play
// catch-up afterwards, and everything after it is then heard late.

/// Frames in a chunk: eight of the module's 128-frame blocks, 21 ms. Each chunk carries the position
/// it reaches and the spectrum analyser's bars, so the page is told of both about 47 times a second.
const blocksPerChunk = 8;
const chunkFrames = blocksPerChunk * 128;
/// How far ahead to render: chunks handed over and not yet reported played. About a fifth of a second.
const ahead = 10;

let core;
/// The way to the audio thread, and back from it.
let output;
/// The tune being rendered: the page's count of its requests to play.
let serial = 0;
let playing = false;
/// Chunks handed to the audio thread that it has not yet played.
let waiting = 0;

/// Copies bytes into the module's memory, calls `use(pointer, length)` and frees them again.
function withBytes(buffer, use) {
  const bytes = new Uint8Array(buffer);
  const pointer = core.siday_alloc(bytes.length);
  new Uint8Array(core.memory.buffer, pointer, bytes.length).set(bytes);
  const result = use(pointer, bytes.length);
  core.siday_free(pointer);
  return result;
}

/// Renders chunks until enough are waiting to be played, or the tune is over.
function render() {
  while (playing && waiting < ahead) {
    const samples = new Float32Array(chunkFrames * 2);
    let last = false;
    for (let block = 0; block < blocksPerChunk; block++) {
      last = core.siday_pull() === 0;
      // The memory can have grown, and moved, since the last time: the view is made afresh.
      samples.set(new Float32Array(core.memory.buffer, core.siday_output(), 256), block * 256);
      // What is left of the chunk after the tune's end stays silent.
      if (last) break;
    }
    const bars = new Uint8Array(core.memory.buffer, core.siday_spectrum(), core.siday_spectrum_bands() * 2).slice();
    output.postMessage({ type: "chunk", serial, samples, position: core.siday_position(), bars, last }, [samples.buffer]);
    waiting++;
    if (last) playing = false;
  }
}

/// From the audio thread: a chunk of this tune has been played, so there is room for another.
function played(message) {
  if (message.serial !== serial) return;
  waiting--;
  render();
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
      output = message.output;
      output.onmessage = (played_) => played(played_.data);
      self.postMessage({ type: "ready" });
      break;
    }
    case "output":
      // Another way to the audio thread, through the page.
      output = message.output;
      output.onmessage = (played_) => played(played_.data);
      break;
    case "load": {
      serial = message.serial;
      waiting = 0;
      const plays = withBytes(message.name, (name, nameLength) =>
        withBytes(message.bytes, (data, length) => core.siday_load(data, length, name, nameLength)),
      ) === 1;
      if (plays && message.subsong >= 0) core.siday_select(message.subsong);
      const text = new TextDecoder().decode(new Uint8Array(core.memory.buffer, core.siday_text(), core.siday_text_length()));
      self.postMessage({
        type: "loaded", serial, plays, text,
        songs: core.siday_subsongs(), song: core.siday_subsong(), length: core.siday_length(),
      });
      playing = plays;
      render();
      break;
    }
    case "television":
      core.siday_set_television(message.set);
      break;
    case "songlengths":
      withBytes(message.bytes, (data, length) => core.siday_set_songlengths(data, length));
      break;
  }
};
