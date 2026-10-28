# Developing siday

How siday is put together, how to build and test it, and how each part was checked. For what siday
plays and how to use it, see the [README](README.md); for each format's story, see
[FORMATS.md](FORMATS.md). This file's [format notes](#format-notes) hold the implementation detail
behind each of those stories: what each player is ported from, what it was compared with, and the
results.

## Layout

The repository is three Swift packages and an app.

- **SidayKit** (at the top) holds all the emulation. It has no dependencies and uses none of
  Foundation: it is given a file's bytes and gives back samples. It builds wherever Swift does,
  WebAssembly and Embedded Swift included, so another package can depend on this repository for it
  alone. It is built as modules, compiled side by side:
  - `Sources/SidayFoundation`: what every player is made with;
  - `SidayChips` and `SidayM68000`: the chips and the processor that several families share;
  - a module for each family of players: `SidayAmigaTrackers`, `SidayAmigaComposers`,
    `SidayAmigaMachine`, `SidayTrackers`, `SidayC64`, `SidayEightBit` and `SidayAtari`;
  - `SidayCodecs`: the decoders of recordings (Ogg Vorbis, MP3, WAV) and the player that plays them;
  - `Sources/SidayKit`: the loader, which brings the rest with it.
- **SidayPlayer** (`Sources/SidayPlayer`, also at the top, also Foundation-free) is what lies between
  a tune and a listener, the same for every front end: how long a song plays and how it ends, the
  settings, the levelling, the television and the analyser, a song kept whole to move about in, which
  tune plays after which, the order of the tunes in a folder or a playlist, and the pictures to
  listen by. It is the library the front ends import, and it brings SidayKit with it.
- **SidayFiles** (`Sources/SidayFiles`) is what the command-line player and the app share for reading
  tunes from disk, with Foundation: finding the tunes in folders and playlists, the files they need
  alongside them, and HVSC's song lengths.
- **`CLI/`** is the command-line player for macOS, a package of its own: Core Audio output, terminal
  keys and options (via swift-argument-parser).
- **`Web/`** is the web player, a package of its own built on SidayPlayer: see
  [The web player](#the-web-player).
- **`App/`** is the app for macOS and iOS: an Xcode project on SidayPlayer and SidayFiles, written in
  SwiftUI. Its Quick Look extension (`App/SidayQuickLook`) previews every kind of tune the app declares
  but the recordings, which the system previews itself. It shares the app's sound ring, lamps, scopes
  and display, but not its engine: that renders each song whole and keeps it (23 MB a minute), where
  the preview's makes the song a sixth of a second ahead of what is heard, and only while it plays.
  The Finder keeps the previews either side of the one on show and tells them nothing as you move,
  so a preview there watches its window's level to know whether it is on show. Its Info.plist is
  written by the same test as the app's.
  A tune's picture is the chip it is heard as made by (`TuneInfo.chips`, set by a player that knows,
  such as S3M's card or a VGM's chips, and otherwise `TuneFormat.likelyChip`), drawn in code by
  `App/Siday/Views/ChipCard.swift`, which the extension shares.

## Building and testing

- `swift test` at the top tests SidayKit, SidayPlayer and SidayFiles.
- `swift test --package-path CLI` tests the command-line player.
- The app's scheme in Xcode tests its accessibility in every part of it.
- `swift build -c release --package-path CLI` builds the command-line player. Always use a release
  build for listening or measuring: the emulators are far too slow in debug.

Some files are generated, and are committed with what they are made from:

- **The app's document types.** The list of kinds of file the app opens is written from SidayKit's by
  a test: `SIDAY_WRITE_APP_TYPES=1 swift test --filter appOpensEveryKindOfFile`.
- **The format stories.** `swift Scripts/pack-formats.swift` puts FORMATS.md into the command-line
  player (`CLI/Sources/siday/FormatStories.swift`), for `--about` and the `i` key. Run it after every
  change to FORMATS.md; a test checks that the two agree. Another test checks that every format has a
  chapter, found by the first word of its `## ` heading.
- **HVSC's song lengths.** When a new HVSC release comes out,
  `swift Scripts/pack-songlengths.swift <its Songlengths.md5> <its number>` rebuilds the table in
  `Sources/SidayC64/SIDFile/SongLengthsData.swift`, and
  `SIDAY_SONGLENGTHS=<that file> swift test` checks every entry of it against the file.

Some data lives in a single place, to be tuned there:

