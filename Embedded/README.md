# SidayKit as Embedded Swift

An experiment: the emulation library built with Embedded Swift, which has no Foundation and next to no
runtime, for this Mac and for WebAssembly. The player itself (Core Audio, the terminal, the option
parser) cannot be built this way; what is built here is the library and a small program that renders a
tune to a file.

```
./build.sh
build/sidayemb <tune> <seconds> <out.f32> [residfp|resid] [plastic|wood]
node run.mjs <folder> /t/<tune in that folder> <seconds> /t/out.f32 [residfp|resid] [plastic|wood]
```

The output is raw interleaved stereo Float32 at 48 kHz. Each run prints the speed and a hash of the
samples; the hash is the same for the normal build, the embedded one and the WebAssembly one.

`run.mjs` gives the WebAssembly module one folder, as `/t`, and that folder is writable to it: give it
a copy of the tunes, not the collection.

It needs the Swift 6.4 toolchain from swiftly and the WebAssembly SDK of the same version (for its C
library). `TOOLCHAIN` and `WASM_SDK` override where they are looked for.

## What it takes

Nothing but the library's own sources and `Files.swift`, which reads and writes files through the C
library for the render programs. SidayKit uses no Foundation, and keeps clear of what Embedded Swift
cannot do: key paths, and making a generic player from a source whose type is only known at run time
(`TuneLoader.trackerPlayer` builds each one outright).

The library target also builds as it stands with SwiftPM and either WebAssembly SDK:

```
swift build --swift-sdk swift-6.4.0-RELEASE_wasm-embedded --target SidayKit
```
