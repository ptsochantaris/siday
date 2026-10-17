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
/// position it reaches, the spectrum analyser's bars and the lights of the tune's voices, so the page is
/// told of them all about 47 times a second.
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
/// The file it came from, the files it needs beside its own, and the song of it that was asked for:
/// { name, bytes, companions, subsong }, a companion that was not found being null. Kept in case the
/// song has to be rendered again.
let file;
/// The song as far as it has been rendered: { samples, position, last, voices } for each chunk, in
/// order, the sound as the chip made it and what its voices were doing in it: for each, how bright
/// its light is, its pitch, whether a note was started on it, its side, and whether it is playing a
/// sample. The last chunk of the song is marked. The list says of itself which voices were left out
/// of it (`mutes`, see `written`), and once all of it is there, that it is `done` and the length
/// that was `found`.
let kept = [];
/// What is being sent to be heard: `kept`, but for a while after the listener has muted a voice or
/// brought one back. The song is then being rendered again, into a new `kept`, and what was kept
/// before goes on being heard until the new has got as far as the listener is.
let source = kept;
/// The voices the listener has left out of the sound: a byte for each voice of the tune, 1 for one
/// that is not to be heard; nothing, when every voice is. It lasts as long as the song does.
let mask;
/// How the song turned out when it was rendered with every voice heard: how many chunks, and the
/// length found. A song with voices left out is made to come out the same, whatever silence there
/// is in it. Nothing, until the song has been rendered so to its end.
let whole;
/// Which of the tune's voices have a light on the page. Some voices are ones a tune may never use (a
/// ZX Spectrum's beeper, the samples played on a SID's volume), and get a light once they have been
/// heard in the song as far as it is rendered, which is well ahead of what is playing.
let shown = [];
/// How bright a light has to have been for its voice to count as heard, of 255.
const heard = 24;
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
/// True while what is heard is not yet what the listener last asked for: a voice muted or brought
/// back, or the song being made again for another output or setting, that has not yet caught up.
let remaking = false;
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
/// Until when sending waits, after a song is loaded and while songs are levelled, for the song's
/// level: first a moment for the page to say what level was kept for it, so that a song measured
/// before starts at its level; and then, if none was, up to a second more while it is measured as
/// it is rendered. A song that is measured whole in that time starts at its level; one that is
/// not starts at about it, by as much of it as has been measured, and glides to it once the whole
/// of it has been. Nothing once the level is known, or the song is on its way.
let levelWait;
/// True once the moment for the page to answer is over, and the song is being measured.
let measuring = false;
const keptWaitLongest = 150;
const measuringWaitLongest = 1000;

/// The song was not measured before: it is given a little time to be measured now.
function waitForMeasuring() {
  measuring = true;
  levelWait = performance.now() + measuringWaitLongest;
  setTimeout(send, measuringWaitLongest + 10);
}

