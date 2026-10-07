<img src="logo.png" alt="The siday logo: a chip marked SIDAY, with a stave of music" width="180" align="right">

# siday

A chiptune player written entirely in Swift, in two forms: **a page that plays in your browser**, and
a command-line player for macOS. Both are the same emulators underneath: of the sound chips of the
ZX Spectrum, the Amstrad CPC and the Commodore 64.

The name is the two families of sound chip it plays, SID and AY. How to pronounce it is left open.

**In a browser:** open **[ptsochantaris.github.io/siday](https://ptsochantaris.github.io/siday/)** and
drop tunes or a whole folder on the page. Nothing is uploaded: they are played where they are. See
[In a browser](#in-a-browser).

**On the command line:** point it at files or folders. See [On the command line](#on-the-command-line).

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

## In a browser

[ptsochantaris.github.io/siday](https://ptsochantaris.github.io/siday/) is the player as a web page,
and `Web/` is where it comes from. It is Swift too: the emulators and the page itself are compiled
to WebAssembly.

- Drop tunes or a whole folder on it, or choose them, and it plays them. Nothing is uploaded: the
  files are read where they are and never leave your computer.
- A tune with several songs lists them, by name where the file names them, and plays them in turn.
- A spectrum analyser follows what is being heard.
- Press anywhere on the time bar to move there, in either direction.
- SID tunes know their lengths: those of the High Voltage SID Collection are built in.
- The list shows every tune that was added, however many, and can be searched.
- It has a volume of its own, apart from the computer's, which it remembers.
- One list chooses what a tune is heard through: mono, the AY chip's channels spread in stereo, or
  the speaker of an early-1980s television. It is remembered too.
- The keys are the command-line player's.

Press anywhere on the time bar to move to that place in the song; the pointer shows the time it is
over. A song is rendered to its end as soon as it starts, far faster than it plays, and the bar
shades in behind as it goes: anywhere in the shaded part is reached at once, and a place beyond it
as soon as the rendering gets there.

The spectrum analyser is held back by as long as the browser says the sound takes to be heard, which
with wireless headphones is a sixth of a second or more. When the sound is sent somewhere else while
the page is open, headphones put on or taken off, the page makes its audio output afresh and carries
on from where it was. Adding `?timing` to the page's address shows what the browser is reporting.

Rendering ahead also finds the length of a tune whose file does not give one. Such a tune is allowed
three minutes; if it turns out to end sooner, the page shows its real length as soon as it is known,
and does not sit through the seconds of silence it takes to be sure a tune is over.

To run it from here:

```
./Web/serve.sh
```

That builds what needs building, serves the folder at http://localhost:8000 (to this Mac only) and
opens the page; Ctrl-C stops it. `./Web/build.sh` builds without serving. `./Web/publish.sh` builds
and puts the result on the web: it pushes the site, and nothing else, to the repository's `gh-pages`
branch, which GitHub Pages serves. The page on the web changes when that is run, and not before.

The folder is the whole site, static files and nothing more: an HTML page, a stylesheet, three short
JavaScript files, and what `build.sh` puts in `Web/generated`. Any web server can serve it (a browser
will not load it straight from disk). After a rebuild, reload the page.

Building it needs Swift 6.4 and the matching Embedded Swift SDK for WebAssembly (`swift sdk list` shows
what is installed), and nothing else: no Node, no packages to install. If Binaryen's `wasm-opt` happens
to be installed, the page's module comes out about a third smaller.

The modules are built to use WebAssembly's SIMD instructions (`-msimd128` in `Web/toolset.json`), which
makes rendering a quarter to a third faster and changes no sample of it. Every current browser has
them; Safari has since 16.4.

The page is two WebAssembly modules. `SidayWebAudio` is SidayKit and nothing else. It runs in a
worker (`engine.js`), which renders the whole of a song and keeps it (23 MB for each minute, for the
song that is playing), and the audio thread (`worklet.js`) only plays what it is sent, a fifth of a
second ahead: much the arrangement of the command-line player, so neither loading a tune nor anything
the page does can hold the sound up. What is kept is the sound as the chip made it; the television and
the spectrum analyser are applied as it is played, so a television can be put in the way or taken out at
any moment. Mono and stereo are what the chip makes, so a change between them renders the song again,
which takes a moment, and it goes on from where it was. `SidayWeb` is the page itself, written in
[ElementaryUI](https://elementary.codes). Between them is `siday.js`, for what only a browser has: the
chosen files and the audio graph. All told it is about 1.3 MB compressed, the song lengths of the High Voltage SID Collection being some 550 kB of that.

With these in the package, a plain `swift build` with no `--product` also compiles the web targets and
what they depend on for the Mac, which takes minutes the first time and is of no use.

## On the command line

`siday` is the player for the terminal, on macOS. To build it:

```
swift build -c release --product siday
```

The binary is `.build/out/Products/Release/siday` (`swift build -c release --show-bin-path` prints the folder).
Always use a release build: the emulators are far too slow in debug.

### Using it

```
siday <files or folders…>
```

Folders are searched recursively and files are recognised by extension. The files are only ever read.

While playing: `space` pause · `n` or `→` next · `p` or `←` previous · `+` / `-` (or `↑` / `↓`) subsong ·
`q` quit.

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
| `--output mono\|abc\|acb\|plastic\|wood` | What the tune is heard through. Mono by default, because many AY tunes layer the chip's three channels into one sound; `abc` and `acb` spread them left, centre and right (a SID has a single output, so for a SID tune these are mono); `plastic` and `wood` are the speaker of an early-1980s television (see below), which is mono too |
| `--sid-model auto\|6581\|8580` | SID model (default: what the tune asks for) |
| `--sid-engine residfp\|resid` | SID emulation. reSIDfp by default; reSID 1.0 is lighter, and its 6581 filter is drier |
| `--sid-filter-curve 0…1` | Where the 6581's filter sits, bright to dark (default 0.5). Real chips varied this much; reSIDfp only |
| `--songlengths path` | A copy of HVSC's `Songlengths.md5` to ask before the lengths that are built in; remembered for later runs. A file with no lengths in it is ignored |
| `--wav folder` | Render to WAV files instead of playing (existing files are not overwritten) |
| `--list` | Show what would be played, with format, length and title |
| `--check` | Load and render a few seconds of every file silently and report per format |
| `--bench` | Render at full speed and report the multiple of real time |

### How long a tune plays

- Tracker modules and register recordings play to their loop point (`--loops` times).
- AY files carry a length per song. Many give none, or the exactly three minutes that rips use as a
  stand-in; those songs are run silently for up to six minutes to find where they end or begin to repeat.
  If that finds neither, they get `--default-time`.
- SID tunes use the song lengths of the High Voltage SID Collection (HVSC). A SID file does not say how
  long its songs are, and most never end; the collection's team have timed every one. Their lengths
  for release 85, all 61,157 tunes, are built into the player, in the command line and the browser
  alike, and a tune is found among them by its content. A copy of the collection's own
  `Songlengths.md5` is asked first when there is one: named with `--songlengths` (once is enough), in
  `$SIDAY_SONGLENGTHS`, or found in a `DOCUMENTS` folder above the tune. That is the way to use a
  newer release's lengths, and it also finds a tune by its path inside HVSC when its content differs.
  A SID tune in neither gets `--default-time`.
- When a new release comes out, `swift Scripts/pack-songlengths.swift <its Songlengths.md5> <its
  number>` rebuilds the table in `Sources/SidayKit/SIDFile/SongLengthsData.swift`, and
  `SIDAY_SONGLENGTHS=<that file> swift test` checks every entry of it against the file.
- Only a tune that is still playing at that point is faded out, since it would go on repeating. One
  that has come to rest there has an ending of its own and simply stops. An AY file that asks for a
  particular fade gets that one.
- Any tune that falls silent for five seconds ends early.
- Multi-song AY and SID files play the song the file names as its first; `+` and `-` move between songs.

### Through a television

These chips were written for and heard through a television: one small paper cone in a vented plastic
or wooden cabinet, fed by a sound stage with little treble to give. `--output plastic` and `--output wood` put that
between the chip and your speakers; in the browser the same two are in the list of outputs, and can
be switched while a tune plays, so the sound with and without can be compared. A television has one
loudspeaker, which is why it is a choice alongside mono and stereo and not on top of them.

| Stage | What it does |
|---|---|
| One speaker | The two channels are added together |
| Sound channel | Treble falls away gently from about 4.5 kHz |
| Amplifier and cone | Loud passages are bent slightly, adding a little second and third harmonic |
| Speaker | No bass below its own resonance (about 170 Hz in `plastic`, 90 Hz in `wood`), little above 6 to 7 kHz |
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

What it is made from:

- [Ay_Emul](http://ay.strangled.net/) by Sergey Bulba: the tracker players, the VTX and YM handling
  and the rules of the AY file machine are ported from its source. The `.ay` format is as he and
  Patrik Rak describe it.
- [libsidplayfp](https://github.com/libsidplayfp/libsidplayfp) and its reSIDfp, by Leandro Nini, Antti
  Lankila, Simon White and Dag Lem: the SID chip, and the way a C64 is started for a tune.
- [reSID](https://github.com/libsidplayfp/resid) by Dag Lem: the other SID chip (`--sid-engine resid`).
- [ayumi](https://github.com/true-grue/ayumi) by Peter Sovietov: the AY and YM chip.
- [z80](https://github.com/superzazu/z80) by superzazu: the Z80's cycle counts.
- ar002 by Haruhiko Okumura: the unpacking of LH5, which VTX and YM files are packed with.
- The [High Voltage SID Collection](https://www.hvsc.c64.org/): the length of every song of every SID
  tune, which its team have timed and which are built into the player, and the description of the SID
  file format.

What it was checked against, besides the originals of the above:

- [ayfly](https://github.com/l29ah/ayfly) and [ay_emul_c11](https://github.com/pdxiv/ay_emul_c11), for
  the tracker players.
- [z80ex](https://github.com/lipro/z80ex), and the
  [ZEXDOC and ZEXALL](https://mdfs.net/Software/Z80/Exerciser/) instruction exercisers by Frank
  Cringle, for the Z80 and the AY file machine.
- [SingleStepTests/65x02](https://github.com/SingleStepTests/65x02), for the 6510.

What it is built with: [swift-argument-parser](https://github.com/apple/swift-argument-parser) for the
command line, and [ElementaryUI](https://elementary.codes) and
[JavaScriptKit](https://github.com/swiftwasm/JavaScriptKit) for the page in the browser.
