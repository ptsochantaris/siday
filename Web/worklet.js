// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// The audio thread. It holds the SidayWebAudio WebAssembly module (SidayKit and nothing else), gives it
// the tunes the page sends, and asks it for sound 128 frames at a time. Plain JavaScript with no
// imports: it is loaded as it stands by audioWorklet.addModule.

class SidayProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    const instance = new WebAssembly.Instance(new WebAssembly.Module(options.processorOptions.module), {
      wasi_snapshot_preview1: {
        // Swift seeds its hash tables with this. Nothing here needs it to be unguessable.
        random_get: (pointer, length) => {
          const bytes = new Uint8Array(this.core.memory.buffer, pointer, length);
          for (let index = 0; index < length; index++) bytes[index] = Math.random() * 256;
          return 0;
        },
      },
    });
    this.core = instance.exports;
    this.core._initialize();
    this.serial = 0;
    this.playing = false;
    this.quanta = 0;
    this.peak = 0;
    this.port.onmessage = (event) => this.receive(event.data);
    if (sampleRate !== 48000) console.warn(`siday: the audio runs at ${sampleRate} Hz, not 48000; tunes will play at the wrong pitch`);
  }

  /// Copies bytes into the module's memory, calls `use(pointer, length)` and frees them again.
  withBytes(buffer, use) {
    const bytes = new Uint8Array(buffer);
    const pointer = this.core.siday_alloc(bytes.length);
    new Uint8Array(this.core.memory.buffer, pointer, bytes.length).set(bytes);
    const result = use(pointer, bytes.length);
    this.core.siday_free(pointer);
    return result;
  }

  /// The text the module last had to say, which is UTF-8. (A worklet has no TextDecoder.)
  text() {
    const bytes = new Uint8Array(this.core.memory.buffer, this.core.siday_text(), this.core.siday_text_length());
    let text = "";
    for (let index = 0; index < bytes.length; ) {
      let code = bytes[index++];
      const more = code >= 0xf0 ? 3 : code >= 0xe0 ? 2 : code >= 0xc0 ? 1 : 0;
      if (more > 0) code &= 0x3f >> more;
      for (let count = 0; count < more && index < bytes.length; count++) code = (code << 6) | (bytes[index++] & 0x3f);
      text += String.fromCodePoint(code);
    }
    return text;
  }

  receive(message) {
    const core = this.core;
    switch (message.type) {
      case "load": {
        this.serial = message.serial;
        const plays = this.withBytes(message.name, (name, nameLength) =>
          this.withBytes(message.bytes, (data, length) => core.siday_load(data, length, name, nameLength)),
        ) === 1;
        if (plays && message.subsong >= 0) core.siday_select(message.subsong);
        this.playing = plays;
        this.quanta = 0;
        this.peak = 0;
        this.port.postMessage({
          type: "loaded", serial: this.serial, plays, text: this.text(),
          songs: core.siday_subsongs(), song: core.siday_subsong(), length: core.siday_length(),
        });
        break;
      }
      case "television":
        core.siday_set_television(message.set);
        break;
      case "songlengths":
        this.withBytes(message.bytes, (data, length) => core.siday_set_songlengths(data, length));
        break;
    }
  }

  process(inputs, outputs) {
    const left = outputs[0][0], right = outputs[0][1] ?? outputs[0][0];
    if (!this.playing) return true;
    const core = this.core;
    for (let offset = 0; offset + 128 <= left.length; offset += 128) {
      const more = core.siday_pull();
      // The memory can have grown, and moved, since the last time: the view is made afresh.
      const samples = new Float32Array(core.memory.buffer, core.siday_output(), 256);
      for (let frame = 0; frame < 128; frame++) {
        const l = samples[frame * 2], r = samples[frame * 2 + 1];
        left[offset + frame] = l;
        right[offset + frame] = r;
        const size = Math.max(Math.abs(l), Math.abs(r));
        if (size > this.peak) this.peak = size;
      }
      if (!more) {
        this.playing = false;
        this.port.postMessage({ type: "ended", serial: this.serial });
        return true;
      }
      // About fifteen times a second.
      if (++this.quanta % 24 === 0) {
        this.port.postMessage({ type: "progress", serial: this.serial, position: core.siday_position(), level: this.peak });
        this.peak = 0;
      }
    }
    return true;
  }
}

registerProcessor("siday", SidayProcessor);