- The television's figures (see the README's
  [Through a television](README.md#through-a-television)) are all in
  `Sources/SidayPlayer/Player/Television.swift`.
- AY files ripped at the wrong speed are corrected by content in
  `Sources/SidayEightBit/AYFile/AYFileCorrections.swift`.

## The web player

[ptsochantaris.github.io/siday](https://ptsochantaris.github.io/siday/) comes from `Web/`. To run it
from here:

```
./Web/serve.sh
```

That builds what needs building, serves the folder at http://localhost:8000 (to this Mac only) and
opens the page. `./Web/build.sh` builds without serving. `./Web/publish.sh` builds, and pushes the
site and nothing else to the repository's `gh-pages` branch, which GitHub Pages serves.

Building it needs Swift 6.4 and the matching Embedded Swift SDK for WebAssembly (`swift sdk list`
shows what is installed), and nothing else: no Node, no packages to install. If Binaryen's
`wasm-opt` is installed, both modules go through it and come out smaller. The folder is the whole
site: static files that any web server can serve.

The page is two WebAssembly modules, about 1.5 MB compressed:

- **`SidayWebAudio`** is SidayPlayer and nothing else. It runs in a worker, which renders the whole of
  a song and keeps it. The audio thread only plays what it is sent, so nothing the page does can hold
  the sound up.
- **`SidayWeb`** is the page itself, written in [ElementaryUI](https://elementary.codes).

Between them is `siday.js`, for what only a browser has: the chosen files and the audio graph.

## Muting

Each player mutes for itself, since a voice is a different thing in each (see the README's
[Muting a voice](README.md#muting-a-voice) for what a listener hears). With no voice muted, the sound
is, to the byte, what it was before any player could mute: that was checked on some two thousand real
files, of every format, when muting was written.

- **In the browser**, a song is rendered to its end as soon as it starts, so a mute means rendering
  the song again from its beginning without the muted voices. What was being heard goes on until the
  new rendering has caught up with the listener, then gives way to it. The song without some of its
  voices is played to exactly the end the whole song came to, fade and all: left to judge by its own
  sound, as a song usually is, it might be taken to have fallen silent and be cut short.
- **On the command line**, which renders as it plays, the song is played a second time alongside:
  another player of the same file starts from the beginning with the voices left out, silently and
  as fast as it can go, while the song plays on whole. When it has caught up, it is heard in its
  place; from then on, voices are muted and brought back at once. The song is still judged by the
  first player, whole, so it comes to the same end. Muting a voice for the first time costs a moment,
  as in the browser; the second player is let go when every voice is back.

## How each part was checked

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
| 68000 CPU | written for this project, from Motorola's manual | AtariAudio's (Musashi), through the tunes below |
| Atari ST machine, its sound chip, timers and STE samples | AtariAudio by Arnaud Carré (MIT); the chip's mixing table measured by Paulo Simões | AtariAudio itself, sample for sample: three minutes of each of 5,897 tunes, and every song of those with several |
| Atari ST YM files, their effects, digi-mixes and YM tracker tunes | AtariAudio | AtariAudio, sample for sample, on the 23 files in the collection; no YM2 or YMT2 file among them |
| Ice unpacking | the C version by Hans Wessels (public domain) | — |
| Sierra AGI sounds on the Amiga | Sierra's two routines, read in Wanted Team's player of the sounds for EaglePlayer | that player itself, run by UADE: all 745 files of UnExoticA's collection, each routine, by stereo loudness envelope |
| Sierra AGI sounds on the PC | the chip's writes, as NewRisingSun's recordings of King's Quest II show them | those recordings, on the same chip: the chip was told the same in 9 of the 13, and in the rest except where a recording leaves out writes |
| Modules packed by games' packers | ProWizard by Sylvain Chipaux, as libxmp keeps it (MIT); where ProWizard does not unpack a file, or unpacks it wrongly, UADE's converter, Deli-Wizard, read in its 68000 code | libxmp's ProWizard itself, byte for byte: all 787 packed files of UnExoticA's collection that it unpacks, and some 28,000 copies of them cut short or changed; UADE, by stereo loudness envelope, on those it does not |
| AMOS music banks | UADE's player of them (GPL), which converts them to a module | that player, run by UADE: the first 40 seconds of eight banks of seven games, by stereo loudness envelope |
| ChipTracker modules | ChipTracker's own replayer, read in Wanted Team's player for EaglePlayer | that player, run by UADE: the first minute of all 41 files of UnExoticA's collection, by stereo loudness envelope |
| TFMX modules | libtfmxaudiodecoder by Michael Schwendt (GPL), made to play as Chris Hülsbeck's players do where it does not: their 68000 code read in Wanted Team's players for EaglePlayer, and the player chosen as UADE chooses it | those players, run by UADE: the periods and volumes written, tick for tick, over the first 40 seconds of all 322 modules of UnExoticA's collection (315 the same throughout), and the stereo loudness envelope over the first minute; libtfmxaudiodecoder itself, tick by tick, with siday's changes set aside |
| Jochen Hippel's TFMX and Future Composer | libtfmxaudiodecoder by Michael Schwendt (GPL); TFMX 7V's mixing from Hippel's own player, read in Wanted Team's player for EaglePlayer | libtfmxaudiodecoder itself, tick by tick: every song of all 230 files of UnExoticA's collection, and some 239,000 copies of them cut short or changed; UADE: the first minute of the 190 it plays, by stereo loudness envelope |
| Magnetic Fields Packer songs | libxmp's reading (MIT), except for its table of patterns, which is read as the format's replayer reads it | that replayer, in Wanted Team's player for EaglePlayer, run by UADE: the first 40 seconds of all 37 songs of UnExoticA's collection, by stereo loudness envelope |
| Amiga trackers with players of their own: PumaTracker, Pierre Adane's packer, Game Music Creator, Images Music System, SoundMon, SidMon, Digital Mugician, Delta Music, Sonic Arranger | each format's own player, read in its 68000 code as UADE carries it (or, for formats whose files carry it, in the files) | that player, run by UADE: what it tells the sound chip, tick for tick, on every file of UnExoticA's collection |
| MaxTrax scores | the MaxTrax Music Driver's released source (LGPL), ported | ScummVM's player of it, with its departures from the driver put back: 282 of 283 songs tick for tick |
| David Whittaker's, Ben Daglish's, Martin Walker's, Special FX's and the Maniacs of Noise's drivers | the drivers themselves, run on an emulated Amiga (siday's 68000, chip memory, Paula heard as she is written, the CIAs and the beam), found and patched as the players of them for EaglePlayer that UADE carries do, read in their 68000 code | those players, run by UADE: what the driver tells the sound chip, tick for tick, over the first 40 seconds of every song of UnExoticA's collection (551 of Whittaker's, 129 of Daglish's 135, 106 of Walker's, the 355 of Special FX's that are heard, 87 of the Maniacs of Noise's) |
| 28 more composers' drivers (see [CORE](#format-notes)) | the drivers themselves, on the same emulated Amiga, found, patched and called as the players of them for EaglePlayer do (most of them Wanted Team's; UADE's own for Fred Monitor and Darius Zendeh), read in their 68000 source or, where there is none, their code | those players, run by UADE: what the driver tells the sound chip, tick for tick, over the first 40 seconds of every song of UnExoticA's collection (1,128 songs of 266 files): the same in nearly every song, and where not, only as far as the two Amigas' timing and their sound chips differ by a few clocks |
| DeliTracker's custom modules, Dave Lowe's earlier music | the modules themselves, hosted on the emulated Amiga, with its interrupts, timers and sound chip as the hardware has them, as UADE's host for the players (`score`) hosts them, read in its 68000 source; for Electronic Arts' own, an exec, timer.device and audio.device of siday's, from the Autodocs and Kickstart 1.3 measured; Dave Lowe's loaded and called as Wanted Team's player of them does | UADE: what the module tells the sound chip, tick for tick, over the first 40 seconds of 2,381 of the 2,539 songs of UnExoticA's 416 modules; the rest are the same except where the processor and the chip race. Electronic Arts' 15, on exec's own system: Copperline on Kickstart 1.3, the same notes in all 48 songs over 60 seconds |
| Richard Joseph's modules, Dave Lowe's later music | each composer's own player, read in its 68000 code in Wanted Team's player for EaglePlayer | that player, run by UADE: what it tells the sound chip, tick for tick, over the first 40 seconds of every song of UnExoticA's collection (917 of Richard Joseph's, the 108 of Dave Lowe's that make a sound) |
| Sonix Music Driver scores | Mark Riley's three players, read in their 68000 code in Wanted Team's player for EaglePlayer | that player, run by UADE: what it tells the sound chip, tick for tick, over the first 40 seconds of all 237 scores of UnExoticA's collection |
| Epic MegaGames' MASI files and Symphonie modules | OpenMPT's readings of them (BSD) | libopenmpt |
| 8-bit Atari machine, its 6502 and its POKEY | ASAP by Piotr Fusik (GPL) | ASAP's `asapconv` itself, sample for sample: the first 30 seconds of every song of the 6,337 files of ASMA, 8,349 of them, and three minutes of 286 songs of 200 of the files |

A **stereo loudness envelope** comparison measures how loud each side is from moment to moment in two
renderings, and how alike the two are; "tick for tick" means the register writes to the sound chip
compared tick by tick.

## Format notes

Under the same headings as FORMATS.md, the detail behind each chapter.

### Loudness and companion files (all formats)

- **Format levels.** At first each format's level was set by plain signal power: the median of a run
  of each kind of file was brought to one level. Since October 2026 it is set by BS.1770 loudness
  (LUFS). The new measure put the tunes of the listening tests in the order they were heard in more
  often: 23 of 25 times, where plain power had 18. For it, MED, CMF, AY and AHX files were turned
  down by 1.2 to 2 dB, and C67 up by 1.1 dB; ModPlug Tracker's and OpenMPT's ways of adding up their
  channels are told in their own chapters.
- **Per-tune levelling** measures each song whole, as played, and brings it to -22.95 LUFS (or
  halfway), boosting by at most 6 dB and keeping peaks 1 dB below full scale. Levels are cached, on
  disk or in the browser.
- **Companion files** are all found by `FileFinder`: by the names they are known to have, beside the
  file that wants them first, and case-insensitively, as Windows matches names.

### The Amiga's frames, and what ticks by them (all Amiga formats)

- **Frames.** The emulated Amiga's frames are long ones, of 313 lines of 227 clocks (71,051 clocks,
  49.92 a second), as on an Amiga that has started its Kickstart: Kickstart 1.3's graphics.library
  sets the long-frame bit 2.5 seconds after power-on (a write of VPOSW, seen in Copperline), and only
  an interlaced display toggles it after that. UADE starts no Kickstart and clears the bit at reset
  (`src/custom.c`), so its frames are short ones of 312 lines (50.08 a second).
  `AmigaChips.comparingWithUADE` gives UADE's for a test that compares with it moment for moment; it
  is never set for playing. Tick for tick comparisons with UADE are not affected: what a tick writes
  does not depend on how long the frame is.
- **What ticks by the frame.** A player is run each frame (`TFMXTiming.frame`) where the program it
  came from shows that it was: TFMX songs that set no timer (TFMX Pro's `installtimer`, "vbi is
  active"), Hippel's COSO ("CALL h_replay each vbi"), Alcatraz Packer, Fashion Tracker and Images
  Music System (their replays' own handlers at $6C), The Musical Enlightenment ("a routine to be added
  to your vertical-blank-handler"), Thomas Hermann's effects (the game's), Beathoven Synthesizer
  modules whose own code sets the frame's vector (Final Mission's), and the Dynamic Synthesizer
  (Hollywood Poker Pro's in-game module sets a copper interrupt at each frame's end); MaxTrax already
  was. And the MOD files of the trackers before ProTracker: NoiseTracker (`N.T.`) and His Master's
  Noise (`M&K!`, `FEST`), whose editor's source (NoiseTracker 2.0's, from ftp.untergrund.net's
  hitchhikr/old/tools) runs the music from its vertical-blank handler `L509` and corrects its clock
  for 49.92 frames a second; and fifteen-sample Soundtracker files at tempo 120 (Obarski's replay 1.2
  of 1987 puts `frameirq` at $6C; SoundTracker V1.0's instructions: "once every vertical blanking
  interrupt"). Those at another tempo tick by Ultimate Soundtracker 1.8's timer exactly, (240 − tempo)
  × 122 + 1 counts (Obarski's V27, `init6`, in UADE's `EP_Ultimate_ST.s`). All are cited in the code. The rest, whose original caller is not known (most of the
  composers' drivers and the other ports, which UADE and siday run on DeliTracker's timer of $376B,
  70,940 clocks), are left so, as is anything with a timer of its own.
- **The Amiga is a PAL one.** Where a game's timer was worked out for NTSC and set on any Amiga, it is
  played as a PAL Amiga ran it: Wings (Cinemaware's CIA-B $2E9B, "NTSC 60Hz timer": 59,660 clocks, where
  Wanted Team's player has 59,115) and the Sonix Music Driver's SNX scores (its clock $1B4F4D, "for NTSC
  timer", where Wanted Team's has $376B times 125). Sonic Arranger's timer is the replayer's own $AD303
  ("only PAL clock") over the song's ticks a second, for modules with their own replayer too, which
  UADE runs at fifty. Infogrames' rate stays UADE's $1A00 (106.6 a second), not Andy Silva's DeliTracker
  player's (99.8): Captain Blood's title music, heard against the game, is right at it (the user's ear,
  2026-10-26).
- **TFMX 1.x's mid-song speed** writes only the CIA timer's upper byte, over the $F0 its own
  TIMERINIT set (not DeliTracker's $6B), and a speed without a tempo puts a song that began without a
  timer back on the frame; as the player's source has it. No module of the collection sets a tempo
  mid-song, so none sounds otherwise for it.
- **Not known:** which program wrote the `N.T.` tag (no file of the collection has it; it is played
  on the frame, with F00 as nothing, as NoiseTracker 1.x has it); a Soundtracker module at tempo 120
  made by Ultimate Soundtracker 1.8, which ran at 48.45 ticks a second, cannot be told from an
  earlier one's; and Startrekker's timing, for which there is no source.

### PT3 — the AY trackers, VTX and AY files

Based on:

- Each tracker's player is Sergey Bulba's, from Ay_Emul.
- Where a reference player and Ay_Emul's source disagreed, the source was followed.
- Tracker players keep the field names and control flow of the Pascal they came from, so the two can
  be read side by side.

Decisions. Three deliberate departures from Ay_Emul are marked in the code:

- Old-format PSC modules start with version-correct sample and ornament tables.
- An AY file only counts as Amstrad CPC once it writes a register through the CPC's ports.
- The AY player stub is placed after the file's memory blocks rather than before.

Notes:

- Tracker modules are loaded into a 64 KB wrap-around memory.
- All file parsing is bounds-checked, so a corrupt file plays wrongly or is skipped but does not
  crash the player.

### YM — recordings of two machines' chips

- A YM file recorded on an Atari ST is played by `STYMRenderer`, on the ST's chip and timers.
- YM files with "xx" over the first two bytes of the archive's header (size and checksum) and over
  the packed size: twenty in the test collection.

### SNDH — the Atari ST and STE

- Based on AtariAudio's design. The tune's code is called and runs to its end in no time, once for
  each tick of its player and once for each interrupt of a timer it has set going. The timers are
  moved on a sample of the output at a time.
- The chip's three tied outputs are looked up in a table recorded from the machine, not added up.
- `siday --raw file.raw tune.sndh` writes the plain average instead of the filtered output. That is
  what agrees with AtariAudio to the sample.

### SID — the Commodore 64

- The 6510 was written for this project, and checked on every opcode and every cycle of the bus.
- The start-up state and the driver for PSID files are libsidplayfp's.
- reSIDfp (from libsidplayfp) and reSID 1.0 (Dag Lem's) are both ports. They were checked bit for
  bit against the C++ on the same streams of register writes.
- What the tune's code writes to the chip was checked against what libsidplayfp has it write.
- The song lengths built in are those of the collection's release 85; a newer `Songlengths.md5` can
  be given to be asked first.

### SAP — the 8-bit Ataris

Based on:

- A port of ASAP, Piotr Fusik's Another Slight Atari Player: its POKEY, its 6502, and as much of the
  machine as a tune needs.
- ASAP's 6502 runs an instruction whole and counts its cycles before it. The C64's 6502 in this
  project makes each memory access in a cycle of its own.
- ASAP works out when each POKEY channel's output next changes. It puts each change into the sound
  where it falls between two samples, as a step band-limited by a windowed sinc.
- The four channels are added as the chip's own DAC adds them, a little less than in proportion, as
  Fusik measured on chips that AMI made.

Checked against:

- ASAP itself, its `asapconv` writing the sound at 48,000 samples a second.
- Every song of the 6,337 files of the ASMA collection in the test collection, 8,349 songs, agrees
  with it to the sample over its first 30 seconds.
- The 286 songs of 200 of the files, taken at random, agree over three minutes.
- `siday --raw file.raw tune.sap` writes what that was compared with.

Notes:

- ASAP makes its tunes about 7 dB louder than the others here. They are turned down to match, by the
  median of two hundred of them.
- Level: ASAP's output is about 7 dB louder than the other formats here; siday turns it down to match.

### AGI — Sierra's adventure games

Based on:

- Wanted Team's player of the sounds for EaglePlayer (2006), which keeps both of the Amiga
  interpreter's routines. That player was read for the player here.
- The interrupt that starts the notes comes round as often as a timer of 11,822 of the Amiga's E
  clock's ticks, and takes one more than that to come round: sixty times a second, all but exactly.
- `--agi pc` follows NewRisingSun's recordings of King's Quest II on the PCjr and the Tandy (at
  vgmrips.net), and the chip as MAME has it.

Checked against (Amiga):

- Wanted Team's player itself, run by UADE (3.05, which carries the same file), with Paula's filters
  off. Its later routine was chosen by setting the one value its configuration sets.
- Every one of the 745 files of UnExoticA's collection was played both ways by both. The stereo
  loudness envelopes were compared, a hundredth of a second at a time.
- Result: 0.989 alike on average for the first routine, and 0.992 for the later one.
- Each file is as long in both, but for the half second of quiet the player here gives any tune that
  comes to an end.
- Played a voice at a time, the pitches, the volumes and the dying away of the notes agree, and the
  noise to the sample.
- Where the two differ, it is in the phase of a tone. That comes of the voice never being started
  again: a note's period is taken up when the sample that is playing ends. So where in its wave a
  voice is depends on exactly when each note before it began, which differs between the two by a
  little. Where two voices on one side play the same note, whether they add up or cancel depends on
  that too.
- Through UADE the first notes also begin a tick later, its first interrupt coming after its start.

Checked against (PC):

- Each of the 13 recordings of the interpreter of the DOS version is of a file in UnExoticA's
  collection.
- Eight sound the same as their file played here, from moment to moment.
- In a ninth, the chip is told the same throughout the file, the recording going on past its end.
- The other four differ where the recording leaves out writes that, by its own reckoning, changed
  nothing: the silent notes' bytes, the volumes written again after them, and the silencing of
  voices at the end.

Loudness:

- On the Amiga, the median of a hundred of the sounds of ten seconds or more is within a dB of the
  rest of the music, with either routine.
- On the PC's chip they were 6.7 dB louder than that, and are turned down to match.
- Level: on the PC's chip the sounds were 6.7 dB louder than a MOD file, and are turned down to match.

### MOD — ProTracker and the Amiga

Based on:

- ProTracker 2.3D's replayer, by way of pt2-clone's port of it to C.
- Paula is run at 96,000 samples a second, with each step in her output replaced by one that holds
  nothing above the range of hearing. Then come the Amiga's output filters, and the result is
  halved.
- E8x is left out, as in pt2-clone.

Checked against:

- `siday --raw file.raw tune.mod` writes the tune as pt2-clone writes one to a file: sixteen bits
  with its dither, and a long sample cut off where ProTracker cuts it. The two agree to the sample.

Packed files (PowerPacker, XPK):

- The unpacking follows Teemu Suutari's ancient, a library that unpacks most of the packers the
  Amiga had.
- It agrees with ancient to the byte on every packed module in the test collection: 28 packed by
  PowerPacker and 8 by XPK.
- One of the eight unpacks to a module packed again by The Player 4.1, which is unpacked in its
  turn.

Modules packed for games (ProWizard):

- The unpacking is a port of the part of Sylvain Chipaux's ProWizard, as libxmp keeps it, that these
  packers need.
- Its tests are asked in the order libxmp asks them, and are given as much of a file as libxmp gives
  them.
- A module that says what it is in four letters is taken as one before any packer is asked. One of
  the oldest, which says nothing, is taken only after.
- Every one of the 787 files of UnExoticA's collection that ProWizard unpacks is unpacked here to
  the same bytes.
- So are some 28,000 copies of them cut short or changed at random, including those ProWizard
  refuses or reads past the end of.

Decisions where siday is not ProWizard (two are the player's own):

- Pha Packer: a file does not say how long its song is. ProWizard counts it to the last place in the
  order that plays a pattern other than the first, so a jingle whose every place plays one pattern
  is a song of no length. It is played here as that pattern once (fourteen files, of Brian the Lion
  and of Frankenstein).
- Ultimate Pinball Quest's modules say "KURT" where ProRunner's say "SNT."; they are taken as
  ProRunner's, and so unpacked as UADE plays them. So are the eight of Winter Olympics, which say
  "+SNT" there.
- UADE's converter, Nicolas Franck's Deli-Wizard, looks at how such a file is made and not at those
  letters. It takes six of the eight Winter Olympics files as ProRunner's. Compared with UADE over
  their first 40 seconds, by the stereo loudness envelope, those six are 0.995 alike or more.
- The other two, of the biathlon and the ski jump, Deli-Wizard takes first as Unic Tracker's, with
  eight and ten songs, and plays as something else.
- NoisePacker 3: ProWizard's test asks for more than 63 bytes of tracks and no line with nothing on
  it. Deli-Wizard looks at neither, and nor is either asked here. So the first level of Last Ninja 3
  and two of the shortest sound effects of Dragonstone play. Two more of Dragonstone's, 46 bytes
  each, are nothing of the kind, and are not played.
- The Player 6.0's packed samples (each byte two steps of four bits, half the size): ProWizard does
  not unpack those; they are unpacked as Deli-Wizard unpacks them (the intro of Statix, which comes
  out the size its file says).
- Promizer 1.8a: each pattern is taken from where the song first plays it, as Deli-Wizard takes it.
  ProWizard takes the pattern of each number from that place in the order instead, and so plays the
  wrong patterns of a song that plays one again before its last is first heard (the one of
  Aquanaut).
- Two of Brian the Lion's are silent, because ProWizard numbers their patterns wrongly, where UADE
  plays them. One of Evil's Doom's is silent in both.
- A file whose last sample is cut short (sixteen of The Player 4's) says so, and plays with that
  sample silent.

ChipTracker:

- Read as ChipTracker's own replayer reads it, as kept in Wanted Team's player for EaglePlayer.
- The 41 files of UnExoticA's collection, compared with that replayer run by UADE over their first
  minute, are 0.997 alike on average by the stereo loudness envelope.
- OpenMPT reads these files otherwise: it keeps every note within ProTracker's three octaves, uses
  the samples' finetune, and counts a loop's start in words.
- OpenMPT also reads some as having sounds of their own making, from waveforms kept before the
  tracks. No file in the test collection has them, nor is there a replayer of them to play them by,
  so such a file is not played.

Channel Players (`.chan`, Fury of the Furries):

- Unpacked as Deli-Wizard unpacks it, the packer asked after every other.
- UADE plays each module so made the same to the tick as it plays the file itself, all nine tunes.

SoundTracker 2.6 and Ice Tracker:

- Read as Deli-Wizard reads it. The one file in the test collection, of Exile, is 0.998 alike with
  UADE over its first 40 seconds.
- A speed command with both its digits set is, in SoundTracker 2.6, two speeds taken in turn from
  line to line, as libxmp plays it. It is left here as ProTracker reads it. Deli-Wizard makes a
  speed and a tempo of one of more than 31. The file in the test collection has none.

Oldest 15-sample modules:

- Seven of Jean Baudlot's (Bad Dudes, Castle Warrior) have order entries past the end of the song
  for patterns the file does not have. They are read counting patterns over the song, not the whole
  order. UADE does not play them.

Startrekker and Audio Sculpture:

- Instruments are played as ASREPLAY, The Synchron Assembly's replay routine, plays them, as UADE
  plays them, tick for tick.
- OpenMPT reads them into an envelope, an automatic vibrato and a pitch envelope of its own. That is
  near but not the same: it holds a note that ASREPLAY lets die away, and its noise is the same on
  every tick.
- 154 Startrekker modules name a place in their order to go round to; four use a speed of nothing.
- ASREPLAY leaves a sample silent whose byte of finetune is not nothing. That would silence seven
  modules, one of them altogether, so siday departs from it there.

AMOS:

- Read as UADE's player of the banks reads it: DEFECT's, put together for UADE by mld, under the
  GPL.
- The reading: the samples' headers from the instruments'; the order from the first voice's list;
  each command as ProTracker's like it; the last command that goes on, kept on each line until
  another; a tempo as a hundred over AMOS's; and the end of a pattern as a break on the line before.
- Compared with UADE over their first 40 seconds, eight banks of seven games are 0.995 alike or
  more.
- Five banks of Tyran crash UADE: their first pattern jumps at line 22, and the converter reads on for
  all 64 lines, past the end of the bank. Here a pattern's conversion stops where the bank ends, and
  its lines left are empty. No oracle plays them; every other bank in the collection renders the same.

Magnetic Fields Packer (`.mfp`):

- libxmp, as far as its release 4.6.3, read the table that says where each voice's tree begins as
  having an entry for each pattern.
- The format's own replayer, in Wanted Team's player for EaglePlayer, reads it as having one for
  each place in the song, which is how it is read here.
- The order the file keeps beside it is the one the module had before it was packed, not the one
  that is played.
- libxmp reads it so too since 4.7.1, of July 2026, in which Alice Rowan put it right.
- Compared with the replayer, run by UADE, over their first 40 seconds, by the stereo loudness
  envelope: the 37 songs of UnExoticA's collection read the old way are 0.76 alike on average, those
  whose patterns are not in the order of their numbers coming out scrambled. Read the replayer's way
  they are 0.994 alike, and 0.982 at the least.

### MED — MED and OctaMED

Based on:

- Not ports: OctaMED's own players are not free to copy, so these were written afresh and then held
  to them.

Checked against:

- OctaMED's players, run in an emulated Amiga (UADE) on every MED module of a collection, compared
  with these in whatever each way of playing leaves to be seen.
- Four-voice modules: compared in everything written to the sound chip's registers. That is each
  voice's period and volume on every tick, where each note starts in its sample and where it goes on
  from, and how long each tick lasts.
- Five to eight channels: what is compared is every byte the chip is given. They are the same bytes.
- Five, six or seven channels: putting the mix for the shared voices in the right place, where
  OctaMED put it in the wrong one, is the one thing in this mode that was not checked against it.
- Mixing mode: what the player tells its mixer is written down and played again through the
  arithmetic of OctaMED's own mixing, eight bits and all, by a small program kept outside the
  package. What comes out is compared with what the emulated Amiga's chip was given, and they are to
  be the same bytes.
- Mixing mode: the three things OctaMED's player gets wrong (silent first tick of each track, a
  mid-song tempo change ignored, a sound-card instrument a semitone sharp) are put right when
  listening, and done wrong only for that comparison.

Debugging:

- `SIDAY_MED_TRACE=1 siday --raw /dev/null tune.med` writes what the player tells the sound chip, a
  line a tick.
- For five to eight channels it writes what the player mixes for the chip; the bytes go to the file
  `SIDAY_MED_MIXED` names.
- In mixing mode it writes what the player tells its mixer.

MED4:

- Of each instrument, only the few words that are not as they would be by default are written, after
  a mask of which instruments there are.
- Of each block, only the lines and tracks that have something on them, a nibble at a time. A note
  or a command is twelve bits: the first or the last twelve of the three bytes an MMD0 module gives
  a note.
- The samples are as an MMD0 module's are.
- OctaMED's players do not read MED4 files, so the check is in three parts, on the three files in
  the test collection, all three of MED 3.00.
- Part one: libxmp reads each of them as it reads the MMD0 module that a separate script makes of
  it, note for note and command for command.
- Part two: that module, played by OctaMED's player in the emulated Amiga, and the MED4 file played
  here, give the sound chip the same periods, volumes and samples on every tick, the whole of each
  tune.
- Part three: the file is played here as the module is, to the sample.
- Where libxmp plays the file differently, it slips: it rounds where an instrument's repeat begins
  down to a whole 256 bytes (the name it copies runs over into the number).
- libxmp would read the two bits beside a note that an MMD0 module gives to the instrument's number
  as part of the note. Here they are the instrument's, as in a module, though none of these files
  has an instrument past the fifteenth to show which is right.

MMDC (packed MED):

- Unpacked as libxmp unpacks it.
- Compared with the game's player, run by UADE, over the first 40 seconds, by the stereo loudness
  envelope: the songs of Captain Planet are 0.994 alike or more, and the title of Knightmare 0.973.

### SFX — SoundFX and Oktalyzer

Based on:

- Not ports: the trackers' own routines are not free to copy, so these were written afresh and then
  held to them.
- SoundFX's songs are found much as the player of these files for DeliTracker finds them.

Checked against:

- The routines were run in an emulated Amiga (UADE) on every such module of a collection, 283 of
  SoundFX's and 42 of Oktalyzer's. They were also run on some hundreds of modules made at random to
  use what those do not.
- Everything they wrote to the sound chip's registers was compared with what these write: each
  voice's period and volume, where each note starts in its sample and where it goes on from, in the
  order they were written and on the ticks they were written on.
- They are the same, for every one of those modules from its beginning to its end.
- For the seventeen Oktalyzer modules of the collection that have split voices, every byte the chip
  was given to play is compared too, wherever it can be told from what the emulated chip put out.
  That output is the byte times the voice's volume: so not while the volume is nought, nor in the
  moment it changes, which leaves nineteen parts in twenty of the time. They are the same bytes,
  some two hundred million of them.

Notes on Oktalyzer timing:

- How long a stretch is mixed on a tick depends on whether the chip, which keeps its own time, has
  got ahead of the player's timer. In the emulated Amiga that turns on a clock or two: on how many
  instructions the routine happened to run on the tick before.
- So when it plays, this player reckons the chip's time itself, in whole clocks as the Amiga kept
  it. It comes to the same length as the routine on three ticks in four. On the others a stretch is
  a word longer or shorter a tick sooner or later: the same run of lengths, a tick out of step.
- For the comparison, it is given the lengths the routine was seen to choose.
- Oktalyzer began to fill a stretch of memory again when the chip might not yet have fetched its
  last words. On an Amiga the mixing took most of a tick to get that far. UADE runs this routine
  with every instruction taking one clock, and there the chip now and then plays the last word or so
  of a stretch from what has just been written over it.
- That is passed over in the comparison, and counted (one stretch in 260). It does not happen here,
  where a voice has a third stretch to mix into.

Debugging:

- `SIDAY_SFX_TRACE=1 siday --raw /dev/null tune.sfx` and `SIDAY_OKT_TRACE=1 siday --raw /dev/null
  tune.okt` write what the players tell the sound chip, a line a tick.
- What Oktalyzer's player mixes goes to the file `SIDAY_OKT_MIXED` names.
- `SIDAY_OKT_WORDS` names a file of the lengths it is to go by.

### AHX

Based on:

- ahx2play's port to C of the replayer of AHX 2.3d-sp3, in whole numbers, with its mistakes.

Checked against:

- `siday --raw file.raw tune.ahx` writes what ahx2play writes to a file: Paula at the rate of the
  output with nothing after her, at ahx2play's loudness and with its dither.
- The two agree to the sample: on a quarter of an hour of each of the 858 files tried, and on three
  minutes of every other song in them.

### HVL — HivelyTracker

Based on:

- The replayer and the mixer of HivelyTracker 1.9, as they are in the players that come with the
  tracker.
- The same replayer plays AHX files when asked (below).

Checked against:

- `siday --raw file.raw tune.hvl` writes what the replayer makes, sixteen bits a side. The two agree
  to the sample on a quarter of an hour of each of the 34 files tried.
- They also agree on a minute of each of 1,800 songs in files made up at random to do everything the
  format can, which those 34 between them do not.
- With the variable `SIDAY_AHX_AS_HIVELY` set (to how far apart the Amiga's two sides are to be,
  from 0 to 4), `--raw` plays an AHX file through the HivelyTracker replayer and not through AHX's
  own. That way the two agree on three minutes of every song of the 858 AHX files as well.
- The `hvl2wav` that comes with the tracker is not what is compared with. It still has an older
  replayer, from before the filtered waves and the noise were made to be AHX's own, and sounds a
  little different.

### DIGI — DIGI Booster

Based on:

- The file is read into the FastTracker 2 replayer, as MOD files of more than four channels and MTM
  files are, with the per-format behaviours listed in FORMATS, as OpenMPT plays these files.

Decisions:

- Unpacked patterns are read a channel at a time, as OpenMPT reads them. libxmp reads them a row at
  a time. The one such file in the collection then has its speed set on eight rows running, and
  every channel playing seven or eight samples. Read OpenMPT's way, the speed is set on every eighth
  row and the channels play two to four.

Checked against libopenmpt:

- All three files in the collection are played. Every sample is as libopenmpt reads it, to the last
  byte of its sound and its loop.
- Every channel's pitch and volume was compared with libopenmpt's on every tick of each file, to its
  end. Of 47,892 ticks they are alike on 47,813, one file on every tick. The rest are where a sample
  ends within a tick, which the two look at differently.
- A file made for the purpose, with every one of the behaviours in it, is alike on 861 of 864 ticks.
  The other three: the tick of the note that is turned round at once, and two of a voice at no
  volume.
- Audio compared with libopenmpt for two minutes of each file: the spectrum agrees to between 0.989
  and 0.999, and the loudness over time to between 0.987 and 1.000.
- Level: set by measurement, about as loud as other modules.

### DBM — DigiBooster Pro and DigiBooster 3

Based on:

- libdigibooster3, DigiBooster 3's replayer (published 2014, BSD licence), ported whole and in its
  own whole-number (integer) arithmetic.

Checked against libdigibooster3, built from its sources:

- `siday --raw file.raw tune.dbm` writes what the replayer writes to a file through the example
  program that comes with it, sixteen bits a side. `--raw` leaves out the four differences listed in
  FORMATS.
- The two are the same to the sample on every one of the 187 songs found in the 175 files in the
  collection that the replayer plays, to their ends or for ten minutes.
- That includes the example program's own oddities. It asks for 100,000 frames at a time. Whether a
  track whose sample has ended goes on is settled once for each part that is asked for. A song that
  stops itself on a tick that fills one of those parts to its end is not stopped, and plays one row
  more.

Decisions:

- Echo settings: with the file's settings, 59 of the 87 files with an echo come nearer to
  libopenmpt, which sets its echo as the file does, and 3 go further.

Checked against libopenmpt and libxmp, on every tick of the first five minutes of every file:

- The three are at the same row of the song on every tick, for all but four files and the very end
  of a song.
- Three of those four set the start of a loop beside a change of speed on one note. OpenMPT, which
  has room for one command and a volume beside a note, loses the start of the loop; libxmp keeps it.
- In the fourth a note sets the speed twice. The replayer takes the second, as OpenMPT does; libxmp
  takes the first.
- What is heard is another matter. libopenmpt and libxmp play DigiBooster's slides and vibratos as
  ProTracker's, on the ticks after a row's first and in periods, with one echo for the whole tune or
  none.
- Over the first minute of each file, the spectrum agrees with libopenmpt to 0.955 for the median
  file, and with libxmp to 0.967; the two agree with each other to 0.968. The loudness over time
  agrees to 0.939 and 0.935, where the two agree to 0.971.

### TFMX — Chris Hülsbeck's music system

Based on:

- Michael Schwendt's libtfmxaudiodecoder, ported line for line. With the changes below set aside, it
  still writes to Paula, tick by tick, what that library writes.
- That holds for every song of every one of the 322 modules of UnExoticA's collection (915 songs,
  two modules having none that can be played), looping or not. It also holds for some 45,000 copies
  of them cut short or changed at random.

Checked against:

- Wanted Team's players of the files for EaglePlayer: "TFMX player module V1.3" for TFMX 1.x, "TFMX
  Pro player module V1.3", and the player of TFMX 7V. Their 68000 code was read for the changes
  below.
- UADE running those players. Each change was compared with UADE: the Paula registers that UADE's
  players write, tick by tick, against those siday's player writes.

Decisions (where siday differs from the library):

- **Which player a module is played as.** The library tells TFMX 1.x from TFMX Professional by an
  old mark in the header and by checksums of modules it knows. siday ports UADE's test of a file's
  contents, which takes 167 of the collection's modules for TFMX 1.x where the library took 35. The
  load-time mends that Wanted Team's players make to a few modules are made too.
- **What each player does.** Each is in the code, with the place in the player it comes from. Among
  the many things the library has otherwise are the items below.
- **TFMX 1.x note start:** a note's macro starts a tick after the note, and that tick has no
  effects.
- **SetNote** keeps the voice's detune.
- **Slides:** a slide that reaches its note waits there for the next, where the library ends it.
- **Commands:** the pattern commands $FB to $FD, and the track commands that loop, fade and change
  speed, are as the player has them.
- **TFMX Professional:** a voice is started and stopped at once, as UADE's settings for the player
  have it. The second byte of DMAon says whether effects are run on the next tick. $FC locks a
  voice. The extra tick a note waits always comes.
- **Both players:** a macro that waits for a sample to come to its end waits for the interrupts
  Paula would have raised.
- **How often the player runs.** The library has fifty ticks a second, or two fifths of a song's
  beats a minute. TFMX Professional's player sets the computer's timer to $1B51F8 over the beats,
  which is slower than that by nearly one part in a hundred. The first player sets it to $1C00 over
  them, in the timer's upper byte.
- **TFMX 7V mixing rate.** The player mixes at its own 16 kHz. UADE's settings for it ask for
  20 kHz, which makes a tick a hair shorter.
- **TFMX 7V buffers.** A buffer of 320 bytes for each tick, longer or shorter by the song's tempo,
  is played on the fourth voice at a period of 224. The tick is when the fourth voice comes to the
  end of a buffer. A buffer is mixed from what the voices were told the tick before, and heard the
  tick after. All of it is done into buffers that siday's Paula plays as the fourth voice.
- **TFMX 7V voices.** A voice steps through its sample at its own period's rate against the
  mixing's, with nothing between one sample and the next. Its volume comes from a table in which 64
  is 63. The four are added and clipped to a byte. A sample or loop of fewer than 32 words plays
  silence in its place.
- **When a song ends:** the library stops a song whose tracks have all ended or reached patterns
  that go round for ever; siday plays on, as the players do.
- **Level:** the median of the collection's modules was 5 dB quieter than modules are, and is turned
  up by that.

Results:

- Over the first 40 seconds of the first song of each module, 315 of the 320 that play write the
  same periods and volumes as UADE's players, tick for tick. The other five are listed in FORMATS.
- By the stereo loudness envelope over the first minute, siday and UADE are 0.958 alike on average,
  where the library is 0.937.
- Level: every format in siday is about as loud as a module played on the same chip. The median TFMX
  module of the collection was 5 dB quieter than modules are, and is turned up by that.

### HIP — Jochen Hippel's TFMX, and Future Composer

Based on:

- Michael Schwendt's libtfmxaudiodecoder, ported line for line. What it tells Paula, tick by tick,
  is the same as what the library tells it, for every song of every one of the 230 files of
  UnExoticA's collection (444 songs), looping or not. It is also the same for some 239,000 copies of
  them cut short or changed at random.

Decisions:

- TFMX 7V's mixing follows Hippel's own player, as Wanted Team keep it in their player for
  EaglePlayer ("(c) 1990-91 Jochen 'Mad Max' Hippel"). It is the same as Chris Hülsbeck's (see
  TFMX), but at 24 kHz, as UADE runs it (a period of 149).
- 480 bytes a tick, made longer or shorter by the song's tempo in 256ths.
- The player runs first and the buffer is mixed after, so what the four are told is heard a tick
  after the rest.
- A volume table of the sample times the volume over 63, rounded towards nought.
- Silence for a sample or loop of 16 words or fewer.
- The library adds the four at the rate of its output.

Checked against UADE, over the first minute of the first song of each file, by the stereo loudness
envelope:

- The 190 files that UADE plays are 0.975 alike on average, and six are below 0.9.
- The library itself is 0.962, with 33 below 0.9.
- Six of the seven files of TFMX 7V are 0.99 alike in siday, and 0.84 to 0.94 in the library.
- UADE plays the compressed files with a player of its own making ("hipc player V0.2 for UADE"). It
  does not play Amberstar's 39 songs.
- Level: Hippel's music was 4.7 dB louder on the Amiga's chip than modules are, at the median of the
  collection, and is turned down by that.

### PUMA, PAP, GMC and IMS — four small players of games' music
- Game Music Creator: until October 2026, forty of its fifty files were played as ProWizard's
  ProTracker modules, and ten were not played at all (ProWizard refuses them or finds them cut short).

Checked against UADE running each player:

- What each player tells Paula on every tick (its periods, volumes, and where each sample is and how
  long) is the same as UADE's running of the player tells it, from the first sound, for every file
  of the collection.
- The window is the first minute for PumaTracker's and Pierre Adane's files, and five minutes for
  Game Music Creator's and every song of Images Music System's.
- By the stereo loudness envelope over the first minute, they are 0.997 and 0.993 alike on average,
  none below 0.98. What is left over is how the chip itself is emulated.
- Game Music Creator: compared with UADE over the first minute, the forty files that ProWizard
  unpacks were 0.979 alike played as ProTracker modules, nineteen of them below 0.99. They are 0.992
  alike played by Game Music Creator's own player.
- Level: measured on the Amiga's chip at the median of the collection, PumaTracker's music is 3.5 dB
  louder than modules are, Pierre Adane's 3.1, Game Music Creator's 5 and Images Music System's 7.8.
  Each is turned down by that.

### DUM — more players of games' music, ported

Method:

- Each player is ported to Swift from the source UADE carries of the player that plays it. It is
  compared with that player, run by UADE, over the first 40 seconds of every file of UnExoticA's
  collection (or 300 seconds), by what it tells Paula on every tick. It is also compared over the
  first minute by the stereo loudness envelope.

Results:

| Player | Files in the collection | Against UADE's register writes | Stereo loudness envelope |
|---|---|---|---|
| Infogrames `.dum` | 36 files: twelve tunes and their copies | the same to the tick, given `rh.ins` | 0.994 alike or more |
| Fashion Tracker `.ex` | three | the same to the tick | 0.999 |
| Peter Verswyvelen Packer `.pvp` | twelve | the same to the tick | 0.987 or more |
| Alcatraz Packer `.alp` | twelve | the same to the tick but for one command (9) | |
| Digital Sonix & Chrome `.dsc` | twelve: seven tunes, five banks of sound effects | the same, but where a note's first interrupt is lost to a race of the player's with the chip, on one note in forty, which falls on other notes in the two Amigas | 0.997 or more for the music |
| Andrew Parton `.bye` | twelve | the same to the tick | 0.9995 |
| Editeur Musical Séquentiel `.ems` | six | the same to the tick | 0.9986 or more |
| Forgotten Worlds `.fw` | five | the same to the tick as copies of Psygore's player mended in scratch (none of which is kept) | 0.992 or more |
| Leggless Music Editor `.lme` | three files, 35 songs | the same to the tick but for the first tick of each note | |
| JamCracker `.jam` | four | the same to the tick | 0.998 |
| A.M.Composer `.amc` | five | the same to the tick | 0.998 |
| Professional Sound Artists `.psa` | one | the same to the tick | 0.9975 |
| The Musical Enlightenment `.tme` | one | the same to the tick | 0.9998 |
| Steve Turner `.jpo` | five files, 47 songs | the same to the tick when played as Wanted Team's player plays them | |
| Cinemaware `.cin` | eleven | the same to the tick | 0.985 or more |
| Paul Shields `.ps` | fourteen | the same to the tick | 0.9997 or more |
| SoundPlayer `.sjs` | thirty-four | the same to the tick | |
| Paul Robotham `.dat` | nineteen | the same to the tick for five minutes | |
| Thomas Hermann `.thm` | four files, ten songs | the same to the tick with Wanted Team's timer | |
| Synth Dream `.sdr` | eight | the same to the tick | |
| Blade Packer `.uds` | five files, 94 songs | all but two songs the same to the tick; those two but for two or three ticks of silence UADE hurries through | |
| Tim Follin `.tf` | thirteen files, twenty songs | the same to the tick | |
| Paul Summers `.snk` | four files, 23 songs | the same to the tick when played Wanted Team's way | |
| Action Amics `.ast` | 32 songs, 20 played | all twenty the same to the tick | |
| David Hanney `.dh` | eight | the same to the tick | |
| Ron Klaren `.cm`, `.rk` | 24 files, 59 songs | the same to the tick with Wanted Team's timer | 0.93 to 0.96 |
| Jason Page `.jpn` | eighteen files, 79 songs | the same to the tick, to each song's end | 0.89 to 0.98 |
| SoundControl `.sct` | 21 files, 31 songs | the same to the tick | 0.948 to 0.998 |
| Synth Pack `.osp` | seventeen files, 30 songs | the same to the tick, to each song's end | 0.87 to 0.98 |
| Silmarils `.mok` | fourteen files, 33 songs | all but one the same to the tick; in Colorado's first, one note UADE loses to a race with Paula | 0.974 to 0.993 |
| Soundfactory `.psf` | one file, five songs | the same to the tick | |

Notes:

- Forgotten Worlds: in UADE, four of the five files are silent with Psygore's player, and the rest
  stall.
- Thomas Hermann: Paula's interrupts end a sample played once on its third interrupt and begin a
  loop on its second, as on the machine. Wanted Team's timer is kept for comparison.
- Paul Summers: Wanted Team's way is kept for comparison.
- Level: measured on the Amiga's chip at the median of their files, these players are between 1.0 dB
  quieter and 7.3 dB louder than modules; each is brought to the level of the rest by its own amount.

### BP — Brian Postma's SoundMon

Based on:

- Brian Postma's replay routines, as mld adapted them for UADE, from the source UADE carries.

Checked against UADE:

- What the player tells Paula on every tick (its periods, volumes, and where each sample or waveform
  is and how long) is the same as UADE's running of it, for all 80 files over their first three
  minutes.
- What it writes into the waveforms as they play is the same as what UADE's Paula plays from them.
- By the stereo loudness envelope over the first minute, all 80 are 0.983 alike or more, 79 of them
  0.99. The same gentle cut of the deepest bass was applied to both, since some of these waveforms
  sit far from the middle.
- Each of the 69 songs past the first plays as UADE plays a copy of its module with the list of
  steps turned round to begin there (and its jumps made to go where they went), tick for tick over
  200 seconds.
- Level: SoundMon's music is 1.5 dB louder on the Amiga's chip than modules are, at the median of the
  collection, and is turned down by that.

### SIDMON — SidMon and SidMon II

Based on:

- mld's adaptation of SidMon's player for UADE, and Defect's of SidMon II's.

Checked against UADE:

- What the player tells Paula on every tick, and the bytes Paula plays from the waveforms it
  rewrites, are the same as UADE's for all fifteen files over their whole songs.
- By the stereo loudness envelope over the first minute, they are 0.98 to 0.9995 alike.
- SidMon's own check takes exactly Venom Wing's three of the 61,000 SID files in the collection.
- Level: at the median of the collection, SidMon's music is 5.6 dB louder on the Amiga's chip than
  modules are, and SidMon II's 3.6. Each is turned down by that.

### MUG — Digital Mugician and Mugician II

Checked against UADE:

- Register writes and waveform writes are the same as UADE's for every song of every file over its
  first 40 seconds. The exception is one voice that plays nothing, whose note falls past the
  player's table.
- Mugician II's four mixed voices are mixed byte for byte as its player mixes them.
- By the stereo loudness envelope over the first minute, the files are 0.994 to 0.9998 alike.

Notes:

- Note starts: the first player's note is silent until 1.8 ms into the tick; its EaglePlayer module
  waits eight or nine raster lines before it.
- The waveforms the players rewrite partway through, and the few tenths of a millisecond that one
  tick's or one file's work takes more or less than another's, are most of what is left between
  siday and UADE.
- Level: Digital Mugician's music is 4.3 dB louder on the Amiga's chip than modules are, at the median
  of the collection, and is turned down by that.

### DM2 — Delta Music 2.0

Checked against:

- UADE running Eagleeye's adaptation of the Delta Music 2.0 player.
- For all eleven files, over their first 40 seconds, the register writes to Paula on every tick are
  the same as UADE's. So are the noise the player writes over its first waveform on every tick, and
  the start of a sample it clears when its loop begins.
- Stereo loudness envelope over the first minute: 0.983 to 0.9997.

Notes:

- Note starts about a millisecond into the tick match UADE's playing of the collection, its median.
- Which low notes carry on depends on where Paula is in a word, to within a few of her clocks, as
  each write is made. That is more closely than the player's timing can be known here, so every note
  starts again. That is the difference in the least alike file.
- Level: Delta Music is 7.2 dB louder on Paula than modules are, in the median of the collection,
  and is turned down by that.

### MXTX — MaxTrax

Based on:

- The MaxTrax driver's source (released under the GNU Lesser General Public License; UADE carries
  it), ported routine by routine.

Checked against:

- ScummVM's player of it, built on its own. It departs from the driver in eight ways (choosing
  voices, loudness, pitch, tempo slides and others).
- With those put back as the driver has them, the register writes to Paula on every tick are the
  same as siday's for 282 of the 283 songs over their first 40 seconds. The other is a score with no
  end, which ScummVM reads past.
- Stereo loudness envelope: every song with music in it is 0.90 alike or more, and the median is
  0.983.

### SA — Sonic Arranger

Based on:

- Wanted Team's player of the format, as UADE plays it, for the editor's modules and the games'
  songs.
- For the songs with a replayer in front, that replayer's rules, in its two builds, told apart by
  their bytes. The 68000 is not emulated.

Checked against:

- UADE. The register writes to Paula on every tick, and what the effects write into each voice's
  waveform, are the same as UADE's for all 240 songs of the 117 modules over their first 40 seconds.
- Stereo loudness envelope over the first minute: median 0.9966, none below 0.98.

Notes:

- Level: Sonic Arranger's music is 5.1 dB louder on Paula than modules are, in the median of the
  collection, and is turned down by that.

### SONIX — the Sonix Music Driver

Based on Wanted Team's player of the scores for EaglePlayer ("Sonix Music Driver player module
V2.0", 2004, which UADE carries). It holds three of Mark Riley's own players, one for each kind,
which Wanted Team took from games:

| Kind | Driver version | Taken from |
|---|---|---|
| SNX | 2.3c | Dynamix's Rise of the Dragon |
| TINY | 2.0b | Melbourne House's Magic Johnson's Basketball |
| SMUS | 2.0f | Synergistic's Vengeance of Excalibur |

siday's player is those three, read in their 68000 code, with the Amiga's memory that the
instruments are loaded into and the waveforms written into kept as the Amiga kept it.

Checked against UADE running that player:

- The register writes to Paula on every tick are the same as UADE's for all 237 scores over their
  first 40 seconds.
- Every score ends within three hundredths of a second of where UADE's ends.
- Stereo loudness envelope over the first minute: the median is 0.993 to 0.997. The least is 0.888,
  a score of sharp attacks whose notes all fall within 20 ms of UADE's.

Notes:

- Level: the Sonix Music Driver's music is 1.9 dB louder on Paula than modules are, in the median of
  the collection, and is turned down by that.

### ML — the Musicline Editor

Based on the Musicline Editor's own player for DeliTracker (`mlineplayer102.asm`, its authors'
source, which UADE carries), ported routine by routine, its waveform makers in the 68000's integer
arithmetic.

Checked against UADE running that player, on the collection's one module (Xenex-Remix.ml, two
tunes), mended as siday mends it (UADE plays nothing of the file as it is):

- The register writes to Paula on every tick are the same as UADE's: all 13,999 ticks of the first
  tune, past its end at tick 13,249, and all 1,982 of the second.
- The file siday mends is loaded byte for byte as the mended copy UADE played.
- Mono loudness envelope over the first minute: 0.91, stretched for UADE's timer, which runs about
  1% slow and unevenly.

Notes:

- Level: the Musicline Editor's music is about as loud on Paula as modules are, and is turned down
  0.4 dB to their level.
- UADE's timer B, which times a note's start within its tick, fires early, so the writes were
  compared tick by tick and not by their times within it.

### BD — Ben Daglish's drivers

Based on Wanted Team's player for EaglePlayer ("Benn Daglish player module V1.2", 2004), which UADE
uses. What it does is done in Swift; the driver runs on siday's Amiga.

Checked against UADE:

- The register writes to Paula on every tick are the same as UADE's for 129 of the 135 songs over
  their first 40 seconds, and two more are silent in both.
- Every song ends within a few hundredths of a second of where UADE's does.
- Stereo loudness envelope over the first minute: 0.9993 on average, none below 0.99.

Notes:

- Level: Ben Daglish's music is 6.4 dB louder on Paula than modules are, in the median of the
  collection, and is turned down by that.

### DW — David Whittaker's own drivers

Based on Wanted Team's player for EaglePlayer ("David Whittaker player module V1.0", 2000; "(c)
1987-94 by David Whittaker & Rob Hubbard, adapted by Wanted Team"), which UADE uses. What it does to
find and mend a driver is done in Swift; the driver itself runs on siday's Amiga.

Checked against UADE:

- The register writes to Paula on every tick are the same as UADE's for all 551 songs of the 115
  modules over their first 40 seconds, or to where they stop.
- Every song ends where UADE's does.
- Stereo loudness envelope over the first minute: 0.9992 alike on average.
- Rob Hubbard's Q-Ball, run from Paula's interrupts on the host for DeliTracker's players: its four
  songs the same on every tick to their ends, but for the second voice's first interrupt, which UADE
  loses on 71 of its 106 notes in the tune by a race of some 16 clocks (the driver clears the voice's
  request just after it turns its DMA on); with those two writes swapped in a copy, UADE matches on
  every tick. Envelope 0.92 to 0.97 alike.

Notes:

- Because what only feeds EaglePlayer's own displays is left out, the driver's writes come a fifth
  of a millisecond earlier in each tick than UADE's, in the median.
- siday's Amiga lays out the first bytes of memory as UADE lays them out, since a driver may read
  them.
- Level: Whittaker's music is 4.6 dB louder on Paula than modules are, in the median of the
  collection, and is turned down by that.

### MW — Martin Walker's own drivers

Based on Wanted Team's player for EaglePlayer ("Martin Walker player module V1.1", 2001), which UADE
uses.

Checked against UADE:

- The register writes to Paula on every tick are the same as UADE's for all 106 songs over their
  first 40 seconds, or to where they stop.
- Every song ends where UADE's does.
- Stereo loudness envelope over the first minute: every song is 0.991 alike or more.

Notes:

- Level: Martin Walker's music is 6.0 dB louder on Paula than modules are, in the median of the
  collection, and is turned down by that.

### JD — Special FX's driver

Based on Wanted Team's player for EaglePlayer ("Special FX player module V1.1", 2007), which UADE
uses.

Checked against UADE:

- The register writes to Paula on every tick are the same as UADE's for all 355 songs that are
  heard, over their first 40 seconds. The four that are never heard are the same write for write.
- Every song ends where UADE's does.
- Stereo loudness envelope over the first minute: every song is 0.996 alike or more.

Notes:

- Level: Special FX's music is 1.7 dB louder on Paula than modules are, in the median of the
  collection, and is turned down by that.

### MON — the Maniacs of Noise's drivers

Based on, as UADE plays them:

- The later driver: UADE's own player of them ("MON player module V0.1 for UADE", 2002, by Heikki
  Orsila, "based on replayer by Frederick Hahn and Maniacs of Noise/Charles Deenen"), which calls
  the file's own driver.
- The earlier driver: Wanted Team's player ("Jeroen Tel player module V1.0", 2004), which runs a
  copy of its own of the driver of Unreal's title, its addresses moved to where the file is. siday
  instead runs each file's own driver at its own address, with Wanted Team's few changes made to it.

Checked against UADE:

- The register writes to Paula on every tick are the same as UADE's for all 87 songs over their
  first 40 seconds, or to where they stop.
- Stereo loudness envelope over the first minute: every song is 0.998 alike or more.
- The build of UADE these were checked against never says that a song of the later driver has gone
  round, and plays them on. So their lengths have nothing to be compared with; siday's end rule
  follows the source of UADE's player.

Notes:

- Level: the later driver's music is 1.7 dB quieter on Paula than modules are, in the median of the
  collection, and the earlier's 1.0 dB; they are turned up by that.

### CORE — more composers' own drivers, by Wanted Team's recipe

Based on:

- What each of Wanted Team's players does, done in Swift, with their patches assembled as they are.
  Each format is a few hundred lines of what its player does.
- No part of Wanted Team's players is carried here. Their code was read, and where its source is not
  given, its 68000 code.

Checked against:

- UADE running Wanted Team's player, over the first 40 seconds of every song of UnExoticA's
  collection, by the register writes to Paula on every tick.
- The stereo loudness envelope over the first minute, for some songs of each.

| Format | Stereo loudness envelope, songs measured | Other notes |
|---|---|---|
| Core Design | six of eight 0.999 or more; the other two 0.92 and 0.97, where a voice is turned off and on again (see SPL) | the three songs whose writes are not in UADE's order are silent stretches |
| Janko Mrsic-Flogel | eight songs, 0.997 or more | |
| Benn Daglish SID | four, 0.999 or more | |
| Fred Gray | four, 0.996 or more | |
| Howie Davies | three, 0.9996 or more | |
| Sound Programming Language | four, 0.977 to 0.995 | |
| Beathoven Synthesizer | 0.99 or more | tick for tick once a register written twice with the same value is passed over |
| Sound Master | 0.9995 or more | |
| Steve Barrett | 0.994 or more, but Street Fighter's first song 0.94 | |
| Rob Hubbard | 0.998 or more | |
| Rob Hubbard ST | 0.985 or more | |
| Fred Monitor | 0.994 or more | |

Notes:

- Core Design: its routine for Paula's audio interrupts is put on each of her four through exec's
  SetIntVector, as the player does.
- Sound Images: Eight songs crash UADE, as some modules ask for those interrupts before their
  handler is in place. siday waits for the handler, as UADE does when it does not crash. Which
  notes' first samples the handler catches depends on a few of the processor's clocks against the
  beam, on both Amigas.
- Core Design: two songs differ a little by the stereo loudness envelope where a voice is turned off
  and on again (see SPL); see the table.
- Desire: UADE's three songs that end, end at the same moment as siday's.
- Level: at the level of modules, these come out between 0.5 and 8.6 dB louder, in the median of
  their files, and each is turned down by its own amount to the level of the rest.

### CUST — DeliTracker's custom modules

Based on:

- UADE's host for the players (`score`). siday's host does what UADE's does, in its order and at its
  addresses.

Checked against UADE:

- Of the 2,539 songs of the 416 modules played on that host (these, and Dave Lowe's own; see DLN),
  2,381 are the same as UADE's in every write to Paula over their first 40 seconds.
- Most of the others are the same but where the processor and the chip race to a moment, which
  UADE's processor and siday's reach a little differently.

Where UADE is wrong:

- Immortal and Zany Golf part from UADE early on. Their code subtracts, and then subtracts again
  with what the first borrowed (SUBX). UADE's processor, built as it is without its x86 assembly,
  keeps nothing of a borrow from SUB, SUBQ or NEG.
- With that mended in a UADE of our own, 20 of their 21 songs are the same as siday's in every
  write, and the last is the same but for one write of a volume the voice already had.

Electronic Arts' fifteen (Archon, Marble Madness, M1 Tank Platoon, World Tour Golf and the rest), on
exec's own system (`DeliTrackerHost.System.exec`, `AmigaExec`, `AmigaTimerDevice`, `AmigaAudioDevice`):

- Based on: the Autodocs of exec, timer.device and audio.device, and what Kickstart 1.3's (exec 34.2,
  audio.device and timer.device 34.1) were measured doing in Copperline, by the program counter of every
  write to Paula. No code of a ROM's is carried. A module is given this system only when it stops on a
  routine of exec's that score does not give; every other module plays on score's as before, bit for bit.
- Checked against Copperline 1.0.1 (an A500 with 1 MB of chip memory, Kickstart 1.3, the module hosted
  as DeliTracker hosts it, DTP_Interrupt from CIA-A at level 2 as score calls it), 60 seconds of each of
  the 48 songs: every song has the same note starts (voice, sample, length, period, volume) as the
  reference. Most fall on the same tick; the rest fall a tick to one side, where the system's own code
  takes the Amiga longer than siday's. In M1 Tank Platoon 3 to 6 notes a song differ because the
  reference lost an interrupt in 1.3's start of a note.
- The envelopes (ADCMD_PERVOL) are stepped by timer.device at 50 Hz while the music ticks at 60 (45 for
  World Tour Golf), so how they fall depends on where the first tick lands in the frame. With the
  reference's phase, most match per tick; without it, they come out as on another Amiga started a moment
  later.
- Loudness envelopes against the references, high-passed at 40 Hz: 0.69 to 0.99. Copperline's own runs on
  Kickstart 3.1 and 1.3 agree with each other at 0.81 to 0.99. The lowest are Skyfox and Marble Madness's
  first songs, dense music in unison whose beating follows the voices' phase within a tick.
- The time the system's routines take on an Amiga is spent: each is charged its median as measured
  on Kickstart 1.3, which brings the notes' moments within a tick closer to the reference's.
- A voice whose DMA comes on during a word written by hand starts its block at once
  (`AmigaChips.manualWordStartsBlock`), as audio.device's every note needs. It is off for every other
  module.
- Not settled: what a write of more than one cycle does when it runs out with nothing behind it (never
  seen; it is stopped, as 1.3 stops a write of one cycle), and timer waits longer than a frame
  (counted in fiftieths of a second, as the Autodocs have them; never measured).

Notes:

- Level: these modules' music is 3.4 dB louder on Paula than modules are, in the median of the
  collection, and is turned down by that.

### RJP — Richard Joseph's player

Based on Wanted Team's player for EaglePlayer ("Richard Joseph Player V1.7A module replayer V1.1",
2001, which UADE carries), read in its 68000 code, with its two load-time fixes (Crazy Football's
title and Cannon Fodder 2's KILLER).

Checked against UADE:

- The register writes to Paula on every tick are the same as UADE's for all 917 songs over their
  first 40 seconds, or to where they stop.
- Stereo loudness envelope over the first minute: median 0.9993.

Notes:

- Level: Richard Joseph's music is 3.1 dB quieter on Paula than modules are, in the median of the
  collection, and is turned up by that.

### DLN — Dave Lowe's later music

Based on Wanted Team's player for EaglePlayer ("Dave Lowe New", 2001, which UADE carries), read in
its 68000 code, with the fix to the data of one of Beneath a Steel Sky's songs as it loads.

Checked against UADE:

- The register writes to Paula on every tick are the same as UADE's for all 108 songs that make a
  sound, over their first 40 seconds. The other twenty, which are silent, are the same write for
  write.
- Stereo loudness envelope over the first minute: every song that makes a sound is 0.989 alike or
  more.
- The earlier programs (`.dl`): all but two of the 45 that are his are the same as UADE's in every
  song over their first 40 seconds. Frontier's and Midwinter II's are the same but for writes of a
  value the chip already has.
- The two older rips for DARKNESS's DeliTracker player ("Dave Lowe's Sound System", `DaveLowe_Deli`,
  binary only: read in a disassembly): all ten songs the same as UADE's on every tick, over 40 seconds
  and to each song's end and past it; loudness envelope 0.93 to 0.99 alike, as UADE is with siday's
  playing of the later rips. Against those, the same Paula writes song for song (see FORMATS).

