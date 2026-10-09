// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// The player's engine, in a worker of its own. It holds the SidayWebAudio WebAssembly module (SidayKit
// and nothing else), loads the tunes the page sends, and hands their sound in chunks to the audio
// thread (worklet.js), a little ahead of what is being heard. It is the arrangement the command-line
// player has: one thread makes the sound and another only plays it.
//
// It does not stop at a little ahead in the making, though. A song is rendered to its end as fast as
// the machine will go, and kept, so the listener can move to any place in it: these tunes are
// programs, and the only way to the middle of one is through everything before it. Moving is then a
// matter of sending from another place in what is kept; if the place has not been rendered yet, the
// sound waits until it has. A song costs 23 MB a minute while it is the one playing.
//
// Nothing is loaded or rendered on the audio thread itself. Loading a tune can take a good part of a
// second, and an audio thread held up for that long does not merely leave a gap: a browser may play
// catch-up afterwards, and everything after it is then heard late.

/// Frames in a chunk: eight of the module's 128-frame blocks, 21 ms. Each chunk sent carries the
/// position it reaches and the spectrum analyser's bars, so the page is told of both about 47 times a second.
const blocksPerChunk = 8;
const chunkFrames = blocksPerChunk * 128;
const sampleRate = 48000;
/// How far ahead to send: chunks handed over and not yet reported played. About a fifth of a second.
const ahead = 10;
/// How long to render before seeing whether there is anything else to do, in milliseconds.
const turn = 10;

let core;
/// A chunk's worth of the module's memory, for finishing each chunk on its way out.
let scratch;
/// The way to the audio thread, and back from it.
let output;

/// The tune that is loaded: the page's count of its requests to play.
let tune = 0;
/// The file it came from, and the song of it that was asked for: { name, bytes, subsong }. Kept in
/// case the song has to be rendered again.
let file;
/// The song as far as it has been rendered: { samples, position, last } for each chunk, in order,
/// the sound as the chip made it. The last chunk of the song is marked.
let kept = [];
/// True when there is no more of the song to render.
let complete = true;
/// The song's length in seconds, once all of it is rendered, if that is how it was found out: the
/// file did not say, and the song came to an end before the time it was allowed; or the file did
/// say, and the song fell silent for good before then. Otherwise 0.
let found = 0;
/// Silence left at the end of a song that ended by falling silent, in seconds.
const rest = 1;
/// True while `work` has another turn coming.
let working = false;
let reported = 0;

/// The run of sound being sent: the page starts another, with another number, for each tune and for
/// each move within one, and the audio thread drops what it has of the last.
let serial = 0;
/// The next chunk to send, by its place in `kept`.
let next = 0;
/// False once the last chunk of the song has been sent.
let sending = false;
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

/// Loads the tune in `file` and starts on the song asked for. Returns false if it cannot be played.
function load() {
  const plays = withBytes(file.name, (name, nameLength) =>
    withBytes(file.bytes, (data, length) => core.siday_load(data, length, name, nameLength)),
  ) === 1;
  if (plays && file.subsong >= 0) core.siday_select(file.subsong);
  kept = [];
  found = 0;
  complete = !plays;
  reported = 0;
  return plays;
}

/// Sends from a place in the song, in seconds from its start, as a new run of sound: at once if that
/// much of the song has been rendered, and when it has been if not.
function sendFrom(position, run) {
  serial = run;
  next = Math.max(0, Math.floor((position * sampleRate) / chunkFrames));
  waiting = 0;
  sending = true;
  core.siday_settle();
  send();
}

/// Sees that rendering is going on, if there is any to do.
function start() {
  if (complete || working) return;
  working = true;
  turns.port2.postMessage(0);
}

/// Renders the next chunk of the song and keeps it.
function render() {
  const samples = new Float32Array(chunkFrames * 2);
  let last = false;
  for (let block = 0; block < blocksPerChunk; block++) {
    last = core.siday_pull() === 0;
    // The memory can have grown, and moved, since the last time: the view is made afresh.
    samples.set(new Float32Array(core.memory.buffer, core.siday_output(), 256), block * 256);
    // What is left of the chunk after the tune's end stays silent.
    if (last) break;
  }
  kept.push({ samples, position: core.siday_position(), last });
  if (last) finish();
}

