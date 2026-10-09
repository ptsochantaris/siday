// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// The audio thread. It makes no sound of its own: the engine (engine.js, in a worker) renders the tune
// and sends it here in chunks, a little ahead, and this plays them, 128 frames at a time. It never
// waits for anything; when it has nothing to play it plays silence. Plain JavaScript with no imports:
// it is loaded as it stands by audioWorklet.addModule.

class SidayOutput extends AudioWorkletProcessor {
  constructor() {
    super();
    /// Chunks waiting to be played, in order: { samples, position, bars, lights, last }.
    this.queue = [];
    /// How far into the first of them playing has got, in frames.
    this.offset = 0;
    /// The run of sound being played: a tune, or a tune from some place in it. Chunks of any other are dropped.
    this.serial = 0;
    // Pausing fades the sound out over one block and resuming fades it in, so neither clicks.
    this.paused = false;
    this.audible = true;
    this.port.onmessage = (event) => this.told(event.data);
    if (sampleRate !== 48000) console.warn(`siday: the audio runs at ${sampleRate} Hz, not 48000; tunes will play at the wrong pitch`);
  }

  /// From the page.
  told(message) {
    switch (message.type) {
      case "engine":
        // The line to the engine: chunks come in on it, and word of each one played goes back.
        this.engine = message.port;
        this.engine.onmessage = (event) => this.told(event.data);
        this.port.postMessage({ type: "connected" });
        break;
      case "chunk":
        // From the engine, or passed along by the page if the engine's line could not be had.
        if (message.serial === this.serial) this.queue.push(message);
        break;
      case "tune":
        // Another tune has been chosen: what was waiting of the last one is dropped at once.
        this.serial = message.serial;
        this.queue = [];
        this.offset = 0;
        this.paused = false;
        this.audible = true;
        break;
      case "seek":
        // Another place in the same tune: the same, but a paused player stays paused.
        this.serial = message.serial;
        this.queue = [];
        this.offset = 0;
        break;
      case "pause":
        this.paused = message.paused;
        break;
    }
  }

  process(inputs, outputs) {
    const left = outputs[0][0], right = outputs[0][1] ?? outputs[0][0];
    for (let start = 0; start + 128 <= left.length; start += 128) {
      // Paused and faded out, or nothing has arrived yet: silence, and the tune stays where it is.
      if (this.paused && !this.audible) return true;
      const chunk = this.queue[0];
      if (!chunk) return true;

      // The page hears of each chunk as it begins to play: where the song has got to, and the
      // spectrum analyser's bars and the voices' lights for it.
      if (this.offset === 0) {
        this.port.postMessage({ type: "progress", serial: this.serial, position: chunk.position, bars: chunk.bars, lights: chunk.lights });
      }
      // 1 throughout, or a ramp down to silence or up from it across this block.
      const from = this.audible ? 1 : 0, to = this.paused ? 0 : 1;
      const samples = chunk.samples, base = this.offset * 2;
      for (let frame = 0; frame < 128; frame++) {
        const gain = from + ((to - from) * frame) / 128;
        left[start + frame] = samples[base + frame * 2] * gain;
        right[start + frame] = samples[base + frame * 2 + 1] * gain;
      }
      this.audible = !this.paused;

      this.offset += 128;
      if (this.offset * 2 >= samples.length) {
        this.queue.shift();
        this.offset = 0;
        (this.engine ?? this.port).postMessage({ type: "played", serial: this.serial });
        if (chunk.last) this.port.postMessage({ type: "ended", serial: this.serial });
      }
    }
    return true;
  }
}

registerProcessor("siday", SidayOutput);