Notes:

- Level: Dave Lowe's later music is 1.5 dB louder on Paula than modules are, in the median of the
  collection; his earlier music is 5.5 dB louder. Each is turned down by that.

### XM — FastTracker 2

Based on:

- FastTracker 2.09's replayer and mixer, by way of ft2play's port of them to C.
- `siday --raw file.raw tune.xm` writes what ft2play writes to a file, with stereo samples, empty
  patterns and sample kinds as FastTracker has them, and without the later trackers' ways with
  loops and missing patterns; the two agree to the sample.

Checked against libopenmpt, for files of other trackers:

- **Plug-ins:** the 107 files in the test collection that send something through a plug-in agree in
  spectrum to 0.993 for the median; without the plug-ins it was 0.982.
- **Plug-in levels:** how loud a plug-in is given its voices depends on which of OpenMPT's mix
  levels the file asks for. Until October 2026 every mix level was given the same. A plug-in that
  squashes or bends its sound, and so makes something else of it when it is louder, then made what
  it does too loud or too quiet beside the rest. One file opens with a bass through OpenMPT's
  distortion that was heard 14 dB too loud beside the music after it. Now each mix level gives a
  plug-in the voices as loud as OpenMPT does, and what comes back is held where OpenMPT's integers
  end. Through the distortion, in each of the six mix levels, the bass comes out as loud beside the
  plain sound as libopenmpt has it.
