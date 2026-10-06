# siday

A command-line chiptune player for macOS, written entirely in Swift. Point it at files or folders
and it plays them.

The name is the two families of sound chip it plays, SID and AY. How to pronounce it is left open.

```
siday ~/Music/chiptunes --shuffle
```

## What it plays

| Family | Formats |
|---|---|
| AY-3-8910 / YM2149 tracker modules | PT3, PT2, PT1, STC, STP, ASC, PSC, SQT, FTC, FXM, PSM, GTR, and TurboSound pairs |
| AY register recordings | VTX, YM (YM2, YM3, YM3b, YM5, YM6) |
| ZX Spectrum and Amstrad CPC program rips | AY (ZXAYEMUL), including beeper music |
| C64 | SID (PSID and RSID) |

Not supported: RSID tunes that need the C64 BASIC ROM, Compute!'s Sidplayer (MUS) data, and the
Atari-ST-only effects in some YM5/YM6 files (digidrums, SID voice), which play without those effects.
A few RSID tunes that depend on exact video or serial-port timing will not play correctly.

## Building

```
swift build -c release --product siday
```

The binary is `.build/out/Products/Release/siday` (`swift build -c release --show-bin-path` prints the folder).
Always use a release build: the emulators are far too slow in debug.

## Using it

```
siday <files or folders…>
```

Folders are searched recursively and files are recognised by extension. The files are only ever read.

While playing: `space` pause · `n` or `→` next · `p` or `←` previous · `+` / `-` (or `↑` / `↓`) subsong ·
`t` television (off, plastic, wood) · `q` quit.

| Option | Effect |
|---|---|
| `--shuffle` | Random order |
| `--formats pt3,sid` | Only these formats |
| `--match text` | Only paths containing the text |
| `--loops n` | Passes through a looping tune before it fades (default 1) |
| `--fade seconds` | Fade-out for a tune that is still playing where it ends (default 20, and never longer than the tune itself) |
| `--default-time m:ss` | Time given to tunes whose length is unknown (default 3:00) |
| `--max-time m:ss` | Cap on any tune |
| `--subsong n` / `--all-subsongs` | Start at song n / play every song of multi-song files |
| `--chip ay\|ym`, `--clock Hz`, `--frame-rate Hz` | AY settings. Defaults: what the file says, otherwise an AY at 1773400 Hz and 50 Hz |
| `--stereo mono\|abc\|acb` | AY channel layout. Mono by default, because many tunes layer the three channels into one sound; `abc` and `acb` spread them left, centre and right |
| `--sid-model auto\|6581\|8580` | SID model (default: what the tune asks for) |
| `--sid-engine residfp\|resid` | SID emulation. reSIDfp by default; reSID 1.0 is lighter, and its 6581 filter is drier |
| `--sid-filter-curve 0…1` | Where the 6581's filter sits, bright to dark (default 0.5). Real chips varied this much; reSIDfp only |
| `--tv plastic\|wood` | Play through an early-1980s television's speaker (see below). Always mono |
| `--songlengths path` | HVSC's `Songlengths.md5`; remembered for later runs. A file with no lengths in it is ignored |
| `--wav folder` | Render to WAV files instead of playing (existing files are not overwritten) |
| `--list` | Show what would be played, with format, length and title |
| `--check` | Load and render a few seconds of every file silently and report per format |
| `--bench` | Render at full speed and report the multiple of real time |

### How long a tune plays

- Tracker modules and register recordings play to their loop point (`--loops` times).
- AY files carry a length per song. Many give none, or the exactly three minutes that rips use as a
  stand-in; those songs are run silently for up to six minutes to find where they end or begin to repeat.
  If that finds neither, they get `--default-time`.
- SID tunes use HVSC's song-length database when one is available: named with `--songlengths` (once is
  enough), in `$SIDAY_SONGLENGTHS`, or found in a `DOCUMENTS` folder above the tune. A tune is looked up
  by content, then by its path inside HVSC. Otherwise it gets `--default-time`.
- Only a tune that is still playing at that point is faded out, since it would go on repeating. One
  that has come to rest there has an ending of its own and simply stops. An AY file that asks for a
  particular fade gets that one.
- Any tune that falls silent for five seconds ends early.
- Multi-song AY and SID files play the song the file names as its first; `+` and `-` move between songs.

### Through a television

These chips were written for and heard through a television: one small paper cone in a vented plastic
or wooden cabinet, fed by a sound stage with little treble to give. `--tv` puts that between the chip
and your speakers, and `t` switches it while a tune plays, so the two can be compared.

| Stage | What it does |
|---|---|
| One speaker | The two channels are added together |
| Sound channel | Treble falls away gently from about 4.5 kHz |
| Amplifier and cone | Loud passages are bent slightly, adding a little second and third harmonic |
| Speaker | No bass below its own resonance (about 170 Hz in `plastic`, 105 Hz in `wood`), little above 6 to 7 kHz |
| Cabinet | A few resonances and a dip in between: the boxy low-middle and the forward upper-middle of a small set |