/// What the song's level is kept under, by the page (see `SongLevel.key`): the same for the same song
/// of the same file, played the same way.
function levelKey() {
  return new TextDecoder().decode(new Uint8Array(core.memory.buffer, core.siday_level_key(), core.siday_level_key_length()));
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

/// A mask as a word: the same word for the same voices left out, and nothing for none.
function written(marks) {
  return marks && marks.some((mark) => mark) ? marks.join("") : "";
}

/// Tells the module which voices to leave out of the tune when it is next loaded. Returns false if
/// it cannot do that yet: it has first to play the song through whole, to know how it ends.
function leaveOut(marks) {
  if (written(marks) === "") return core.siday_set_muted(0, 0) === 1;
  const pointer = core.siday_alloc(marks.length);
  new Uint8Array(core.memory.buffer, pointer, marks.length).set(marks);
  const can = core.siday_set_muted(pointer, marks.length) === 1;
  core.siday_free(pointer);
  return can;
}

/// Loads the tune in `file` and starts on the song asked for, with the voices in `marks` left out
/// of it (the module must have said it can: see `leaveOut`). Returns false if it cannot be played.
/// What was being sent goes on being sent if `meanwhile` says so: the song is the same song.
function load(marks, meanwhile = false) {
  const before = source;
  leaveOut(marks);
  // (The files it needs beside its own, first: those that were found, and a place for those that were not.)
  core.siday_companion(0, -1, 0);
  for (const companion of file.companions) {
    if (companion) withBytes(companion, (data, length) => core.siday_companion(data, length, 1));
    else core.siday_companion(0, 0, 0);
  }
  const plays = withBytes(file.name, (name, nameLength) =>
    withBytes(file.bytes, (data, length) => core.siday_load(data, length, name, nameLength)),
  ) === 1;
  if (plays && file.subsong >= 0) core.siday_select(file.subsong);
  kept = [];
  kept.mutes = written(marks);
  source = meanwhile && plays ? before : kept;
  found = 0;
  complete = !plays;
  reported = 0;
  // (The lights that have come on stay on, if it is the same song with the same voices.)
  const voices = plays ? core.siday_lights_count() : 0;
  if (!meanwhile || shown.length !== voices) {
    const always = plays ? core.siday_lights_always() : 0;
    shown = Array.from({ length: voices }, (_, voice) => voice < always);
  }
  return plays;
}

/// Renders the playing song again from its start, because what it is heard through, or a setting,
/// has changed in a way that changes what is made. What was being heard goes on being heard, as it
/// was, until the new rendering has got as far as the listener is; and the page is told of the
/// tune again, since how long it is to be played may have changed. It is the song that was
/// playing, whichever the file would now be started at. And it is rendered whole first, whatever
/// voices are left out: how it ends may have changed, and that has to be known before it can be
/// rendered without them.
function again() {
  if (!file || (source.length === 0 && complete)) return;
  if (core.siday_subsongs() > 0) file.subsong = core.siday_subsong();
  whole = undefined;
  if (!load(undefined, true)) return;
  const text = new TextDecoder().decode(new Uint8Array(core.memory.buffer, core.siday_text(), core.siday_text_length()));
  self.postMessage({
    type: "loaded", tune, plays: true, text,
    songs: core.siday_subsongs(), song: core.siday_subsong(), length: core.siday_length(), levelKey: levelKey(),
  });
  start();
}

/// Sees that the song is being rendered as the listener now wants to hear it: with the voices of
/// `mask` left out. What is being heard goes on until the new rendering has caught up with it.
function remix() {
  if (!file || (source.length === 0 && complete)) return;
  const wanted = written(mask);
  if (kept.mutes === wanted) return;
  // What is being heard may be the very thing, if the listener has changed their mind again.
  if (source.mutes === wanted && source.done) {
    kept = source;
    complete = true;
    found = source.found;
    return;
  }
  // A song with voices left out ends as the whole song does, which has to be known first. If it is
  // not, the whole song is still being rendered, and this is come back to when it has been.
  if (wanted !== "" && !whole) {
    if (kept.mutes !== "" && load(undefined, true)) start();
    return;
  }
  if (load(mask, true)) start();
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
  // Asked for first, as below.
  const taken = core.siday_lights();
  const count = shown.length;
  // Five rows: a light for each voice, its pitch, whether a note was started on it, its side, and
  // whether it is playing a sample.
  const voices = new Uint8Array(core.memory.buffer, taken, count * 5).slice();
  for (let voice = 0; voice < count; voice++) if (voices[voice] >= heard) shown[voice] = true;
  // And each voice's scope as the chunk ends: 64 points a voice.
  const scoped = count > 0 ? core.siday_scopes() : 0;
  const scopes = scoped ? new Uint8Array(core.memory.buffer, scoped, count * 64).slice() : null;
  kept.push({ samples, position: core.siday_position(), last, voices, scopes });
  if (kept.mutes !== "" && whole) {
    // With voices left out, the song is as long as it is whole: no longer, whatever the module
    // went on to render, and its length the length that was found then.
    if (last || kept.length >= whole.chunks) {
      kept.length = Math.min(kept.length, whole.chunks);
      kept[kept.length - 1].last = true;
      complete = true;
      found = whole.found;
      kept.done = true;
      kept.found = found;
    }
    return;
  }
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
  kept.done = true;
  kept.found = found;
  // And how loud it is, if it was measured as it was rendered, for the page to keep.
  const level = core.siday_level_length();
  if (level > 0) {
    const text = new TextDecoder().decode(new Uint8Array(core.memory.buffer, core.siday_level(), level));
    self.postMessage({ type: "level", tune, key: levelKey(), text });
  }
  // That was the whole song, and how it ends is now known: if the listener has voices left out, it
  // can be rendered as they want it.
  whole = { chunks: kept.length, found };
  remix();
}

/// Sends chunks until enough are waiting to be played, or there are no more to send yet.
function send() {
  if (levelWait !== undefined) {
    if (core.siday_waits_for_level() === 1) {
      if (performance.now() < levelWait) return;
      if (!measuring) {
        waitForMeasuring();
        return;
      }
      core.siday_start_at_provisional_level();
    }
    levelWait = undefined;
  }
  // The song as the listener now wants it is taken up as soon as it has been rendered past the
  // place they are at; and whatever there is of the song is, if what was being heard has run out.
  if (source !== kept && ((kept.mutes === written(mask) && (kept.length > next + ahead || complete)) || (next >= source.length && kept.length > next))) {
    source = kept;
  }
  // A place past the end of the song: its last moment is played, and so it ends.
  if (sending && source.done && next >= source.length) next = source.length - 1;
  while (sending && waiting < ahead && next < source.length) {
    const chunk = source[next++];
    // The television and the spectrum analyser belong to what is heard, not to what is kept.
    new Float32Array(core.memory.buffer, scratch, chunkFrames * 2).set(chunk.samples);
    core.siday_present(scratch, chunkFrames);
    const samples = new Float32Array(core.memory.buffer, scratch, chunkFrames * 2).slice();
    // Asked for first: working the bars out can make the module's memory grow, and so move.
    const spectrum = core.siday_spectrum();
    const bars = new Uint8Array(core.memory.buffer, spectrum, core.siday_spectrum_bands() * 2).slice();
    // The voices that have a light, row by row as they were kept; and a sixth row, for which of
    // them the listener has left out, as that stands now.
    const lit = chunk.voices.filter((_, place) => shown[place % shown.length]);
    const voices = new Uint8Array(lit.length + lit.length / 5);
    voices.set(lit);
    let light = 0;
    for (let voice = 0; voice < shown.length; voice++) {
      if (shown[voice]) voices[lit.length + light++] = mask && mask[voice] ? 1 : 0;
    }
    // The scopes of the voices that have a light, in the same order.
    let scopes = null;
    if (chunk.scopes) {
      scopes = new Uint8Array(light * 64);
      let place = 0;
      for (let voice = 0; voice < shown.length; voice++) {
        if (shown[voice]) scopes.set(chunk.scopes.subarray(voice * 64, voice * 64 + 64), 64 * place++);
      }
    }
    output.postMessage({ type: "chunk", serial, samples, position: chunk.position, bars, voices, scopes, last: chunk.last }, [samples.buffer]);
    waiting++;
    if (chunk.last) sending = false;
  }
}

/// Tells the page how much of the song there is to move about in.
function report() {
  const now = performance.now();
  if (!complete && now - reported < 100) return;
  reported = now;
  // (While a song is being rendered again for a voice muted or brought back, there is as much of
  // it to move about in as there was.)
  const chunks = Math.max(kept.length, source.length);
  const length = complete ? found : source.done ? source.found : 0;
  self.postMessage({ type: "rendered", tune, seconds: (chunks * chunkFrames) / sampleRate, length });
}

/// Tells the page when the song starts or stops being made again for the listener (see `remaking`),
/// so that it can show the controls that asked for it as busy.
function sayRemaking() {
  const now = file !== undefined && (source !== kept || kept.mutes !== written(mask));
  if (now === remaking) return;
  remaking = now;
  self.postMessage({ type: "remaking", tune, busy: now });
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
  sayRemaking();
  working = !complete;
  if (working) turns.port2.postMessage(0);
}

/// From the audio thread: a chunk of this run has been played, so there is room for another.
function played(message) {
  if (message.serial !== serial) return;
  waiting--;
  send();
  sayRemaking();
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
      file = { name: message.name, bytes: message.bytes, companions: message.companions ?? [], subsong: message.subsong };
      // Another song: every voice of it is heard.
      mask = undefined;
      whole = undefined;
      const plays = load();
      const text = new TextDecoder().decode(new Uint8Array(core.memory.buffer, core.siday_text(), core.siday_text_length()));
      self.postMessage({
        type: "loaded", tune, plays, text,
        songs: core.siday_subsongs(), song: core.siday_subsong(), length: core.siday_length(),
        levelKey: plays ? levelKey() : "",
      });
      next = 0;
      waiting = 0;
      sending = plays;
      if (plays) {
        measuring = false;
        levelWait = performance.now() + keptWaitLongest;
        setTimeout(send, keptWaitLongest + 10);
      }
      start();
      break;
    }
    case "seek":
      // The listener has moved to another place in the song: sending goes on from there, as soon as
      // there is something there to send.
      if (source.length === 0 && complete) break;
      sendFrom(message.position, message.serial);
      break;
    case "mute": {
      // The listener has pressed a light: to mute its voice or bring it back, or, with `solo`, to
      // hear it alone (and pressed again on a voice heard alone, to bring the others back). The
      // light is counted among those that are shown.
      const voice = shown.map((lit, place) => (lit ? place : -1)).filter((place) => place >= 0)[message.light];
      if (voice === undefined) break;
      let marks = mask ? mask.slice() : new Uint8Array(shown.length);
      if (message.solo) {
        const alone = marks.every((mark, place) => (place === voice ? mark === 0 : mark === 1));
        marks = marks.map((_, place) => (alone || place === voice ? 0 : 1));
      } else {
        marks[voice] ^= 1;
      }
      mask = marks.some((mark) => mark) ? marks : undefined;
      remix();
      // The lights are told of it with the sound that is sent from now on, whichever sound that is;
      // and the page at once, since what it shows is the sound of a moment ago.
      self.postMessage({ type: "muted", tune, marks: Array.from(marks.filter((_, place) => shown[place])) });
      break;
    }
    case "style":
      // What tunes are heard through. A television is no more than something in the way of the sound
      // as it is sent. Mono and stereo are what the chip makes, so a change between them means making
      // the song again.
      if (core.siday_set_output(message.style) === 1) again();
      break;
    case "settings": {
      // The listener's settings: a number for each. If one has changed that has to do with the tune
      // that is loaded, the song has to be made again, as for a change between mono and stereo.
      const values = Float64Array.from(message.values);
      const pointer = core.siday_alloc(values.byteLength);
      new Float64Array(core.memory.buffer, pointer, values.length).set(values);
      const changes = core.siday_set_settings(pointer, values.length) === 1;
      core.siday_free(pointer);
      if (changes) again();
      break;
    }
    case "stop":
      // The tune has been taken out of the list, and nothing follows it: the song is let go.
      file = undefined;
      kept = [];
      source = kept;
      mask = undefined;
      whole = undefined;
      complete = true;
      sending = false;
      break;
    case "level":
      // The level the page kept for the song, from when it was measured before, or none.
      if (file && message.key === levelKey()) {
        if (message.text) withBytes(new TextEncoder().encode(message.text).buffer, (text, length) => core.siday_set_level(text, length));
        // (None was kept: the song is measured now, for a moment, before it is heard.)
        if (levelWait !== undefined && !measuring && core.siday_waits_for_level() === 1) waitForMeasuring();
        send();
      }
      break;
    case "songlengths":
      withBytes(message.bytes, (data, length) => core.siday_set_songlengths(data, length));
      break;
  }
  if (core) sayRemaking();
};