- **Reverb (X99/X98):** of the 16 such files in the test collection, how alike their two sides are
  to libopenmpt's went from 0.31 to 0.97 for the median.
- **Sample ends dying away:** of 400 such files, 284 change. Where they change, 55 come nearer to
  libopenmpt sample by sample, and 4 go further.
- **Interpolation:** 50 XM files in the test collection ask for an interpolation by instrument.
  Compared with libopenmpt, the top of the sound (above 12 kHz, against what is between 0.5 and 6
  kHz) was on average 6.4 dB too loud in 100 such files. It now agrees within a decibel in 73 of
  them, where it did in 22. Of 400, 8 are audibly nearer libopenmpt by the other measures, and none
  further.
- **Arpeggio:** OpenMPT first had FastTracker's arpeggio in version 1.17.03.02; files from before it
  count up. Of all OpenMPT's other ways for an XM file that such trackers' files are played without,
  none was heard to change more than a handful of tunes, tried over a sample of 1,300 of them. The
  arpeggio changes about a thousand of the collection's files. Of 182 such files compared with
  libopenmpt, 180 changed and none went further from it; 79 came nearer by the spectrum (one from
  0.92 to 1.00).
- **Finetune:** OpenMPT keeps the full finetune in its files before 1.22.07.19, and in later ones
  that ask for it. Of 150 such files compared with libopenmpt, 104 came nearer by the spectrum, and
  none further.