`plastic` is a small portable, thin and forward. `wood` is a large set in a veneered cabinet, fuller and
rounder. The level in the middle of the range is kept where it was. No particular set was measured: the
figures are typical ones, chosen to be judged by ear, and are all in one place
(`Sources/SidayKit/Core/Television.swift`).

### AY files ripped at the wrong speed

An AY file can only ask for its music routine once per 1/50 s. A few games drove their music from a
free-running loop instead, and their rips approximate that rate, not always well. Files known to be off
are corrected by content (`Sources/SidayKit/AYFile/AYFileCorrections.swift`) and show "timing corrected"
when they play; so far those are the Exolon 128K title tune, which the rip plays 14% fast, and the Kenny
Dalglish Soccer Match menu tune, which it plays 5% slow. Giving
`--frame-rate` plays any file exactly as written.

## In a browser

`Web/` is the same player as a web page: drop tunes or a folder on it and it plays them, with the same
keys. Nothing is uploaded; the files are read where they are.

```
./Web/serve.sh
```

That builds what needs building, serves the folder at http://localhost:8000 (to this Mac only) and
opens the page; Ctrl-C stops it. `./Web/build.sh` builds without serving.

The folder is the whole site, static files and nothing more: an HTML page, a stylesheet, two short
JavaScript files, and what `build.sh` puts in `Web/generated`. Any web server can serve it (a browser
will not load it straight from disk). After a rebuild, reload the page.

Building it needs Swift 6.4 and the matching Embedded Swift SDK for WebAssembly (`swift sdk list` shows
what is installed), and nothing else: no Node, no packages to install. If Binaryen's `wasm-opt` happens
to be installed, the page's module comes out about a third smaller.

The page is two WebAssembly modules. `SidayWebAudio` is SidayKit and nothing else, running in an audio
worklet (`worklet.js`) so the sound does not depend on what the page is doing. `SidayWeb` is the page
itself, written in [ElementaryUI](https://elementary.codes). Between them is `siday.js`, for what only
a browser has: the chosen files and the audio graph. All told it is about 700 kB compressed.

With these in the package, a plain `swift build` with no `--product` also compiles the web targets and
what they depend on for the Mac, which takes minutes the first time and is of no use.

## How it is built

`Sources/SidayKit` holds all emulation. It has no dependencies and uses none of Foundation: it is
given a file's bytes and gives back samples, so it builds wherever Swift does, WebAssembly and Embedded
Swift included (see `Embedded/`). `Sources/siday` is the player for macOS: reading files, Core Audio
output, terminal keys and options (via swift-argument-parser).

| Part | Based on | Checked against |
|---|---|---|
| AY/YM chip | ayumi by Peter Sovietov (MIT) | C ayumi, sample for sample |
| Tracker players, VTX, YM | Ay_Emul by Sergey V. Bulba (`Players.pas`; free use with attribution) | ayfly's players (ay_emul_c11 for FTC, FXM, PSM, GTR), register frame by frame, over a whole collection |
| LH5 unpacking | ar002 by Haruhiko Okumura (public domain) | — |
| Z80 CPU | written for this project, after superzazu/z80 (MIT) | ZEXDOC and ZEXALL; cycle totals against the C core |
| AY file machine | Ay_Emul's port and interrupt rules; Patrik Rak's format | a z80ex-based reference, every port write and its T-state |
| 6510 CPU | written for this project | SingleStepTests/65x02: every opcode, every bus cycle |
| C64 environment | HVSC's SID file format document; driver and start-up state from libsidplayfp (GPL) | libsidplayfp's SID register writes |
| SID chip | reSIDfp from libsidplayfp 2.16.1 (GPL) | C++ reSIDfp on the same register traces, bit for bit |
| SID chip, `--sid-engine resid` | reSID 1.0 by Dag Lem (GPL) | C++ reSID on the same register traces, bit for bit |

Where a reference player and Ay_Emul's source disagreed, the source was followed. Three deliberate
departures from Ay_Emul are marked in the code: old-format PSC modules start with version-correct sample
and ornament tables; an AY file only counts as Amstrad CPC once it writes a register through the CPC's
ports; and the AY player stub is placed after the file's memory blocks rather than before.


Tracker players keep the field names and control flow of the Pascal they came from, so the two can be
read side by side. Tracker modules are loaded into a 64 KB wrap-around memory and all file parsing is
bounds-checked, so a corrupt file plays wrongly or is skipped but does not crash the player.

## Licence and credits

GNU General Public License, version 2 or (at your option) any later version; see `LICENSE`.

This project stands on other people's work, most of all Sergey Bulba's Ay_Emul, Dag Lem's reSID,
libsidplayfp and its reSIDfp (Leandro Nini, Antti Lankila, Simon White, Dag Lem) and Peter Sovietov's ayumi.
`THIRD-PARTY.md` lists what came from where and under which terms.