/// The whole song is rendered, and so it is known how it ends.
function finish() {
  complete = true;
  const end = kept[kept.length - 1].position;
  // A tune with no ending of its own is over when it has been silent for some seconds. Those seconds
  // were needed to find that out, and now it is known: a moment of them is kept and the rest dropped.
  const silence = core.siday_silence();
  if (silence > rest) {
    kept.length = Math.max(1, Math.min(kept.length, Math.ceil(((end - silence + rest) * sampleRate) / chunkFrames)));
    kept[kept.length - 1].last = true;
  }
  // Where the file gave no length the page was told the time the tune would be allowed. If the tune
  // did not need it all, its real length is the sound it made. So it is for a tune whose length is
  // known but which fell silent before it: a module with nothing but empty rows before it goes round.
  const length = end - silence;
  found = (core.siday_length_known() === 0 || silence > 0) && length > 0 && length < core.siday_length() ? length : 0;
}

/// Sends chunks until enough are waiting to be played, or there are no more to send yet.
function send() {
  // A place past the end of the song: its last moment is played, and so it ends.
  if (sending && complete && next >= kept.length) next = kept.length - 1;
  while (sending && waiting < ahead && next < kept.length) {
    const chunk = kept[next++];
    // The television and the spectrum analyser belong to what is heard, not to what is kept.
    new Float32Array(core.memory.buffer, scratch, chunkFrames * 2).set(chunk.samples);
    core.siday_present(scratch, chunkFrames);
    const samples = new Float32Array(core.memory.buffer, scratch, chunkFrames * 2).slice();
    // Asked for first: working the bars out can make the module's memory grow, and so move.
    const spectrum = core.siday_spectrum();
    const bars = new Uint8Array(core.memory.buffer, spectrum, core.siday_spectrum_bands() * 2).slice();
    output.postMessage({ type: "chunk", serial, samples, position: chunk.position, bars, last: chunk.last }, [samples.buffer]);
    waiting++;
    if (chunk.last) sending = false;
  }
}

/// Tells the page how much of the song there is to move about in.
function report() {
  const now = performance.now();
  if (!complete && now - reported < 100) return;
  reported = now;
  self.postMessage({ type: "rendered", tune, seconds: (kept.length * chunkFrames) / sampleRate, length: complete ? found : 0 });
}

// Rendering is done a turn at a time, with a message to itself between turns, so that word from the
// page and from the audio thread is heard promptly however long the song.
const turns = new MessageChannel();
turns.port1.onmessage = work;

function work() {
  const until = performance.now() + turn;
  while (!complete && performance.now() < until) {
    render();
    send();
  }
  report();
  working = !complete;
  if (working) turns.port2.postMessage(0);
}

/// From the audio thread: a chunk of this run has been played, so there is room for another.
function played(message) {
  if (message.serial !== serial) return;
  waiting--;
  send();
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
      scratch = core.siday_alloc(chunkFrames * 2 * 4);
      self.postMessage({ type: "ready" });
      break;
    }
    case "output":
      // The way to the audio thread: a line of the engine's own to it, or one through the page. It is
      // given again when the page makes a new audio thread.
      output = message.output;
      output.onmessage = (played_) => played(played_.data);
      break;
    case "load": {
      tune = message.tune;
      serial = message.serial;
      file = { name: message.name, bytes: message.bytes, subsong: message.subsong };
      const plays = load();
      const text = new TextDecoder().decode(new Uint8Array(core.memory.buffer, core.siday_text(), core.siday_text_length()));
      self.postMessage({
        type: "loaded", tune, plays, text,
        songs: core.siday_subsongs(), song: core.siday_subsong(), length: core.siday_length(),
      });
      next = 0;
      waiting = 0;
      sending = plays;
      start();
      break;
    }
    case "seek":
      // The listener has moved to another place in the song: sending goes on from there, as soon as
      // there is something there to send.
      if (kept.length === 0 && complete) break;
      sendFrom(message.position, message.serial);
      break;
    case "style":
      // What tunes are heard through. A television is no more than something in the way of the sound
      // as it is sent. Mono and stereo are what the chip makes, so a change between them means making
      // the song again: the page is told, and says where it had got to.
      if (core.siday_set_output(message.style) === 1 && file && !(kept.length === 0 && complete)) {
        self.postMessage({ type: "again", tune });
      }
      break;
    case "again":
      // The song is rendered again from its start, as it is now to be heard, and taken up where it
      // had got to. Until the rendering has reached that place, the sound waits.
      if (!file || !load()) break;
      sendFrom(message.position, message.serial);
      start();
      break;
    case "songlengths":
      withBytes(message.bytes, (data, length) => core.siday_set_songlengths(data, length));
      break;
  }
};