- **X commands:** of the 76 files in the test collection that have them, compared with libopenmpt,
  20 came nearer by the spectrum (one from 0.77 to 0.99) and none went further. 80 others picked at
  random were not changed at all.

- **Files FastTracker had no room for (October 2026):** 150 XM files siday used to refuse were
  compared with libopenmpt over their first minute: more than 128 instruments, more than sixteen
  samples to an instrument, samples packed by ModPlug's MOD Plugin, files cut short or damaged
  partway through their instruments, and MED2XM's longer headers. 149 now play, with a loudness
  envelope of 0.9 or more in all but eight, each of those explained by something siday already did
  differently from OpenMPT. Instruments over the sixteenth sample, played alone, agree to 0.999.
  Every XM file of the collection that played before lists as it did, and 155 of them play to the
  sample as they did.

- **Later trackers' own ways (October 2026):** loudness envelope against libopenmpt, whole songs up
  to ten minutes, before and after:

  | Rule | Files checked | Median | Nearer / further |
  |---|---|---|---|
  | Sample kinds (Xrns2XMod) | 8 | 0.637 to 0.996 | 8 / 0 |
  | Empty patterns | 29 | 0.996 to 0.998 (least 0.43 to 0.83) | 9 / 0 |
  | Missing patterns | 14 | 0.804 to 0.998 | 8 / 0 |
  | Loops, ModPlug and OpenMPT | 18 | 0.739 to 0.997 | 14 / 0 |
  | Loops, DigiBooster Pro | 12 | 0.998 to 0.826 | 1 / 10 |

  The DigiBooster Pro files move away from libopenmpt on purpose: FastTracker's restart, which
  libopenmpt keeps for them, would hide about 6,000 notes in 19 files. F00 is unchanged, because
  libopenmpt alone plays past it. Of the whole collection, 335 XM files change length, each by one
  of these rules; FastTracker's own files play to the sample as they did.

### MTM, DTM and AMF — MultiTracker, Digital Tracker and DSMI

Based on:

- There is no player of these trackers to be right against. The check is against two players that
  have read these files for decades, libxmp and OpenMPT, and the loaders are written from theirs.

Checked against:

- What each loader made of every file in the test collection (394 MTM files, 92 DTM and 38 AMF) was
  compared with what libxmp made of it, note by note and sample by sample. `SIDAY_FT2_LISTING=1
  siday --raw /dev/null tune.mtm` writes it out.
- 170 files come out the same. Every difference in the rest is one of a few that were meant, each
  said in its loader. Most are where the two players read a file differently and one had to be
  followed.
- Then a minute of every tune was played by all three (siday, libxmp, OpenMPT), and the loudness
  over time and the spectrograms compared. By that measure nothing plays a wrong note, a wrong
  sample or at a wrong speed.
- The tunes furthest from both the others are those that lean on what one player does and another
  does not: a sweep from speaker to speaker, or two long samples kept in step by their pitch.

Notes:

- The pitch of a note is FastTracker's, from the Amiga's table of periods. That is OpenMPT's too, to
  within two cents. libxmp works a note out afresh and is four cents away on some. It also plays an
  MTM file a sixth of a semitone lower, at the rate of a European Amiga.
- Loudness, by measure: the median file of each kind is at the level of the median of 200 XM files.

### S3M — Scream Tracker 3

Based on:

- st3play's port of Scream Tracker 3, and its emulation of the cards (Gravis Ultrasound, Sound
  Blaster Pro).
- The AdLib card: Scream Tracker's driver, ported with the rest; the chip is a port of Nuked OPL3.

Checked against:

- `siday --raw file.raw tune.s3m` writes what st3play writes to a file: a stereo sample's left side
  only.
- The two agree to the sample when the environment variable `SIDAY_REFERENCE_SLIPS` is set. That
  repeats one slip of st3play's that Scream Tracker did not make: it loses the sign of a number on
  very high notes, and plays them wrong.
- AdLib: st3play has an OPL2 of its own, so for these files the check is in two parts. The chip is
  checked against Nuked OPL3 itself on streams of register writes. The tune is checked against
  st3play with Nuked OPL3 put in place of its chip. Both agree to the sample.

Comparisons with libopenmpt (files from later trackers):

| What | Files | Result |
|---|---|---|
| Timing by tempo, not whole ticks | 150 picked at random | A 4-minute tune had drifted a second from where it should be, and so from libopenmpt. Spectrum of 45 came nearer (40 of those by more than 0.1, one from 0.60 to 0.97); of 2 went further by 0.003. |
| X, P, Y on the GUS | 159 in the collection | How alike the two sides are rose in 70 and fell in 14 (median from 0.54 to 0.71). |
| Z (filter) | 65 S3M files have Z; only four are of a tracker that had it | Spectrum of each as near or nearer, most of all an FM tune's (from 0.90 to 0.95). |
| S99 (reverb) | 12 ask for it; 10 of a later tracker | GUS: spectrum of nine of the ten nearer (from 0.97 to 0.99 for one); the tenth, whose reverb is on a channel past the sixteen Scream Tracker played, as it was. Sound Blaster, which sounds less like libopenmpt either way: six nearer, two further, two as they were. The other two files Scream Tracker saved, and in those S99 is nothing. |
| Channels past sixteen | 23 in the collection | Spectrum of 11 came nearer (one from 0.76 to 0.97) and of three went a little further (by 0.011 at the most). The loudness envelope came nearer in 15 and went further in one. |

Notes:

- The tenth S99 file (reverb past the sixteenth channel) has 26 channels of samples. It saves those
  after the sixteenth with the numbers Scream Tracker gives the AdLib card's voices.
- Z: OpenMPT tells a tracker that had the filter by the mark each leaves in what it saves. Those
  that say they are Scream Tracker 3.20 and had no filter: Sound Club, PlayerPRO, Velvet Studio.
- Crawling Despair: OpenMPT plays Z00 to Z0F as pan positions in a file from before Scream Tracker
  3.20 whose Z is only ever that.

Damaged and later trackers' files (October 2026): 22 S3M files and 6 IT files siday used to refuse
were compared with libopenmpt.

- **Noughts written over:** 17 S3M files have many of their noughts replaced by one byte.
  `ST3Noughts.swift` puts them back where they are certain, and was checked against a twin of it
  written apart in Python, which mends the file the same way. On the Sound Blaster, against
  libopenmpt playing a copy mended the same way, the loudness envelope is 0.71 to 0.997; on the
  GUS, whose whole ticks drift from libopenmpt's tempo, it is lower.
- **More patterns, 257 places, and IT files of more than 255 samples:** 0.875 to 0.9995.
- 352 S3M, IT, MOD and other files that played before play to the sample as they did.

Nothing to hear, and files cut short (October 2026): every tracker loader refuses a module whose
samples are all missing or silent (`Shortfall.nothingToHear`), and says what a cut file has lost. A
cut-probe of 116 files of 43 kinds, each cut at seven places, finds every cut copy refused or saying
it is cut, but for five whose loss cannot be heard. The whole collection lists the same but for 29
refusals and reasons meant, each of the newly refused files having been silence; 298 files of 46
kinds play to the sample as before.

### STM — Scream Tracker 2, and STX

Based on:

- A port of st2play, which Sergei Kolzun made from the program itself and calls very accurate. Its
  replayer and its mixing are one loop.
- st2play has the replayers of 2.21, 2.24 and 2.3. Version 2.3 is ported, because that is what the
  files in the collection ask for.
- Eight files have arpeggios, and in five of them those are chords of three notes, written as a
  MOD's are.
- Four carry a vibrato on with no value.
- Eleven have samples at 8,192 a second, which is 2.3's number for its C, where the earlier
  versions' was 8,448.
- The arpeggio on a B reads past the end of the note table; st2play's author wrote down what it
  finds there from the program's memory.

Checked against:

- The port agrees with st2play to the sample over half an hour of each of the 63 STM files in the
  collection, on 62 of them. st2play is given empty patterns where a file has none.
- Giving st2play those empty patterns is one of the three things done here that st2play does not do.
- Why Scream Tracker 2 seems not to have saved the empty patterns after a tune's last: eleven of
  these files have such a pattern in their lists.
- One file has a number in the list that is neither a pattern's nor a mark of the end. It is the one
  that differs.
- There are 21 samples whose loop goes round from past their own end, most of them over by one byte.
  st2play brings the end in. `siday --raw file.raw tune.stm`, which writes what st2play makes, a
  sample for each of its own, does so too.
- Loudness, by measure: the median STM file is at the level of the median XM file.

STX:

- The check is of the reading. The two STX files in the collection, one of each of the converter's
  two versions, agree to the sample with st2play for an hour of each. st2play is given the STM file
  that a separate script makes of them.
- OpenMPT plays that STM file as it plays the STX file itself: every voice at the same pitch and
  volume on every tick.

### DSM — the Digital Sound Interface Kit

Decisions:

- The file is read into an S3M file and played by Scream Tracker 3's replayer, on a Gravis
  Ultrasound, following OpenMPT's S3M rules; the three things OpenMPT does otherwise for these files
  are passed to the replayer.
- The file's master volume is left out. In OpenMPT, one of the three files in the collection, which
  asks for its loudness to be found from its count of channels, is seven to twelve decibels quieter
  than the other two.

Checked against libopenmpt:

- Every sample is as libopenmpt reads it, to the last byte of its sound and its loop.
- Every channel's pitch, volume and pan position was compared on every tick of each file, to its
  end. Of 25,984 ticks they are alike on 25,747, counting Scream Tracker's 63 as OpenMPT's 64.
- Of the rest, all but eight are where a sample with no loop ends a tick sooner or later in one than
  in the other (most of them later here). The eight are the first ticks of rows of vibrato.
- The pan positions are the same on every tick.
- A file made for the purpose, with every kind of sample and the commands that are not in the three,
  is alike on every tick but those of a note cut short, which here is silent and plays on.
- What is heard was compared too, for two minutes of each file. The spectrum agrees to 0.991, 0.982
  and 0.925, and the loudness envelope to 0.994, 0.972 and 0.792. The last is the file that moves
  its channels between the speakers all through, to positions the Ultrasound has only near.
- The files are made about as loud as other modules are, by measure.

### MASI — Epic MegaGames' PSM files

Decisions:

- Read into an S3M file and played by Scream Tracker 3's replayer on a Gravis Ultrasound, exactly as
  DSM files are.
- A newer file's songs follow one another in the S3M file's order list, each with the mark for an
  end after it. The replayer is told where each song begins, where it goes back to at its end, and
  its own speed, tempo and pan positions, which it starts with.

Checked against libopenmpt:

- All sixteen files in the collection are played: four of the older kind (the first Epic Pinball's
  and Silverball's) and twelve of the newer (five of Extreme Pinball's and seven of Sinaria's), with
  55 songs among them.
- Every one of their 174 samples is as libopenmpt reads it, to the last byte of its sound, its loop,
  its rate and its volume.
- Every song lasts as long as in libopenmpt, but for a second song libopenmpt finds in the first
  Epic Pinball tune. That is five seconds that lead back into the first, and is not counted here.
- Every channel's pitch, volume and pan position was compared on every tick of every song, to its
  end. The song is at the same row on every tick. The pan positions are the same on every one of
  over half a million channel-ticks.
- Of 113,299 ticks, 112,458 are alike (99.3%), counting Scream Tracker's 63 as OpenMPT's 64. Of the
  841 others, 790 are a sample with no loop that ends a tick later here; 92 are first ticks of rows
  of vibrato and the ticks after them in the one song with much of it; and one is a volume.
- What is heard was compared too, for every song of ten seconds or more, up to two minutes of each
  (34 songs), with libopenmpt's ticks put in step. The spectrum agrees to 0.988 at the median (0.937
  at the least). The loudness envelope agrees to 0.988 (0.791 at the least): where channels play
  together, the Ultrasound's pitches and pan positions, a little apart from OpenMPT's, make them add
  up otherwise.
- The files are made about as loud as other modules are, by measure.

### IT — Impulse Tracker, and ModPlug Tracker after it

Based on:

- it2play's port of Impulse Tracker 2's replayer, and the driver it2play adds to Impulse Tracker's
  own.
- Samples that ModPlug Tracker packed four bits a sample are in 36 files in the collection; it2play
  leaves them silent.

Checked against it2play:

- `siday --raw file.raw tune.it` writes what it2play writes to a file, and the two agree to the
  sample. `--raw` writes every file as Impulse Tracker played it, whatever tracker made it, to
  compare with it2play.
