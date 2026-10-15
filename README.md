<img src="logo.png" alt="The siday logo: a chip marked SIDAY, with a stave of music" width="180" align="right">

# siday

A player of chiptunes and tracker modules written entirely in Swift, in two forms: **a page that
plays in your browser**, and a command-line player for macOS. Both are the same emulators underneath:
of the sound chips of the ZX Spectrum, the Amstrad CPC, the Atari ST, the Commodore 64, the Amiga and
the PC's AdLib and Sound Blaster cards, and of the trackers that played modules on the Amiga and the PC.

The name is the two families of sound chip it began with, SID and AY. How to pronounce it is left open.

**In a browser:** open **[ptsochantaris.github.io/siday](https://ptsochantaris.github.io/siday/)** and
drop tunes or a whole folder on the page. Nothing is uploaded: they are played where they are. See
[In a browser](#in-a-browser).

**On the command line:** point it at files, folders or playlists. See [On the command line](#on-the-command-line).

```
siday ~/Music/chiptunes --shuffle
```

## What it plays

| For | Formats | Played by |
|---|---|---|
| ZX Spectrum, Amstrad CPC | PT3, PT2, PT1, STC, STP, ASC, PSC, SQT, FTC, FXM, PSM, GTR, and TurboSound pairs; VTX and YM register recordings; AY program rips, beeper music included | each tracker's own player, or the tune's own program on a Z80, on the AY chip |
| Atari ST and STE | SNDH, packed with Ice or not; YM files from the ST, with its timer effects; sample tunes (MIX1, YMT1, YMT2) | the tune's own program on a 68000, on the ST's sound chip and the STE's samples |
| Commodore 64 | SID (PSID and RSID) | the tune's own program on a C64, with either of two emulations of the SID chip |
| Amiga | MOD of four channels (ProTracker's and its relatives', packed with PowerPacker or XPK or not), MED (MED4, and MMD0 to MMD3), AHX, HVL, SFX, OKT, DBM; DIGI | each tracker's own replayer, on the Amiga's sound chip (HivelyTracker's and DigiBooster's on their own mixers); DIGI Booster's read into what FastTracker 2's replayer plays |
| PC trackers | XM, and MOD of more than four channels; S3M; STM and STX; IT; 669; FAR | the replayers of FastTracker 2, Scream Tracker 3, Scream Tracker 2 and Impulse Tracker; players written for 669 and FAR files |
| Other PC trackers | MTM, DTM, AMF; DSM; GDM, PTM, ULT, C67, MDL, DMF, IMF, AMS, PLM; MPTM; MT2; J2B (Jazz Jackrabbit 2), packed with zlib | read into what FastTracker 2's replayer plays (the first three), Scream Tracker 3's (DSM), or Impulse Tracker's |
| AdLib and Sound Blaster FM | CMF, ROL, FMT | Creative's driver, AdLib's driver and OpenMPT's reading, on the FM chip |

Each of these was set beside a reference player, most of them to the sample:
[How it is built](#how-it-is-built) says what each is made from and what it was checked against, and
[FORMATS.md](FORMATS.md) tells each format's story.
What is not played, and what is played with something missing, is under
[Playback caveats](#playback-caveats).

A playlist in Ay_Emul's AYL format plays the tunes it names, in its order, whatever kinds of tune
they are.

## In a browser

[ptsochantaris.github.io/siday](https://ptsochantaris.github.io/siday/) is the player as a web page,
and `Web/` is where it comes from. It is Swift too: the emulators and the page itself are compiled
to WebAssembly. Drop tunes or a whole folder on it and it plays them. Nothing is uploaded: the files
are read where they are and never leave your computer.

A playlist can be dropped too. A web page can only read the files it is given, so it cannot go
from a list to its tunes on the disk. Dropped by itself, a list says so and asks for the
folder its tunes are in, which is then only looked in, and stays known for the lists dropped after
it. Or drop the folder that holds both.

Beside the player and its list there is a spectrum analyser, a light for each voice of the tune
(red for a voice whose sound a chip makes of itself, blue for one that plays a sample), a
picture to listen by (a lava lamp, a mirror ball, an aurora, a pond, a fire, a fountain or rain,
each made from what the tune's voices are doing), and the command-line player's options as
settings. A song is rendered to its end as soon as it starts, far faster than it plays, so any
place in it can be moved to. A tune that is not played quite as its file asks has a small ≈ beside
its name: see [Playback caveats](#playback-caveats). And the name of the tune's format, beside its
title, can be pressed: it brings up what [FORMATS.md](FORMATS.md) says of that format, to read
while the tune plays.

Each light is also a button for its voice. Click one to mute the voice, and again to bring it back;
right-click it (or hold Control and click, or press and hold on a touch screen) to hear that voice
alone, and again to bring the others back. A muted light is dimmed and loses most of its colour,
and goes on flickering with what its voice is playing. The sound follows a moment after the press,
and the mutes last until the song changes. See [Muting a voice](#muting-a-voice) for what a muted
voice still shares with the others.

To run it from here:

```
./Web/serve.sh
```

That builds what needs building, serves the folder at http://localhost:8000 (to this Mac only) and
opens the page. `./Web/build.sh` builds without serving, and `./Web/publish.sh` builds and pushes
the site, and nothing else, to the repository's `gh-pages` branch, which GitHub Pages serves.

Building it needs Swift 6.4 and the matching Embedded Swift SDK for WebAssembly (`swift sdk list`
shows what is installed), and nothing else: no Node, no packages to install. If Binaryen's
`wasm-opt` is installed, both modules go through it and come out smaller. The folder is the whole
site, static files that any web server can serve.

The page is two WebAssembly modules, about 1.5 MB compressed. `SidayWebAudio` is SidayKit and
nothing else: it runs in a worker, which renders the whole of a song and keeps it, and the audio
thread only plays what it is sent, so nothing the page does can hold the sound up. `SidayWeb` is
the page itself, written in [ElementaryUI](https://elementary.codes). Between them is `siday.js`,
for what only a browser has: the chosen files and the audio graph.

With these in the package, a plain `swift build` with no `--product` also compiles the web targets and
what they depend on for the Mac, which takes minutes the first time and is of no use.

## On the command line

`siday` is the player for the terminal, on macOS 26 or later. To build it:

```
swift build -c release --product siday
```

The binary is `.build/out/Products/Release/siday` (`swift build -c release --show-bin-path` prints the folder).
Always use a release build: the emulators are far too slow in debug.

### Using it

```
siday <files, folders or playlists…>
```

Folders are searched recursively and files are recognised by extension. The files are only ever read.

A playlist (an AYL file) is played as it is written: the tunes it names, in its order, and under
each what the list says about it, if it says anything. In a folder, the tunes are played in the
order of their names, and a playlist is the order of the tunes beside it and below it: those are
played where the list is, as it has them. The tunes a list names from somewhere else are added
only if the folder does not hold them: a collection kept as one folder of tunes and many of lists
is played once through, and a folder of nothing but lists is played too.

While playing: `space` pause · `n` or `→` next · `p` or `←` previous · `+` / `-` (or `↑` / `↓`) subsong ·
`i` the story of the tune's format, from [FORMATS.md](FORMATS.md) · `q` quit.

Each voice of the tune has a light on the status line, a bar as tall as the voice is loud, four to a
group. `1` to `9`, and `0` for the tenth, mute a voice and bring it back; `[` and `]` choose one,
shown the other way round, and `m` mutes it, `s` plays it alone (`s` again brings the others back).
A muted light is faint. Every tune starts with all its voices. See
[Muting a voice](#muting-a-voice).

A tune that is not played quite as its file asks says what is missing, a line for each thing, under
its own line as it starts.

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
| `--output mono\|abc\|acb\|plastic\|wood` | What the tune is heard through. Mono by default, because many AY tunes layer the chip's three channels into one sound; `abc` and `acb` spread them left, centre and right (a SID has a single output, so for a SID tune these are mono, and a module has a stereo of its own, which these leave as it is); `plastic` and `wood` are the speaker of an early-1980s television (see below), which is mono too |
| `--s3m-card gus\|sb` | The sound card an S3M file is played on: a Gravis Ultrasound, or a Sound Blaster Pro with its eight bits at 22 kHz. Default: the one the file was saved with, where it says, and otherwise the GUS |
| `--amiga-separation 0…100` | How far apart a module's left and right are kept, in percent (default 20). 100 is the Amiga's own hard left and right, which is harsh in headphones |
| `--amiga a1200\|a500` | Which Amiga a module is heard on. The 1200 by default; the 500 has a low-pass filter at 4.4 kHz in the way, which is the darker sound much Amiga music was written on |
| `--sid-model auto\|6581\|8580` | SID model (default: what the tune asks for) |
| `--sid-engine residfp\|resid` | SID emulation. reSIDfp by default; reSID 1.0 is lighter, and its 6581 filter is drier |
| `--sid-filter-curve 0…1` | Where the 6581's filter sits, bright to dark (default 0.5). Real chips varied this much; reSIDfp only |
| `--songlengths path` | A copy of HVSC's `Songlengths.md5` to ask before the lengths that are built in; remembered for later runs. A file with no lengths in it is ignored |
| `--mute 2,4` / `--solo n` | Leave these voices out of every tune, or hear only this one, played or rendered to WAV. Voices are numbered from 1, as the lights are |
| `--wav folder` | Render to WAV files instead of playing (existing files are not overwritten) |
| `--list` | Show what would be played, with format, length and title. A `*` after the length marks a tune that is not played quite as its file asks |
| `--shortfalls` | With `--list`, say under each marked tune what it is that is left out or made do for |
| `--check` | Load and render a few seconds of every file silently and report per format; the last column counts the tunes `--list` would mark |
| `--bench` | Render at full speed and report the multiple of real time |
| `--about it` | Print what [FORMATS.md](FORMATS.md) says of a format, named or given by a file of it, and exit |

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
- A CMF or ROL file ends where its music does, with a second after it for the last notes to die away.
- An FMT file went round for ever in its tracker. It is played through once, and given the same second.
- Only a tune that is still playing at that point is faded out, since it would go on repeating. One
  that has come to rest there has an ending of its own and simply stops. An AY file that asks for a
  particular fade gets that one.
- A tune that falls silent for five seconds is played on, unheard, to see whether the sound comes
  back. If it does within a minute, and before the tune is over, that was a pause, and it is played
  as it is written, however long: a tune made to go with a demo's pictures may wait half a minute
  between its parts. If it does not, the tune ends there. A tune that begins with ten seconds of
  silence is looked into the same way.
- Multi-song AY and SID files play the song the file names as its first; `+` and `-` move between songs.
- A module can hold several songs too: a game's music was often one file with a tune for every level,
  each ending in a jump back to its own start. Whatever the list of patterns holds that playing from
  its top never reaches is played from there as another song, and so on until nothing is left. A
  song is over when it comes round to where it has itself been. It may get there by way of a song
  found before it: another beginning for a tune goes on as the tune does. One that runs off the end
  of the list of patterns, which the tracker would have started again from the top, where another
  song is, stops there instead, with what is sounding left to die away. A piece that only leads
  into an earlier song is not counted unless it is half a minute long before it gets there, nor one
  with no note in it or shorter than a second; where the first song is such a nothing, the first
  real one is played.
  `+` and `-` move between them, and `--list --all-subsongs` shows how long each is. Some of what
  turns up is not a song but patterns the composer left behind after the end of the list.
- An AHX file says itself where each of its songs starts, and those are its songs, but for any that
  start where an earlier one has played through: those are ways into it and not songs. One is over
  when it comes round to a row it has played, or stops itself. A HivelyTracker file is the same.

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

## Playback caveats

A file that is played with something missing or made do for says so itself, in a sentence for each
thing: "Three of its instruments play through plug-ins, and are not heard." The page puts a small ≈
beside its name, and `siday --list --shortfalls` prints the sentences. Only what the tune itself
uses is said, and only what might be heard.

Not played:

- **SID:** RSID tunes that need the C64's BASIC ROM, and Compute!'s Sidplayer (MUS) data.
- **Amiga:** a MOD packed again by The Player; a song that MED saved before MED4 (MED2, MED3), and
  a MED4 song whose instruments are kept in files of their own; a module of the later SoundFX, of
  31 samples.
- **PC:** a DTM file from Digital Home Studio; the other kind of
  file called AMF, ASYLUM's; the other kind called DSM, Dynamic Studio's; an STM song saved without
  its samples.
- **MPTM:** a file whose notes are, half of them or more, for plug-ins that are not OpenMPT's own
  or for samples kept in other files.
- **MT2:** a file whose notes are, half of them or more, for VST instruments or MIDI devices, or for
  samples kept in other files.
- **J2B:** a file whose checksums are wrong, or that does not unpack to what its header says.

Played, with a difference:

- **SID:** a few RSID tunes that depend on exact video or serial-port timing do not play correctly.
- **SNDH:** a tune that sends its notes out of the MIDI port is silent, and of some 5,900 files
  tried a handful do not start; the reference player does not start them either.
- **MED:** notes for a MIDI synthesiser are not heard; in a MED4 file, a synthetic or hybrid sound
  is silent, and the hold and decay of notes are not read.
- **DBM:** played as DigiBooster 3 plays it, which leaves out three of DigiBooster Pro's commands:
  setting how far into an envelope a note is, sliding where a sample starts, and setting the tempo
  in beats a minute.
- **DIGI:** played by FastTracker 2's replayer as OpenMPT plays it; a start more than 64 KB into a
  sample and the robot voice are left out, and a note played backwards is not turned round by a
  note that starts on a later row beside it.
- **XM** from a later tracker: played as FastTracker 2 would play it.
- **XM, IT and MPTM** from ModPlug Tracker or OpenMPT: plug-ins that are not OpenMPT's own are left
  out, and what was sent through one is heard as it is; a sample packed ModPlug Tracker's own way
  (ADPCM) is silent; and in an IT or MPTM file, S9A to S9D, which choose two speakers or four for a
  channel in surround and how a note's filter starts, are left out.
- **GDM, PTM, ULT, MDL, DMF, J2B:** a command that Impulse Tracker's replayer has no room or no like for is
  left out. An MDL file's command that chooses another of the tune's envelopes turns on the
  instrument's own.
- **MT2:** the tracks' own effects, the automation and the VST plug-ins are left out, as OpenMPT
  leaves them out; and a place between the speakers that has no room beside a volume and a command.
- **IMF:** the chorus, the reverb and slides of the filter are left out, as OpenMPT leaves them out;
  and a command that has no room beside another, or that Impulse Tracker's replayer has no like for.
- **AMS:** a command that has no room beside a note's others is left out, as OpenMPT leaves it out;
  a key that a command lets go after some ticks is let go at once, as OpenMPT lets it go.
- **STM and STX:** played as Scream Tracker 2.3 played it, whichever version the tune was made with.
- **DSM:** played by Scream Tracker 3's replayer on a Gravis Ultrasound, as OpenMPT plays it by
  Scream Tracker's rules, but at sixteen places between the speakers and with surround in the
  middle; the file's master volume is left out.
- **ROL:** an instrument that no bank has is silent.

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
| 68000 CPU | written for this project, from Motorola's manual | AtariAudio's (Musashi), through the tunes below |
| Atari ST machine, its sound chip, timers and STE samples | AtariAudio by Arnaud Carré (MIT); the chip's mixing table measured by Paulo Simões | AtariAudio itself, sample for sample: three minutes of each of 5,897 tunes, and every song of those with several |
| Atari ST YM files, their effects, digi-mixes and YM tracker tunes | AtariAudio | AtariAudio, sample for sample, on the 23 files to hand; no YM2 or YMT2 file among them |
| Ice unpacking | the C version by Hans Wessels (public domain) | — |

### Each format

Each format has a story of its own: where it came from, what its player here is made from, how
that was checked and against what, and, where the references disagree, which way was taken and
why. Those are in [FORMATS.md](FORMATS.md), a part for each format. The web player shows a
format's part when the format's name beside the tune is pressed. On the command line,
`siday --about it` prints the part on IT files (a format's name or a tune's file will do), and
`i` prints the part on the format of the tune that is playing.

### Muting a voice

In the browser a voice can be left out of the sound by pressing its light, and on the command line
by its key. Each player does that for
itself, since a voice is a different thing in each: a channel of a chip, a track of a module, a note
left ringing behind a newer one. The rule is the same for them all. A muted voice is left out where
it joins the others, and goes on playing: the tune keeps its timing and comes to the same end, and
what is shown of the voice (its light, its pitch, its side) is what would be shown if it were heard.
With no voice muted the sound is, to the byte, what it was before any player could mute: that was
checked on some two thousand real files, of every format, when the muting was written.

Left out where it joins the others means that what voices share is still shared, and some of that
can be heard:

- **AY chip.** A muted channel's tone, noise and envelope run on, and it is simply not added in. The
  Spectrum's beeper is a fourth voice and mutes the same way.
- **Atari ST.** The ST's chip does not add its three channels: it gives out one level for the three
  together, from a table that was measured on the machine, in which three voices are not three times
  one. A muted channel is looked up as silent, so the others sound as they do beside a silent
  channel, which is louder than they are in the mix, by 4 dB at the most.
- **SID.** A muted voice comes to the filter and the mixer as a silent voice at its resting level.
  It does not drive the filter, and it goes on modulating the others (ring modulation, sync) and
  being read by the tune. Because a silent voice still has a level, a tune that changes the filter's
  mode often leaves faint thumps when every voice is muted. The fourth light is for samples played by
  moving the volume; they are muted by holding the volume still, and only in a song that is found to
  play them, since holding it would undo every fade in a song that does not. Samples made on a voice
  go with that voice.
- **FM chips.** A voice is left out at the chip's own output. In rhythm mode the drums share
  channels, so the bass drum mutes alone, the snare with the hi-hat, and the tom-tom with the cymbal.
- **Amiga.** Where Oktalyzer or MED split one of the Amiga's voices into two tracks, either can be
  muted, but the pair has one volume between them. DigiBooster's echo belongs to its track and is
  muted with it. In OctaMED's mixing mode a muted track feeds
  neither the sound nor the echo.
- **PC trackers.** In Impulse Tracker's replayer a muted channel takes with it the notes it has left
  ringing, and feeds none of OpenMPT's effects; an echo or a reverb that already holds some of its
  sound rings out. On Scream Tracker's Gravis Ultrasound a muted channel still takes voices from
  the others when the card runs out, as it would if it were heard.
- **Everywhere:** a tune so loud that its sum is clipped is clipped less with a voice muted.

The page renders a song to its end as soon as it starts, so a mute cannot simply be switched on: the
song is rendered again, from its beginning, without the muted voices. What was being heard goes on
being heard until the new rendering has caught up with the listener, and then gives way to it, so
nothing stops; the effect comes a moment after the press, and later in a long tune of a kind that is
slow to render. The song without some of its voices is played to exactly the end the whole song came
to, fade and all. Left to judge by its own sound, as a song usually is, it might be taken to have
fallen silent and be cut short. A change between mono and stereo, or of a setting that changes the
sound, is taken up in the same way.

The command line renders as it plays, and there the song is not rendered again but played a second
time, alongside: another player of the same file starts from its beginning with the voices left
out, unheard and as fast as it can go, while the song plays on whole. When it has got to where the
song is, it is heard in its place; from then on, voices are muted and brought back at once. The
song is still judged by the first player, whole, so it comes to the same end. Muting a voice for the
first time costs a moment, as in the browser; the second player is let go when every voice is back.

## Licence and credits

GNU General Public License, version 2 or (at your option) any later version; see `LICENSE`. Two parts,
the driver for CMF files and the replayer for STM files, come from work under the Apache License 2.0, which goes with version 3 of
the GPL and not with version 2: the player as a whole is passed on under version 3 or later.

This project stands on other people's work, most of all Sergey Bulba's Ay_Emul, Dag Lem's reSID,
libsidplayfp and its reSIDfp (Leandro Nini, Antti Lankila, Simon White, Dag Lem), Peter Sovietov's ayumi
and Arnaud Carré's AtariAudio.
`THIRD-PARTY.md` lists what came from where and under which terms.

What it is made from:

- [Ay_Emul](http://ay.strangled.net/) by Sergey Bulba: the tracker players, the VTX and YM handling
  and the rules of the AY file machine are ported from its source. The `.ay` format is as he and
  Patrik Rak describe it.
- [libsidplayfp](https://github.com/libsidplayfp/libsidplayfp) and its reSIDfp, by Leandro Nini, Antti
  Lankila, Simon White and Dag Lem: the SID chip, and the way a C64 is started for a tune.
- [reSID](https://github.com/libsidplayfp/resid) by Dag Lem: the other SID chip (`--sid-engine resid`).
- [ayumi](https://github.com/true-grue/ayumi) by Peter Sovietov: the AY and YM chip.
- [AtariAudio](https://github.com/arnaud-carre/AtariAudio) by Arnaud Carré (Leonard of Oxygene): the
  Atari ST as a tune needs it, with its sound chip, its timers and the STE's samples, and the playing
  of YM files as the ST played them. The YM format is his too. The table of
  how the ST mixes its chip's three channels was measured on the machine by Paulo Simões. The SNDH
  format is the work of the [SNDH archive](https://sndh.atari.org/) and those who keep it.
- [pt2-clone](https://github.com/8bitbubsy/pt2-clone) by Olav Sørensen (8bitbubsy): the Amiga as a
  module needs it. The replayer is his C port of ProTracker 2.3D's, and Paula, her filters and the
  reading of modules are his too; the band-limited steps in Paula's output are by aciddose. ProTracker
  itself is by Lars Hamre, Anders Hamre, Sven Vahsen and Rune Johnsrud, after Karsten Obarski's
  Ultimate Soundtracker, where the module began.
- MED and OctaMED are by Teijo Kinnunen, and the MED module is as he describes it in the notes on
  the format that came with OctaMED; the MED4 file is as libxmp's authors read it. The players of
  MED modules here, and the mixing, are siday's own: nothing in them is taken from OctaMED's,
  which they were written to do the same as.
- SoundFX is by Christian Haller and Christian A. Weber (Linel, 1988), and Oktalyzer by Armin Sander
  (1989). Their modules are as Claudio Matsuoka (for libxmp) and Harald Zappe wrote them down. The
  players of both here are siday's own: nothing in them is taken from the trackers' routines, which
  they were written to do the same as.
- [ahx2play](https://github.com/8bitbubsy/ahx2play), also by Olav Sørensen: AHX's replayer and the
  making of its waves, ported by him from the tracker's own source. AHX is by Martin Wodok (Dexter)
  and Manfred Linzner (Pink) of Abyss.
- [HivelyTracker](https://github.com/pete-gordon/hivelytracker) by Pete Gordon (Xeron of IRIS): its
  replayer and mixer, and the HVL format. The replayer began as his port of AHX's, and others have
  mended it since, kode54 and passing_by among them.
- libdigibooster3 by Grzegorz Kraszewski, which APC&TCP published: DigiBooster 3's replayer and
  its reading of DBM files, which play DigiBooster Pro's modules too. DigiBooster Pro is by Tomasz
  and Waldemar Piasta, and DigiBooster 3 by Grzegorz Kraszewski with APC&TCP.
- [ft2play](https://github.com/8bitbubsy/ft2play), also by Olav Sørensen: FastTracker 2's replayer
  and mixer, ported by him from the tracker's own assembly and Pascal. FastTracker 2 is by Fredrik
  Huss and Magnus Högdahl, of Triton.
- [libxmp](https://github.com/libxmp/libxmp) by Claudio Matsuoka, Hipolito Carraro Jr and those who
  have kept it since, and [OpenMPT](https://openmpt.org) by Olivier Lapicque and the OpenMPT
  developers: how an MTM, a DTM and an AMF file are read, and what the trackers that wrote them meant
  by their commands, version by version. MultiTracker is by Daniel Goldstein of Renaissance, Digital
  Tracker is Softjee's, and DSMI is by Otto Chrons.
- [st3play](https://github.com/8bitbubsy/st3play), also by Olav Sørensen: Scream Tracker 3's replayer,
  its Gravis Ultrasound driver, Sound Blaster mixing and AdLib driver, and the emulation of the GUS's
  sound chip. Scream Tracker 3 is by Sami Tammilehto (Psi) of Future Crew.
- [st2play](https://github.com/viiri/st2play) by Sergei "x0r" Kolzun: Scream Tracker 2's replayer and
  mixing, which he ported from the program, version by version. Scream Tracker 2 is Sami
  Tammilehto's too.
- [it2play](https://github.com/8bitbubsy/it2play), also by Olav Sørensen: Impulse Tracker 2's
  replayer, ported by him from the tracker's own assembly, the reading of IT files, and the sound
  driver, which is his own. Impulse Tracker is by Jeffrey Lim.
- OpenMPT once more: an MPTM file is its own, and what is read from one, and what the replayer has
  been given to play one with, follow its source.
- libxmp and OpenMPT again: how a GDM and a PTM file are read, which is made after both of theirs,
  and libxmp the player that the reading and the playing of those files were checked against. The GDM
  format is as MenTaLguY describes it, and BWSB and its converter are by Edward Schlunder; the PTM
  format is as JAL of Nostalgia describes it, and PolyTracker is by Lone Ranger of AcmE.
- And again: what a 669 file and a FAR file mean, which the players written for them were made
  from. Composer 669 is by Tran of Renaissance, and Farandole Composer by Megan Potter.
- And again: how a ULT file is read, made after both of theirs and, for what goes where when a note
  has two commands, after neither; libopenmpt is the player those files were checked against. The
  format is as FreeJack of The Elven Nation describes it, and UltraTracker is by Marc André
  Schallehn.
- And again: how an MT2 file is read, and the few ways in which OpenMPT plays one otherwise than an
  IT file; libopenmpt is the player those files were checked against. MadTracker is by Yannick
  Delwiche.
- And again: how an IMF file is read, which OpenMPT took from Storlek's loader for Schism Tracker,
  and the few ways in which OpenMPT plays one otherwise than an IT file; libopenmpt is the player
  those files were checked against. Imago Orpheus is by Lutz Roeder.
- And again: how an AMS file of either kind is read and its packed samples unpacked, and the few ways in
  which OpenMPT plays one otherwise than an IT file; libopenmpt is the player those files were checked
  against. Extreme's Tracker and Velvet Studio are by Extreme, later Velvet Development.
- And again: how an MDL file is read, and what Digitrakker does otherwise than Impulse Tracker,
  made after OpenMPT's; and how its samples are unpacked, as the description that came with the
  program has it, which libxmp quotes. libopenmpt is the player those files were checked against.
  Digitrakker is by Prodatron.
- And again: how a DMF file is read, its packed samples among it, and the few ways in which OpenMPT
  plays one otherwise than an IT file; libopenmpt is the player those files were checked against.
  X-Tracker is by D-Lusion.
- And again: how a J2B file is read, made after OpenMPT's (itself after kode54's for his DUMB);
  libopenmpt is the player those files were checked against. The Galaxy Sound System is by Carlo
  Vogelsang, and the music is Jazz Jackrabbit 2's. Its zlib packing is unpacked as Teemu Suutari's
  [ancient](https://github.com/temisu/ancient) does it, and was checked against the system's zlib.
- And again: how a PLM file is read, and what Disorder Tracker 2 does otherwise than Impulse
  Tracker, made after OpenMPT's; libopenmpt is the player those files were checked against.
- And again: how a DSM file of the Digital Sound Interface Kit is read, and what OpenMPT does for
  one otherwise than for an S3M file; libopenmpt is the player those files were checked against.
  The Digital Sound Interface Kit is by Carlos Hasan.
- And again: how a DIGI Booster module is read, and what DIGI Booster does otherwise than
  FastTracker 2, made after OpenMPT's; libopenmpt is the player those files were checked against.
  DIGI Booster is by Tomasz Piasta.
- [Nuked OPL3](https://github.com/nukeykt/Nuked-OPL3) by Nuke.YKT: the Yamaha OPL3, the FM chip of
  the AdLib and Sound Blaster cards, as exact as its author could make it from the chip itself. The
  chip's ROMs were read out by Matthew Gambrell and Olli Niemitalo.
- [fmdrv](https://github.com/viiri/fmdrv) by Sergei "x0r" Kolzun: SBFMDRV, the driver that played CMF
  files on a Sound Blaster, ported by him to C from the driver itself. The driver and the CMF format
  are Creative's.
- [AdPlug](https://github.com/adplug/adplug) by Simon Peter and others: its player of ROL files, by
  OPLx, and AdLib's sound driver as OPLx, Stas'M and Jepael have it there from the code AdLib gave
  programmers. Visual Composer, the ROL format and the first bank of instruments are AdLib's; the
  instruments built into the player are theirs and those of the many people who added to that bank.
- [OpenMPT](https://openmpt.org/) by its developers, after Olivier Lapicque's ModPlug Tracker: all
  that is written down of FMT files is its loader for them, and how such a song is played here
  (its pitches, and how a note is stopped) is how OpenMPT plays it. FM Tracker and the FMT format
  are Davey W Taylor's.
- The Ice 2.4 unpacker is after the C version Hans Wessels placed in the public domain; Ice itself is
  by Axe of Delight.
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
- [UADE](https://zakalwe.fi/uade/) by Heikki Orsila and Michael Doering, which runs an Amiga's own
  music players in an emulated Amiga and can write down all they tell the sound chip and all it
  plays: OctaMED's three players in it are what the players of MED modules were held to.
  SoundFX's routine in it (as Wanted Team fitted it for DeliTracker) and Oktalyzer's (as Buggs of
  Defect did) are what the players of those modules were held to.

What it is built with: [swift-argument-parser](https://github.com/apple/swift-argument-parser) for the
command line, and [ElementaryUI](https://elementary.codes) and
[JavaScriptKit](https://github.com/swiftwasm/JavaScriptKit) for the page in the browser.