- Files with more than 100 samples, 100 instruments or 200 patterns: there is no reference to check
  them against, since it2play does not play them.
- The filters start open here. The environment variable `SIDAY_REFERENCE_SLIPS` repeats it2play's
  shut filters (when a file's own MIDI settings leave the line blank), for comparing the two.
- The filter is the one place where the web player and the Mac's do not agree to the last bit: each
  asks its own maths library for a power of two.

Which tracker's ways:

- Which filter a file is played with is told by the signs OpenMPT goes by. Of the 21,189 IT and MPTM
  files in the collection that are read at all, there is not one where the two choose differently.
- That filter (ModPlug Tracker's) is heard in 1,236 of the IT files and 215 of the MPTM files.
- Plug-ins: ModPlug Tracker, and OpenMPT before its version 1.17, named an instrument's plug-in in a
  piece of the file of its own, just after the instrument, and that is read too. Most of those files
  say it again where OpenMPT came to say it, but two in the collection do not.
- Envelopes: OpenMPT stops making the first of the three envelope changes (the loop a tick sooner)
  at the first instrument that has anything random in it, in a file from before its version
  1.17.02.50. It leaves the instruments after it as they are. So does siday.
- Pitch: OpenMPT keeps periods for 7,403 IT files in the collection.
- ModPlug Tracker 1.0's files, from before it wrote a version of its own: 117 in the collection.
- Schism Tracker went over to rates on 29 January 2015, or on 2 May 2021 for a song without linear
  slides.
- Panbrello: OpenMPT's way of putting the note back once the panbrello's rows are over is also a
  Schism Tracker's before 9 March 2024. A random panbrello takes a new place every tick in a Schism
  Tracker's until 19 October 2023.
- A note's instrument or sample giving the channel its pan position from then on: OpenMPT did so
  until 1.29, and Schism Tracker until 2 May 2021.
- What such a file says of its instruments, OpenMPT reads from just after whatever of the rest of
  the file ends last, and so it is read here now. It was looked for before by the four letters that
  begin it, which can turn up earlier, in a sample's sound. In eleven files in the collection they
  did, so that those files' instruments were given the wrong plug-ins, filters or ways of being
  interpolated.

Comparisons with libopenmpt:

| What | Files | Result |
|---|---|---|
| Plug-ins | 300 files | Spectrum median 0.983, where without the plug-ins it was 0.960. |
| Sample-end fade 16 times quicker | 400 | Changes most a little; fifteen audibly nearer, none further. |
| Surround | 2,816 files of those two trackers have surround | 680 sound different for it in their first 45 seconds: 426 nearer and 16 further in one way or another. The stereo placement of those 680 is as like libopenmpt's as 0.968 at the median, where it was 0.878. |
| Periods | 534 IT files whose sound that changes in libopenmpt, a sample of the 7,403 | 286 nearer, 25 further in one way or another; spectra median 0.994, where 0.985. |
| ModPlug Tracker 1.0 pitches | the 117 | 66 nearer, 6 further. |
| Older Schism Tracker periods | 470 files | 236 nearer, 23 further; spectra median 0.997, where 0.989. |
| OpenMPT's vibrato, tremolo and sample vibrato | 131 files whose sound that changes in libopenmpt | 44 nearer, 7 further. |
| Zxx in trackers with no filter | six files have it | One sounds different for it. |
| Panbrello | 317 files whose panbrello that changes | 76 nearer, 10 further; stereo placement median 0.985, where 0.974. |
| OpenMPT's other ways (instrument with no note, SCx, Qxy/Ixy, slide to another sample) | 300 files of those two trackers at random | 24 sound different for all that: 10 nearer, 1 further. |
| ModPlug's ping-pong turn, instrument beside a note-off, slide to another sample without compatible Gxx (switches 33, 50, 42) | the 8,974 IT and MPTM files that ask for one of them | 2,147 sound different in their first 30 seconds: 77 nearer, 2 further, the furthest by 0.016 in stereo placement; envelopes median 0.994, where 0.992, and spectra 0.996, where 0.995. Short chip loops change most (one spectrum from 0.67 to 0.99), and their treble is libopenmpt's within a decibel or two. |
| Older OpenMPT's four numbers | 300 such IT files | 37 nearer in stereo placement, 6 further, which with anything random is as near as two playings of one file come. |
| Interpolation | 100 such files; 400 files | The top of the sound (above 12 kilohertz, against what is between half a kilohertz and six) now agrees within a decibel in 80 of 100, where it did in 38. Of 400 files, 5 are audibly nearer and none further. |

- Interpolation choice: 111 of the IT files in the collection make it, most of them for no
  interpolation (406 of the 619 instruments that say).

Filter checks:

- Every sounding channel's filter was compared with libopenmpt's on every tick of a file's first
  minute: whether it is on, and the three numbers it is worked by.
- Of the 215 MPTM files, 186 have nothing random about their filters. In 179 of those the two are
  the same on every tick, give or take one step of 512 in an envelope, which the two round
  differently.
- Of 300 of the IT files taken at random, 295 have nothing random. The two players go through the
  same rows tick for tick in 291 of them, and in 279 of those the filters are the same on every
  tick. What is left is mostly envelopes that carry on, or do not, about a slide to a note.
- What is heard was compared before and after. Of the 300 IT files, 139 are nearer and 9 further; of
  the 215 MPTM files, 86 and 5. The spectrum of the median IT file agrees to 0.981, where it was
  0.975; that of the median MPTM file to 0.994, where it was 0.991.
- A file with a filter moved at random cannot be compared with anything, since no two playings of it
  are alike.

Loudness:

- ModPlug Tracker's own way of adding up leaves such files some 8 dB below the rest.
- Measured over three hundred ModPlug Tracker and OpenMPT files and three hundred others, the median
  file of every way is now within about a decibel of the median IT file, and of the median XM file.
- By how loud they are heard (see the beginning), ModPlug Tracker's own way came out 1.4 dB louder
  than the rest even so, and is turned down by that.
- In an MPTM file, OpenMPT 1.17's way, its compatible one and ModPlug Tracker's are raised by 0.8,
  2.4 and 2.2 dB, which brings the median file of each to the same level.

MMCMP:

- Unpacked as Teemu Suutari's ancient unpacks it, and agrees with it to the byte. The four IT files
  in the collection then play as it2play plays them, and the four S3M files as st3play does, to the
  sample.

### GDM — BWSB and PolyTracker

Based on:

- The loaders are made after libxmp's and OpenMPT's. Where siday's reading differs from libxmp's it
  is by choice; where those two disagree, the source says which was followed and why.

Checked against:

- What was read from every such file in the collection, 56 of them, has been compared with what
  libxmp and OpenMPT read from it.
- What is heard has been compared with libxmp's playing by measure, of the loudness envelope and the
  spectrum. That finds a wrong note or a missing channel, and cannot find a wrong nuance.

### ULT — UltraTracker

Decisions:

- There were two ways to play a ULT file: a small player written for it, as 669 files have, or
  Impulse Tracker's replayer, as for the GDM and PTM files. A player written for it would have had
  nothing of UltraTracker's to be made after, and would have been ProTracker's commands written out
  once more. Every one of those commands is one Impulse Tracker has. So it is Impulse Tracker's
  replayer, with "old effects" on, which is where OpenMPT and Schism Tracker put these files too.
- What is left out for want of room is 31 notes, in five of the files in the collection.

Checked against libopenmpt:

- All 126 files in the collection are played.
- Every channel's pitch and volume was compared with libopenmpt's on every tick of each file, to its
  end or for two minutes. Of 769,384 ticks they are alike on 729,705. 54 files are alike on every
  tick, and 42 more on all but one in fifty.
- The rest come down to three things, below, and to the choices listed in FORMATS.
- One: OpenMPT plays these files on its own replayer, whose vibrato and tremolo are not shaped as
  Impulse Tracker's are.
- Two: OpenMPT's ticks drop the part of a sample that Impulse Tracker's come to, as for 669 files,
  so a tune at any tempo but 125 drifts.
- Three: OpenMPT loses a speed or a tempo that shares a note with another command in the first
  channel. The two files it is furthest from siday are the two it plays at 125 beats a minute where
  they ask for another tempo.
- Audio compared with libopenmpt for the first minute of each file: the spectrum and the loudness
  over time agree to 0.999 for the median file, and to 0.945 and 0.859 for the file a tenth of the
  way up from the worst.
- Level: set by measurement, as loud as XM files.

### MDL — Digitrakker

Based on:

- OpenMPT plays these files on its own replayer, as it plays an IT file, and has been taught what
  Digitrakker does otherwise. libxmp plays them as it plays an XM file, and has been taught less.
- There were two ways to play one here: a small player written for it, which would have had nothing
  of Digitrakker's to be made after, or Impulse Tracker's replayer, as for the ULT and GDM files,
  with what OpenMPT does otherwise given to it. Every command of Digitrakker's has its like among
  Impulse Tracker's, and its instruments are Impulse Tracker's with less in them, so it is the
  second. The file is read as OpenMPT reads it.

Decisions:

- Two commands to a note: what is left with nowhere to go is 291 notes, in five of the files in the
  collection. Nearly all are in one file, which strikes a note again while its volume slides on.
- Volume slides: OpenMPT takes a quarter of each of Digitrakker's slides, to the nearest of Impulse
  Tracker's below and no more than fifteen. So its slides of less than a quarter become slides that
  go on with whatever slide the channel had before. One composer swells notes in from nothing that
  way, which OpenMPT then leaves silent or swells four times too fast. libxmp's reading of the same
  commands is Digitrakker's, by 255ths.
- Tempo below 32: all seven files in the collection that set one set it on the last place of their
  list. So the song ends there, after the row, where OpenMPT reads it as a tempo slide and plays on
  very slowly.
- A note on an instrument the file does not have: eleven files have such notes. siday plays nothing
  there; OpenMPT plays the note on the sample that was playing.
- libxmp's notes on how trackers differ have a column for Digitrakker 3.2, found by trying it, but
  for MOD files and not its own. There, a note on an instrument that is not there cuts the note, and
  a note with no instrument has its instrument's volume again. The second is not how these tunes are
  written. One sets a quiet volume on a note's first row and repeats the note bare on the rows
  after; read as libxmp's column would have it, that would be loud from the second row.

Checked against libopenmpt:

- All 148 files in the collection are played. Every sample is as libopenmpt reads it, packed or not,
  to the last byte of its sound and its loop.
- Every channel's pitch and volume was compared with libopenmpt's on every tick of each file, to its
  end or for fifteen minutes.
- Read as OpenMPT reads them, before the choices that are not OpenMPT's were made, they were alike
  on 1,917,068 ticks of 1,919,629. 98 files were alike on every tick, and all but three of the rest
  on all but one in fifty.
- What was left: a sample that ends a tick sooner in one than in the other, at a note so short that
  it ends on the very tick the next row starts; and the eleven files with notes on instruments they
  have not got.
- As they are played now, 82 files are alike on every tick, and the rest differ where the choices in
  FORMATS make them.
- Audio compared with libopenmpt for the first minute of each file: the spectrum agrees to 0.992 for
  the median file and the loudness over time to 0.974. For the file a tenth of the way up from the
  worst, they agree to 0.907 and 0.737.
- Level: set by measurement, as loud as XM files.

### J2B — Jazz Jackrabbit 2 and the Galaxy Sound System

Based on:

- DEFLATE is in Swift of siday's own (`Packers/Inflate.swift`), made after the decompressor in Teemu
  Suutari's ancient and the two RFCs that describe DEFLATE and zlib's stream. siday uses no library
  of the system it runs on.
- A file is refused unless all of these hold: its header gives its own length rightly; the checksum
  of what is packed is right; what is packed unpacks to exactly the length the header says; and
  zlib's own checksum of what it unpacked to (Mark Adler's) is right. A file shorter than its header
  says is unpacked as far as its stream goes (`Inflate.zlibCutShort`).
- The Galaxy vibrato behaviour described in FORMATS is `IT2Module.playsAsGalaxy`, used for these
  files and no others.

Checked against the system's zlib:

- The unpacking was compared with the system's own zlib on all 24 files in the collection, and on
  5,760 streams made with zlib at every level and in every way it packs. That is: stored, in the
  codes DEFLATE fixes and in a block's own codes, with flushes between blocks, from 0 bytes to a
  megabyte. Every one came out byte for byte the same.
- On some 21,000 damaged copies of those streams, flipped in a few bits or cut short, it refused
  just those that zlib refuses. Where both took one, it made the same bytes.

Checked against libopenmpt:

- All 24 files in the collection are played, none with anything left out. Every sample is as
  libopenmpt reads it, to the last byte of its sound, its loop, its volume and its rate.
- Every channel's pitch and volume was compared with libopenmpt's on every tick of each file, to the
  end of its song. All 145,348 ticks are alike, the rows coming in the same order and lasting as
  long.
- On 98.5% of a voice's ticks the rate is the same to the hertz, and on 99.97% within one, which is
  the rounding of the two dumps. The volume is the same on 99.99%. The pan position is the same on
  98.2%; the rest is one file's voices in surround, which the two players mark differently.
- The songs last as long as libopenmpt says they do, to the second.
- Audio compared with libopenmpt for the first minute of each file: the spectrum agrees to 1.000 for
  the median file and 0.999 for the worst, and so does the loudness over time.
- Level: set by measurement, as loud as other modules (the median file at −24.7 dB), which is 1.5 dB
  quieter than libopenmpt plays them.
- Level: made as loud as other modules by measurement, 1.5 dB quieter than libopenmpt plays them.

### DMF — X-Tracker

Based on:

- libxmp's reader of these files is no longer built. OpenMPT's reading is followed to the letter.

Decisions:

- What is left with nowhere to go is 358 notes, in twelve of the files.
- The two commands Impulse Tracker has not: a note's volume given by the command, where the volume
  column has something else, is 504 notes in seven files. A note tuned by up to a semitone either
  way: one file tunes 720.

Checked against libopenmpt:

- All 32 files are played. Every sample is as libopenmpt reads it, packed or not, to the last byte
  of its sound and its loop. Every pattern for every place in the list is the same, command for
  command, as OpenMPT's reading of it.
- Every channel's pitch, volume and pan position was compared with libopenmpt's on every tick of
  each file, to its end or for fifteen minutes. They are alike on 927,707 ticks of 938,569, and 22
  files on every one.
- Of the rest, 5,728 are in the two files where the scratched notes keep their loop.
- Most of the others are long pitch slides. Here they move a whole number of samples a second each
  tick, as Impulse Tracker's do, where OpenMPT's keep finer steps. So after a long slide to a low
  note the two are a few cents apart.
- A few dozen are a sample that ends a tick sooner in one than the other.
- Audio compared with libopenmpt over the whole of each file: the loudness over time agrees to 0.999
  for the median file and 0.992 for the worst, the spectrum to 0.999 and 0.994, and left and right
  to 0.999.
- Level: set by measurement, as loud as IT files.

### PLM — Disorder Tracker 2

Checked against libopenmpt:

- All four files in the collection are played. Every sample is as libopenmpt reads it, to the last
  byte of its sound and its loop.
- Every channel's pitch, volume and pan position was compared with libopenmpt's on every tick of
  each file, to its end. Of 34,761 ticks they are alike on 34,745, and three files on every tick.
  The other sixteen are where a sample ends on the very tick a row starts, sooner in one than in the
  other. The pan positions are the same on every tick.
- A file made for the purpose, with the slides, the starts and two patterns laid across each other,
  is alike on every tick.
- Audio compared with libopenmpt for the first twenty seconds of each file: the spectrum agrees to
  between 0.985 and 1.000, and the loudness over time to between 0.959 and 1.000.
- Over two minutes they agree less well, because OpenMPT's ticks are a whole number of samples and
  Impulse Tracker's replayer's are not. At a tempo of 144 a tick is 833 samples to OpenMPT and 833⅓
  here, and the two are 40 ms apart by then.
- Level: set by measurement, about as loud as other modules.

### MPTM — OpenMPT

FM instruments, checked against libopenmpt:

- OpenMPT's own chip is another emulator of the same chip, so the sound is not its sound to the
  sample. But what is set in the chip's registers can be compared, and was, tick by tick, for the
  first minute of every such file.
- Of the notes sounding in libopenmpt, 99.98% are sounding here with the same patch.
- Their pitch is the same number in 91% of ticks, within two of the chip's steps in 99.2%, and
  within two hundredths in 99.8%.
- The level of the operator that is heard is within one step of 63 in 99.6%.
- Much of what once differed was not the chip's doing but the replayer's. It has been made OpenMPT's
  way for these files, for samples as much as for the chip (the three things listed in FORMATS).
- What is left is mostly a step of rounding, and a note given another of the chip's voices than
  OpenMPT gives it.

Plug-ins:

- Each of OpenMPT's built-in plug-ins that siday has is carried over from OpenMPT's own.
- All but the last of them in the list in FORMATS (Symphonie's echo) were compared with OpenMPT's.
  Given the same sound and the same settings (every setting that the files in the collection keep
  among them), each gives what OpenMPT's class gives, to the last bit, when that is built to round
  as Swift does.

ModPlug Tracker's reverb (S99):

- Carried over from OpenMPT's, and compared with it as the plug-ins were. Given the same sound, in
  every one of its twenty-nine rooms and at four rates, it gives what OpenMPT's gives to the last
  bit.
- Of the 196 files in the collection that use it, the sound of 78 comes nearer to libopenmpt's by
  its spectrum, and 2 go further. Their two sides come nearer in 109 and go further in 9.

Tunings:

- The scale's pitches are worked out in OpenMPT's own arithmetic, and compared with libopenmpt tick
  by tick. In the nine files in the collection with tuned instruments, the notes of those
  instruments are within a cent of it on 99.95% of their ticks or more. The rest is one tick, where
  a song comes round to its start.

Interpolation:

- Of the 700 files, 201 choose for the song, 108 of them no smoothing at all. The sinc had turned
  these into something much duller than their composers heard: a tune of samples made at eleven
  kilohertz kept forty decibels less of its top.
- Compared with libopenmpt, the top of the sound (measured as in the IT notes) now agrees within a
  decibel in 78 of 100 files, where it did in 45, and within three in 93, where it did in 70. Of the
  700, 27 are audibly nearer and 2 further, by a little.

OpenMPT's own ways of playing:

- Pitch as a period is how OpenMPT played a song before its version 1.24, or before 1.30 for a song
  without linear slides. Compared with libopenmpt tick by tick, the pitch of those 73 files is
  within a cent of it on 99.7% of their ticks, where it was 45%.
- Pitch in hertz: of those 624 files, 488 are now within a cent of libopenmpt on 99.9% of their
  ticks or more, where 374 were. 26 are audibly nearer it and none further. Most of what is left is
  a vibrato with a random wave, which no two playings agree on.

Checked against libopenmpt, OpenMPT's own player as a library:

- Of 700 files, 699 are played; one is refused for keeping its samples in other files.
- What is read from each of 625 files is the same as what libopenmpt reads, but for a fade and a pan
  position that the extras give more finely than an IT file's instrument can hold.
- Where the tune is on every tick, and how many frames the tick lasts, is the same for ten minutes
  or to the song's end in every one of them, and in the 67 with FM that have been played since: 692
  files in all.
- One was out for a long time: a tune made as a puzzle, with a pattern in which every row jumps to
  the row before it, and loops within loops on the rows it comes back to. A row played again was
  taken for the tune coming round, and the tune ended fifty seconds early. Now a row played while a
  loop is counting down is the same row again only if the counts are the same too, which is how
  OpenMPT tells a tune's end.
- Audio compared with libopenmpt as it plays, plug-ins and all, by the same two measures as above,
  for the first minute of each file:

| Files | Spectrum, median file | Spectrum, file a tenth of the way up from the worst |
|---|---|---|
| no plug-ins | 0.997 | 0.976 |
| plug-ins all OpenMPT's own | 0.994 (0.972 without the plug-ins) | 0.959 (0.894 without the plug-ins) |
| a plug-in that is left out, which libopenmpt leaves out too | 0.997 | 0.979 |
| with FM | 0.984 | 0.957 |

- The rest of the difference is a pitch that OpenMPT rounds where Impulse Tracker does not, and
  whatever an instrument does at random.

### MO3 — Un4seen's packed modules

Based on:

- libopenmpt 0.8.9's `soundlib/Load_mo3.cpp` (Johannes Schultz and OpenMPT's developers, from the
  UNMO3 project's documentation and unpacking by Laurent Clévy): the container, the LZ unpacking, the
  music, and every kind of sample (raw, delta, delta prediction, duplicates, OPL patches, MP3 with
  the LAME frame and encoder delay taken off, Ogg Vorbis with and without a shared header).
- `MO3Read` reads into an OpenMPT-like model (`MO3Song`); `MO3WriteIT`, `MO3WriteXM` and `MO3Writers`
  write it again as an IT or MPTM, an XM, or an S3M, MOD or MTM, as OpenMPT's own savers lay those
  out. Effects go back through OpenMPT's `S3MSaveConvert` and `ModSaveCommand`. An OMPT chunk's XTPM
  and STPM are copied after the last sample; plug-ins are written as FXnn and CHFX pieces.
- **Which tracker:** a VERS chunk's cwtv/cmwt or XM tracker name is written back. Without one, an IT
  with the ModPlug flag is written with ModPlug Tracker 1.09–1.16's signs (17 files); other ITs as IT
  2.14; an XM with FastTracker 2's. An IT is written as MPTM when its cwtv is 0x0889 to 0x08FF and it has
  an OMPT chunk (5 files).
- Sizes a file states are bounded by what its data can hold; pattern cells are capped at 2^23.

Checked against libopenmpt, built with minimp3 and stb_vorbis, `-ffp-contract=off` and
`MINIMP3_NO_SIMD`, which loaded each MO3 and each rebuilt module:

- All 149 collection files unpack, and every rebuilt module loads in libopenmpt and in siday (149 play
  under `--check`, none silent).
- 8,458 of 8,469 samples are the same bytes. The other 11 are one MOD's (elevator_2) MP3 samples, which
  the MOD format brings to eight bits.
- 37 files are the same field for field. Every difference in the other 112 is one that the format the
  module is written in, or libopenmpt's reader of that format, makes: its own mix levels and pre-amp
  (82 files), no pitch and pan centre in an XM (60), one pitch-wheel depth (51), the Zxx macros cleared
  by FastTracker 2's and Scream Tracker's readers (34), MOD Amiga limits by libopenmpt's own guess (21),
  read as ModPlug Tracker made it (17), and a few of one file each.
- Rendered over 60 s: 50 the same to the bit as they are; 139 of 149 with the MO3's global settings put on
  the rebuilt module. The other ten are the ModPlug-read files, a panning rounding in an S3M and an IT,
  and the eight-bit MOD.
- 331,500 spoilt files, synthetic and real: no trap; at most 0.16 s and 78 MB each. All 149 unpack in
  11.2 s in release.
- MTM is checked only on a file made for the test: the collection has no MO3 made from one.

### MT2 — MadTracker 2

Based on:

- OpenMPT's loader (Olivier Lapicque's, from ModPlug Tracker's days) is the only other reader of
  these files. Nothing else is to be found, libxmp and Schism Tracker included, and nothing of
  MadTracker's own about the format beyond the names that OpenMPT's loader gives.

Decisions:

- Commands with no place: in 15 of the files, 2,552 are left out, as OpenMPT leaves them out.

Checked against libopenmpt:

- All 106 files in the collection are played. The two are at the same place on every tick, with
  every tick as many frames long, for ten minutes or to the song's end, in every one of them.
- Every channel's pitch and volume on every tick of the first two minutes: of 826,682 ticks they are
  alike on 816,966. 53 files are alike on every tick and 43 more on all but one in fifty.
- Most of what is left is the reference's own way of looking, which loses a voice for a tick at the
  turn of a loop. In the rest, in two files a slide to a note starts from where libopenmpt has put
  the pitch back, for a reason not found in its code.
- Audio compared with libopenmpt for the first minute of each file: the spectrum agrees to 1.000 for
  the median file and 0.999 for the file a tenth of the way up from the worst, the loudness over
  time to 1.000 and 0.996, and left and right to 0.999 and 0.992.
- The furthest is a file that stacks fifty voices of the same short wave a hair apart in pitch.
  Which of their overtones cancel at any moment depends on how their phases have drifted, and comes
  out otherwise.
- Level: played as loud as OpenMPT plays them, the median file is 4 dB quieter than the median XM
  file. The files are made as loud as XM files are.
- Level: played as loud as OpenMPT plays them, the median file is 4 dB quieter than the median XM
  file; siday brings the files to XM files' level.

### SYMMOD — Symphonie and Symphonie Pro

Based on:

- OpenMPT's loader of these files (Devin Acker's and the OpenMPT developers', after Patrick Meng's
  own player in Java and Symphonie's Amiga source).
- OpenMPT's echo for Symphonie's is `OpenMPTSymMODEcho`.
- Every sample is made as OpenMPT makes it, through its readers of those kinds of sound file, its
  filters and squashing, to the last bit. The virtual instruments go through a copy of its mixer at
  its straight lines between points.
- A channel's sample stopped where it is and let go on from there: 31 of the 35 files do this,
  93,672 times in all.

Checked against libopenmpt 0.8.9:

- All 35 files in the collection are played. Every sample is as libopenmpt makes it, to the last bit
  of its sound, its loop, its rate and its volumes, the 19 virtual instruments of four of the files
  among them.
- Every cell of every pattern, and the list of patterns, are what OpenMPT makes of the tracks. The
  place in the song, and the length of each tick, are the same on every tick of each file, to its
  end or for ten minutes.
- Every channel's pitch and volume were compared with libopenmpt's on every tick of the first three
  minutes of each file. They agree on 307,271 ticks of 307,308; the rest are a sample that ends
  within the first frame of a tick.
- The pitches agree to the hertz on 94 voices' ticks in a hundred, and are a hertz apart on the
  rest. The replayer keeps a pitch in whole hertz, and OpenMPT's rounding is now and then the other
  way.
- Audio compared with libopenmpt's sound for the first minute of each file: the spectrum agrees to
  1.000 for the median file and to 0.996 for the worst, the loudness over time to 1.000 and 0.996.
  In the worst, a low note held through the echo is a hertz apart, and its echo meets it a little
  otherwise.
- Clicks, millisecond by millisecond, in the first minute of each file: 59 milliseconds in all have
  a sharper step in the sound than libopenmpt's has there (by three times or more). There were 1,763
  before two changes: what a stopped sample last put out was let die away, and what is left of the
  voices that end on their way to the echo was let die away as quickly as OpenMPT lets it.
- Level: set by measurement, about as loud as other modules, which is 2.3 dB louder than OpenMPT
  plays them.

### IMF — Imago Orpheus

Based on:

- OpenMPT's reading and playing of the format. OpenMPT's loader was Storlek's, for Schism Tracker,
  first. libxmp and MikMod also read these files.
- Played by the Impulse Tracker replayer, keeping time as OpenMPT does (as for an MPTM file), told
  where OpenMPT's player asks whether a file is an IT file and goes another way for these files.

Command conversion, as OpenMPT makes it:

- A fine slide of volume becomes a slide with F for its other half.
- A fine slide of pitch becomes an Exx or Fxx of Ex or Fx.
- The filter's cutoff becomes Zxx (the other way up), and its resonance Z8x.
- The commands that are X followed by a letter become the S commands that do the same.
- Two commands to a note: one goes into the volume column if either can go there; otherwise the one
  that matters more by OpenMPT's reckoning is kept, and the other is left out and the file says so.
  Two of the twelve files in the collection have 65 such, as many as OpenMPT leaves out.
- An offset beside another command that has the command's place becomes the volume column's coarser
  offset, as OpenMPT has it.

Checked against libopenmpt, all twelve files in the collection:

- Every sample is read byte for byte the same.
- For ten minutes or to the song's end, in every file, the two are at the same place on every tick,
  with every tick as many frames long.
- Every channel's pitch and volume on every tick, over the same span: of 116,165 ticks they are
  alike on 115,793, and every file on all but one in fifty.
- What is left is mostly the reference's own way of looking, which loses a voice for a tick at the
  turn of a loop or just before a sample ends.
- In one file, an instrument is named alone on the very tick its sample has run out. OpenMPT, having
  not yet seen it end, does not start it again, as Impulse Tracker does.
- Audio compared for two minutes of each file:

| Measure | Median file | Worst |
|---|---|---|
| Spectrum | 1.000 | 0.999 |
| Loudness over time | 1.000 | 0.993 (the file a tenth of the way up from the worst) |
| Left and right | 0.999 | 0.990 |

- The worst file for loudness over time, 0.789, is a short tune of a steady loudness, whose small
  changes are all there is to compare.
- The octaves from 63 hertz to 16,000 are in the same balance to within half a decibel, but the
  highest of one file, by 0.7.

Level:

- Played as loud as OpenMPT plays them, the median file is 1.7 dB quieter than modules of other
  kinds are made. The files are made louder by that much, keeping each file's own mixing volume and
  master volume.

### AMS — Velvet Studio and Extreme's Tracker

Based on:

- OpenMPT's own loader for both kinds, and its playing: read into the shape of an IT file with "old
  effects" and "compatible Gxx" on, played by Impulse Tracker's rules but where OpenMPT's player
  asks whether a file is an IT file (as for IMF).

Command conversion, as OpenMPT makes it:

- ProTracker's commands by their meaning.
- Velvet Studio's own by what OpenMPT makes of them: extra fine slides of pitch, a channel's volume,
  a pattern break in hexadecimal, fine slides of volume of twice the precision (forwards and
  backwards), the global volume and its slide.
- A note's commands are put into its cell one after another. Each new one is joined to the one
  before where they can be (a slide of volume beside a vibrato or a slide to a note that goes on as
  it was). Else the one that matters more by OpenMPT's reckoning keeps the command's place, and the
  other goes to the volume column if it is free and can, and is otherwise left out.
- Four of the eight files have such left-out commands, 1,727 in all, the most of them in one file
  whose cells have up to four commands. Each file says how many.

Sample and instrument details, as OpenMPT works them out:

- The samples' volumes, of 127, become Impulse Tracker's of 64, to the nearest.
- A sample's rate is from its rate for C-4, its finetune and its "relative tone".

Checked against libopenmpt:

- Extreme's Tracker files were checked only with files made for the purpose, as none is in the
  collection. Compared with libopenmpt they read the same samples, packed and not, and play the same
  notes but for C-10, which is played a semitone lower.
- All eight Velvet Studio files in the collection: every sample is read byte for byte the same,
  shadows and packed samples among them.
- For ten minutes or to the song's end, in every file, the two are at the same place on every tick,
  with every tick as many frames long.
- Every channel's pitch and volume on every tick, over the same span: of 96,745 ticks they are
  alike on 96,590, and seven files of the eight on all but one in five hundred.
- What is left is mostly the reference's own way of looking, which loses a voice for a tick at the
  turn of a loop of a short sample. One file has many of those.
- Audio compared for two minutes of each file:

| Measure | Median file | Worst |
|---|---|---|
| Spectrum | 1.000 | 0.999 |
| Loudness over time | 1.000 | 0.995 |
| Left and right | 1.000 | 0.995 |

- The octaves from 63 hertz to 16,000 are in the same balance to within half a decibel.

Level:

- Played as loud as OpenMPT plays them, the median file is 3.7 dB quieter than modules of other
  kinds are made, and the files are made louder by that much.

### 669 — Composer 669 and UNIS 669

Based on:

- No port: the player is written from the descriptions that came with the two programs and from
  what OpenMPT and libxmp make of such a file.
- The numbers (slide steps, trill) are OpenMPT's, whose authors compared their player with Composer
  669 itself running in an emulator. libxmp has the same ones.
- The mixer is the player's own: a curve through each four samples, at the output's rate.

Checked against libopenmpt, on all 164 files played, every tick, to the end or for ten minutes:

- The two are never at different rows, but for the one row of the one file where OpenMPT's speed
  comes late.
- Every channel's pitch and volume: of 901,749 ticks they are alike on 894,484. Every one of the
  rest is one of the three choices (trill, slide to a note, pattern speed), or the last tick, where
  libopenmpt stops and siday goes round.
- Audio compared for the first minute of each file. With the ticks made the length libopenmpt makes
  them, the spectrum and the loudness over time both agree to 1.000 for the median file, and to
  0.999 and 0.998 for the file a tenth of the way up from the worst.
- With the ticks their own length, a minute of music drifts apart by a sixtieth of a second, and the
  same measures come to 0.992 and 0.966. That says more about the measure than about the sound.

Level:

- The files are made as loud as XM files are, by measure: the median one of each is the same.

### C67 — Composer 670

Checked against libopenmpt, all 34 files in the collection:

- The two are at the same row on every tick, and alike on 212,060 ticks of 216,154.
- The rest are the ends of samples, the tick on which a tune comes round, and the highest FM notes,
  which OpenMPT keeps as periods too coarse for them.
- What is heard agrees to 0.96 for the median file, the two having different emulations of the chip.

### FAR — Farandole Composer

Based on:

- The description of the file that came with the program, and libxmp, whose authors compared their
  player with the program itself and wrote down what they found.

Checked against libxmp, every tick of the 37 files in the collection:

- The two are never at different rows, and 32 files are alike on every tick.
- In four of the rest, a note ends a tick sooner in one than in the other.
- In the fifth, a slide to a volume starts from the volume the channel has, as the program's
  description says, where libxmp starts it from the loudest.

### CMF — Creative's music files

Based on:

- SBFMDRV, by way of fmdrv's port of it to C.

Checked against fmdrv:

- `siday --raw file.raw tune.cmf` writes the chip's own samples, at its own 49,716 a second.
- They agree to the sample with fmdrv playing on Nuked OPL3, on all 932 files in the collection,
  from end to end.

### ROL — AdLib's Visual Composer

Based on:

- AdLib's own sound driver, as AdPlug has it from the code AdLib gave programmers.

The built-in bank:

- `swift Scripts/pack-bank.swift` makes the table from bank files.

Checked against AdPlug:

- `siday --raw file.raw tune.rol` writes the chip's own samples, as for a CMF file.
- Of 1,509 ROL files tried, 1,479 find every instrument in the built-in bank and 30 are left with
  one, two or three that no bank in the collection has. The `--raw` samples agree to the sample with
  AdPlug's ROL player on Nuked OPL3, given the same bank, on every one of those files.
- AdPlug refuses a ROL file that has no bank beside it, and wants one bank to have everything.

### FMT — FM Tracker

Based on:

- OpenMPT's loader for the format (by someone who wrote songs in the tracker), and what OpenMPT then
  does with the song.

Checked against OpenMPT:

- For the four songs in the collection, and for files made to try every note, every register the
  player sets, and the tick it sets it on, is what OpenMPT sets.
- What is heard can be held to OpenMPT only by measure, since OpenMPT plays FM on another emulation
  of the chip. Tick by tick, the two are as loud as each other to within a third of a decibel for
  half the ticks, and one decibel for nine in ten. Their spectra keep close.

Level:

- Turned down by half, by measure, to be as loud as CMF and ROL files.

### MID — Standard MIDI Files

Based on:

- `SidayMIDI`, a module of its own: reading Standard MIDI Files and RMID (`MIDIFile`), the sequencer
  (`MIDISequencer`: libADLMIDI's timing and loops, and a prelude of the sysex kept beside a file),
  and what a file was written for (`MIDIStandard`, `MIDIOrigin`). A synthesiser takes the messages
  through `MIDIReceiver`.
- The FM synthesiser in `SidayEightBit/MIDI`: a port of libADLMIDI's MIDI player and OPL3 driver
  (`ADLMIDISynth`), with The Fat Man's bank (`FatManBank`), played by `MIDIFMRenderer`.
- `SidayMT32`, a module of its own with no Foundation: the port of Munt's mt32emu, played by
  `MIDILA32Renderer` for files written for the MT-32 when the ROMs are kept (`MT32ROMSet`,
  `LoadOptions.mt32ROMs`). `MT32Tables.swift` holds libmt32emu's own tables as numbers it printed, so
  they are the same on every platform whatever its maths library.
- `SidaySC55`, a module of its own with no Foundation: the port of Nuked SC-55 (`SC55MCU`: the
  H8/532, its timers, serial port and interrupts; `SC55Instructions`: upstream's original
  interpreter, `mcu_opcodes.cpp`; `SC55PCM` and `SC55PCMLoop`: the PCM chip; `SC55ROMs`: the digests;
  `SC55Synth`: the start, bytes by frame, rendering and parts), played by `MIDISC55Renderer` for every
  file the MT-32 does not take when the SC-55's ROMs are kept (`SC55ROMSet`, `LoadOptions.sc55ROMs`;
  `MIDISynthesiser.choose` decides). Its 64 kHz is brought to 48 kHz by `SidayCodecs.Resampler`.
  Firmware 1.21 keeps the part of each PCM slot at static RAM 0xA318 + slot, in GS block order: found
  by playing notes on known channels and reading the RAM.
- Kept files: `KeptFile` and `KeptFiles` in SidayPlayer know a file by its contents (an MT-32 ROM by
  Munt's SHA-1 table, an SC-55 ROM by Nuked SC-55's SHA-256 table, song lengths by reading them); `KeptFileStore` in SidayFiles is the folder they
  are kept in (`Application Support/siday/Kept` for the command line, the app container's for the
  app); the web player keeps them in IndexedDB (`siday-kept`). `$SIDAY_KEPT` names a folder that is
  read for one run, never written.

Checked against libADLMIDI 1.6.2.1, built with a log of its writes to its Nuked OPL3:

- Same bank, same volume model, same chip; the writes over the first minute. 107 of 110 files write
  the same registers at the same chip samples. In two, 19 of about 11,000 writes land a sample apart,
  where libADLMIDI's own output loop lets its chip catch up. In the third, the last write differs,
  where siday goes back to the song's loop.
- libADLMIDI's chip runs one sample behind its output; siday leaves the chip's first sample unmade.
- What each file was written for was checked on the pairs of the same games' music kept in two
  versions (the Wing Commanders, Ultima VII, Leisure Suit Larry 3, Space Quest 1 and others): no
  General MIDI copy is taken for the MT-32's, and every MT-32 copy whose setup is in it or beside it
  is taken for the MT-32's. 62 MT-32 rips with no setup anywhere are left as saying nothing: no sign
  in their notes alone tells them apart well enough (the best, the MT-32's timpani as program 112, is
  in 64% of MT-32 rips and 3% of General MIDI files).

Checked against libmt32emu 2.8.3, built with `-ffp-contract=off`, by a harness that takes siday's
messages (`MIDILA32Renderer.eventLog`: the sample at 32 kHz and the bytes) and renders them with the
integer renderer, analogue mode ACCURATE, DAC input GENERATION2, MIDI delay DELAY_SHORT_MESSAGES_ONLY,
the "nice" amp ramp, panning and partial mixing off, and 32 partials:

- 49 whole songs (Sierra's rips, the Wing Commanders, Ultima VII and Serpent Isle, with their setups
  in the file or beside it) are the same, sample for sample. (That was before songs were heard from
  just before their first note. What is heard since is the same output with the unheard start cut
  off: checked on all 49 and on 23 files on FM. Where the music starts is found with each moment's
  events in the file's own order, `MIDIFile.Order.asWritten`: libADLMIDI's order, which siday plays
  them in, puts a note after the all notes off that stops it at the same moment.)
- The MT-32's renderer always renders blocks of 1,024 frames, whatever it is asked for: mt32emu draws
  random numbers for each partial's timer as it renders, partial by partial, so its sound depends on
  how much is rendered at a time. The harness renders the same blocks.

Checked against Nuked SC-55, J.C. Moyer's fork at 66d12727cc43 (0.8.0) built with
`-DNUKED_ENABLE_DECODER2=OFF`, by a harness on its back end that takes siday's bytes
(`MIDISC55Renderer.eventLog`: each byte with the output frame it is posted before, counted from the end
of the start), runs `SC55Synth.startSteps` (1,666,667) steps first, posts the bytes due before each step,
and writes the back end's frames at 64 kHz (`MIDISC55Renderer.rawLog` is siday's side, before resampling):

- 50 whole files (capped at ten minutes) are the same, sample for sample: Roland's GS files from
  bestmid, GS and General MIDI pop files, the games' General MIDI versions (the Wing Commanders, Ultima
  VII and VIII, Daggerfall, System Shock, The 7th Guest), four XG files and three MT-32 files with
  SCMODE's setup.
- The fork's own decoder ("decoder2", its default) is not the same as upstream's on the SC-55: it
  raises no address errors, and firmware 1.21 makes one as it starts (a word read at 0xAB15, MCU step
  594,398), whose handler is an RTE. siday follows upstream's interpreter, so compare with decoder2 off.
- Nuked SC-55 gives the same output for the same input whatever the block size, so siday's renderer
  needs no fixed blocks.

Level:

- FM: measured over the first minute of 100 files, as loud as CMF files.
- MT-32: no gain. The same files are about 2 dB louder on it than on FM, between CMF files and the
  rest of the FM MIDI files.
- SC-55: 1.68 (+4.5 dB), the median gap to FM over the first minute of 60 files (−24.9 LUFS against
  −21.4). One of them, Ultima VII's "Arrival", touches full scale for a few hundred samples.

### VGM — what was written to the chip, and when

History:

- From 16 October 2026, a Sound Blaster Pro's two OPL2s are brought most of the way together (a
  fifth of the difference kept; `--sb-pro-separation`, 100 being the card's own).
- The AY-3-8910, the YM2612's DAC streams, the SN76489 and the SAA1099 are played from 16 October
  2026.
- Until 16 October 2026, the second of two chips, a Sound Blaster Pro's most often, now and then lost
  a sample or two of its own between writes. That was where the first had made more than the player
  asked of it, so the second came to its writes a little early. It drifted from them a sample at a
  time, from the first second of a tune, until it was kept in step.

Timing:

- A write that comes at a moment is made before the first of the chip's samples at or after it. The
  chip runs at its clock over 288, or over 72 for the two before the OPL3, in whole samples a
  second, as libvgm runs it.
- Writes that come together each land a little after the one before, as on the chip itself, where
  each took a moment.
- Each chip keeps its own time, in its own samples, and the chips go on together: the next writes
  are made when every chip has made all it was given before them.

Checked, OPL chips:

- `siday --raw file.raw tune.vgz` writes the chips' own samples. They agree to the sample with the
  original Nuked OPL3, given the same writes at the same moments, on 99 files of every kind, the
  Sound Blaster Pro's pairs among them.
- libvgm, Valley Bell's player of the format, makes nearly the same: the same notes and the same
  sound (spectrum 0.998, loudness over time 0.999, for the median of 61 files). But it does not put
  writes that come thick and fast at quite the same moments, and is not even the same as itself,
  since where it puts those depends on how much sound it is asked for at a time.
- In one file in the collection, libvgm leaves out the louder chip the file asks for, which siday
  gives it, as the format has it.

AY-3-8910 (PC speaker):

- libvgm plays it on emu2149, a different emulation. The two make nearly the same: spectrum 0.995 a
  window and 1.000 a song, the median of 30.
- They part a little where a tune's notes are deep, as in Skate or Die!'s Downhill Race, whose bass
  is at 58 to 87 Hz. siday's AY chip takes out what is steady over 1,024 samples, a 47th of a
  second, as it does for every AY tune, so that bass is up to 2 dB softer.

YM2612 DAC (Sound Blaster samples):

- Compared with libvgm, whose YM2612 is Genesis Plus GX's: the DAC alone is as loud as it from
  moment to moment to within 0.2 dB for half the time, in each of four files. The whole files are
  within 0.08 dB for half the time, the median of 34.
- These files ask to be louder than most, by 5.6 to 8.8 dB, and are.

SN76489:

- A Swift port of MAME's emulation, which is the one libvgm plays it on.
- Compared with libvgm, the 18 files have the same notes and noises (spectrum 0.999 a window, the
  median of 18). They are as loud from moment to moment to within 0.06 dB half the time.
- With the chip at libvgm's level they were within 0.1 dB of it, all but the one with an FM chip as
  well, which libvgm turns down as a whole.
- In 688 Attack Sub's, which plays samples, the samples alone and the music alone are each within
  0.04 dB of libvgm half the time, but together only within 0.6 dB, for a reason not found.
- King's Quest II's files ask to be 11.5 dB quieter than libvgm plays the chip, and others to be
  louder. siday has the chip 5 dB under libvgm's level, where the median of them is as loud as the
  rest.

SAA1099:

- A Swift port of SAASound (Dave Hooper, with Simon Owen). siday steps it at its clock over 128, as
  libvgm does, and band-limits it.
- Channels swing either side of nought: with the chip's own outputs, from nought up, the thump the
  card's filter let through was 11 to 14 dB of the lowest sound, compared with libvgm.
- Offsets: SAASound holds an offset written to an oscillator on its own for a half more of a wave.
  SAASound's author asks in its code whether the chip really does that. It put a tune of many writes
  2 dB from libvgm, which takes a write up at once.
- libvgm's own emulation of the chip is Valley Bell's, checked against recordings of the chip by
  NewRisingSun. libvgm has MAME's as well.
- Compared with Valley Bell's, siday is within 0.5 dB of it from moment to moment half the time, and
  its spectrum 0.992 a window, the median of 13 files of the 98 in the collection. That is as near
  as libvgm's two are to each other (0.6 dB).
- Level: as loud as the rest by the median of the 98.

Level:

- VGM files are turned down by 6 dB more than the other music for the chip, by measure, to be as
  loud as it is.
- The PC speaker's files, one channel of the AY chip, are turned up by 3.4 dB more than an AY tune,
  since only one of its three channels plays.

### OGG — recordings: Ogg Vorbis, MP3 and WAV

Based on:

- **Ogg Vorbis:** a port of stb_vorbis 1.22 as libopenmpt 0.8.9 builds it, push-data API only
  (`STB_VORBIS_NO_PULLDATA_API`, `STB_VORBIS_NO_STDIO`). `VorbisFile` adds the walk over pages, chained
  links played one after another while their channels and rate match, and each link cut to its last
  granule. It goes on past errors, as stb resynchronises at the next good page.
- **MP3:** a port of minimp3 as OpenMPT's fork has it, all three layers, scalar code (as
  `MINIMP3_NO_SIMD`), with float and int16 output. `MP3File` follows `minimp3_ex.h`'s
  `mp3dec_load_buf`: ID3v2, ID3v1 and APE tags skipped, the Xing/Info frame and the LAME delay and
  padding taken off. Its `length` walks every frame's header and side information without decoding.
- **WAV:** written for siday. PCM of 8 (unsigned) to 32 bits, floats of 32 and 64, A-law, μ-law, IMA
  ADPCM and Microsoft ADPCM, `WAVE_FORMAT_EXTENSIBLE`; a `fact` chunk trims an ADPCM file's last block.
- **`RecordingRenderer`:** a Kaiser-windowed sinc (β 9, 64 input samples either side of each output
  sample, more when the rate is brought down), one row of weights for each place between two input
  samples where the ratio of the rates allows (44.1 kHz to 48 kHz is 147 to 160), else 2,048 rows
  read between. Notes struck are found where a voice's power over about a hundredth of a second rises
  past four times its power over about a third of a second.

Checked against:

- **Ogg Vorbis:** every float bit, and every call's bytes taken and samples given, the same as stb_vorbis
  built with `-ffp-contract=off`: all 779 collection files (44.1 kHz stereo, none chained), the 2,150
  Vorbis streams cut from the 149 MO3 files (461 of them with a shared header), and 501 more made or
  patched (other encoders, 8 to 48 kHz, 3 to 16 channels, all 36 pairs of block sizes). 28,000 spoilt
  files give what the C gives, but for 18 where the C crashes after a failed allocation, and for comments
  that are not UTF-8. Lengths agree with
  ffmpeg's on 778 of 779 files: `Sim_City_CDTV_CDDA/15_Ingame.ogg` has a page with a bad CRC, which
  ffmpeg drops and stb decodes. Against ffmpeg's libvorbis the sound differs by -155 dBFS rms at the
  median, -138.5 at worst.
- **MP3:** every sample the same as minimp3 built with `-ffp-contract=off -DMINIMP3_NO_SIMD`, in floats
  and in int16, and `MP3File` the same as `mp3dec_load_buf`: the collection's 4 MP3 files and its MP2,
  40 files made with LAME and ffmpeg (CBR, VBR, ABR, mono, middle/side, CRC, free format, every rate
  from 8 to 48 kHz, layer II), the MPEG data of all 149 MO3 files, and 435 made-up streams of every
  layer and mode, which reach intensity stereo and short blocks at every rate. 7,700 spoilt files run
  under the address sanitizer. From the NEON build the floats differ by at most 4.8e-7, from one sum
  made in another order, and int16 samples by one (once by two) on at most 0.05% of them, from its
  rounding.
- **WAV:** each kind of sample the same as ffmpeg reads it, to the bit, on the two collection files
  (8-bit at 22.05 kHz, IMA ADPCM at 8 kHz) and twelve made by ffmpeg.
- **Resampling:** tones in a 44.1 kHz file come out unchanged in level (to 0.001 dB) up to 20 kHz, and
  everything else in them is some 110 dB down; 30 kHz in a 96 kHz file is taken out by 109 dB. About 530
  times real time for 44.1 kHz stereo; Vorbis decodes at about 1,000 times, MP3 at 1,700.

Decisions:

- **Level:** recordings are multiplied by 0.49. The median of the 777 collection Ogg Vorbis files that
  are not silence is -16.8 LUFS as decoded, and comes to -22.97 LUFS as played.
- **Full scale:** decoded samples are held to ±1 before resampling. `Dangerous_Streets_CD32_CDDA/
  07_ingame.ogg` begins with a broken packet that decodes, in ffmpeg too, to samples up to 1,047.
- **Channels:** more than two are refused rather than mixed down.

### AYL — Ay_Emul's playlists

- `PlaylistFile` reads one: the tunes and the comments, and nothing else.

### M3U — the plainest playlists

- `PlaylistFile` reads one as it reads an AYL: the tunes, in order, and nothing else.
