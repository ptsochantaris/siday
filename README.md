<img src="logo.png" alt="The siday logo: a chip marked SIDAY, with a stave of music" width="180" align="right">

# siday

siday plays chiptunes and tracker modules. It is written entirely in Swift, and comes in three
forms that share the same emulators:

- **[a web page](https://ptsochantaris.github.io/siday/)** that plays tunes in your browser;
- **an app** for macOS, iPhone and iPad, in beta on
  [TestFlight](https://testflight.apple.com/join/6eXCKs3e);
- **a command-line player** for macOS.

It emulates the sound chips of the ZX Spectrum, the Amstrad CPC, the Atari ST, the 8-bit Ataris, the
Commodore 64, the Amiga, and the PC's AdLib and Sound Blaster cards. It also plays the modules of the
trackers of the Amiga and the PC, mostly through ports of those trackers' own replayers.

The name comes from the two families of sound chip it began with: SID and AY. How to pronounce it is
up to you.

**In a browser:** open **[ptsochantaris.github.io/siday](https://ptsochantaris.github.io/siday/)**
and drop tunes, or a whole folder, onto the page. Nothing is uploaded: the files are played where
they are. See [In a browser](#in-a-browser).

**On the command line:** point it at files, folders or playlists. See
[On the command line](#on-the-command-line).

```
siday ~/Music/chiptunes --shuffle
```

Each format has a story: where it came from, and how siday plays it. Those are in
[FORMATS.md](FORMATS.md), and every player can show the story of the tune you are listening to. How
siday is built, and how each part was checked, is in [DEVELOPMENT.md](DEVELOPMENT.md).

## What it plays

| For | Formats | Played by |
|---|---|---|
| ZX Spectrum, Amstrad CPC | PT3, PT2, PT1, STC, STP, ASC, PSC, SQT, FTC, FXM, PSM, GTR, and TurboSound pairs; VTX and YM register recordings; AY program rips, beeper music included | each tracker's own player, or the tune's own program on a Z80, on the AY chip |
| Atari ST and STE | SNDH, packed with Ice or not; YM files from the ST, with its timer effects; sample tunes (MIX1, YMT1, YMT2) | the tune's own program on a 68000, on the ST's sound chip and the STE's samples |
| Atari 400, 800, XL and XE | SAP, for one POKEY or two | the tune's own program on a 6502, on the POKEY |
| Commodore 64 | SID (PSID and RSID) | the tune's own program on a C64, with either of two emulations of the SID chip |
| Amiga | MOD and its many packed forms, and over twenty other trackers and music systems: see [On the Amiga](#on-the-amiga) | each format's own player, or a port or reading of it, on the Amiga's sound chip |
| PC trackers | XM, and MOD with more than four channels; S3M; STM and STX; IT; 669; FAR | the replayers of FastTracker 2, Scream Tracker 3, Scream Tracker 2 and Impulse Tracker; players written for 669 and FAR files |
| Other PC trackers | MTM, DTM, AMF; DSM; GDM, PTM, ULT, C67, MDL, DMF, IMF, AMS, PLM; MPTM; MT2; J2B (Jazz Jackrabbit 2), packed with zlib | converted for FastTracker 2's replayer (the first three), Scream Tracker 3's (DSM), or Impulse Tracker's (the rest) |
| Modules packed by Un4seen | MO3, with its samples packed or kept as MP3 or Ogg Vorbis | unpacked into the IT, XM, S3M, MOD or MTM it was made from, and played as that is |
| Epic MegaGames' DOS games | PSM files of MASI, their music system (Epic Pinball, Silverball, Jazz Jackrabbit, Extreme Pinball, Sinaria), told apart from the ZX Spectrum's PSM by how they begin | converted for Scream Tracker 3's replayer |
| Sierra's adventure games, King's Quest to Manhunter | AGI sounds | either of Sierra's own two routines for the Amiga, on the Amiga's sound chip; or the PCjr's and Tandy 1000's chip, as Sierra's interpreter wrote to it |
| Recordings, such as the CD audio of CD32 and CDTV games | Ogg Vorbis, MP3 (and MP2), WAV | ports of stb_vorbis and minimp3; brought to 48 kHz, a voice for each side |
| AdLib and Sound Blaster FM, the Creative Music System, the PC speaker, the PCjr and Tandy 1000 | CMF, ROL, FMT; VGM and VGZ recordings of the OPL, OPL2 and OPL3, of the Creative Music System's two SAA1099s, of the AY-3-8910 that PC speaker music is recorded as, of the samples a Sound Blaster played, and of the SN76489 | Creative's driver, AdLib's driver and OpenMPT's reading, on the FM chip; a recording's own writes, at their own moments, on the FM chip, the SAA1099, the AY chip, the SN76489 or a DAC |

A playlist, in Ay_Emul's AYL format or an M3U (such as VGM packs come with), plays the tunes it
names, in its order, whatever kind of tune each is.

Each player here was compared with a reference player, most of them sample for sample.
[DEVELOPMENT.md](DEVELOPMENT.md#how-each-part-was-checked) says what each is made from and what it
was checked against. What is not played, or played with something missing, is under
[Playback caveats](#playback-caveats).

### On the Amiga

**Modules** of four channels (ProTracker's and its relatives') are played by ProTracker 2.3D's
replayer. That covers modules:

- packed whole with PowerPacker or XPK, or not packed at all;
- packed by the packers games used: The Player (with its packed samples), NoisePacker, ProRunner,
  ProPacker, Pha Packer, Tracker Packer, AC1D, Novotrade, Digital Illusions, Promizer and Channel
  Player;
- from ChipTracker (read as its own replayer reads them), SoundTracker 2.6 and Ice Tracker;
- in AMOS music banks, converted to modules as UADE converts them;
- packed with the Magnetic Fields Packer, with their samples in a file alongside.

**Trackers with players of their own**, each played by a port of its own player: PumaTracker, Pierre
Adane's packed modules (with their samples alongside), Game Music Creator, Images Music System,
SoundMon 2.0 and 2.2, SidMon and SidMon II, Digital Mugician and Mugician II (seven voices), Delta
Music 2.0, Sonic Arranger, Infogrames' scores, Fashion Tracker, the Peter Verswyvelen Packer, the
Alcatraz Packer, Digital Sonix & Chrome's, Andrew Parton's, the Editeur Musical Séquentiel, Forgotten
Worlds', the Leggless Music Editor, JamCracker, A.M.Composer, Professional Sound Artists, The Musical
Enlightenment, Steve Turner's, Cinemaware's (with its instruments folder), Paul Shields', Lemmings'
SoundPlayer, Paul Robotham's, Thomas Hermann's, Soundfactory, Synth Dream, the Blade Packer, Tim
Follin's, Paul Summers', Action Amics, and David Hanney's.

**Music systems:**

- **TFMX**, Chris Hülsbeck's, with TFMX Professional and 7V, as his own players play it.
- **Jochen Hippel's TFMX** (HIP, COSO, 7V) and **Future Composer**, by Michael Schwendt's player,
  with the seven voices mixed as Hippel's own player mixed them.
- **MaxTrax**, by a port of its driver's released source, with its instruments alongside where they
  are kept separately.
- **The Sonix Music Driver**, Mark Riley's: its SMUS, TINY and SNX scores, played as his own players
  play them, with their instruments in the folder alongside.

**Composers' own players:**

- David Whittaker's, Ben Daglish's, Martin Walker's, Special FX's and the Maniacs of Noise's
  (Charles Deenen's and Jeroen Tel's) drivers. Each file carries the composer's own 68000 code,
  which siday runs on an emulated Amiga.
- DeliTracker's custom modules, each a game's own player with its music; and Dave Lowe's earlier
  music, with his own code. Both are hosted on the emulated Amiga as DeliTracker hosted them.
- 28 more composers' and studios' drivers, following the recipe of Wanted Team's players: Core
  Design, Janko Mrsic-Flogel, Benn Daglish's SID-like music, Fred Gray, Howie Davies, Holger
  Gehrmann's Sound Programming Language, Beathoven Synthesizer, Sound Master, Darius Zendeh, Mark
  II, Steve Barrett, Rob Hubbard (and on Steve Bak's replayer), Fred Monitor, Desire, the SCUMM
  sounds of Maniac Mansion and Zak McKracken, Sean Connolly, Tony Williams' Sound Images, Wally
  Beben, Mike Davies, Jason C. Brooke, Ashley Hogg, Mark Cooksey, Kris Hatlelid, Sean Conran, Jesper
  Olsen, and Chris Hülsbeck's Dynamic Synthesizer.
- Richard Joseph's player (Cannon Fodder, The Chaos Engine, Sensible World of Soccer, James Pond 2
  and 3), with its samples alongside.
- Dave Lowe's later music (King's Quest VI, Beneath a Steel Sky, Super Street Fighter II).

**Other trackers:**

- MED (MED4, MMD0 to MMD3, and MMDC, packed for games), by players written to behave as OctaMED's do.
- AHX and HVL, by their own replayers (HivelyTracker's on its own mixer).
- SFX (SoundFX) and OKT (Oktalyzer).
- DBM (DigiBooster Pro and 3), by DigiBooster 3's replayer on its own mixer.
- DIGI (DIGI Booster), converted for FastTracker 2's replayer.
- Symphonie and Symphonie Pro (SymMOD), read as OpenMPT reads them and played by Impulse Tracker's
  replayer.

## In a browser

[ptsochantaris.github.io/siday](https://ptsochantaris.github.io/siday/) is the player as a web page.
It is Swift too: the emulators and the page itself are compiled to WebAssembly. Drop tunes or a
whole folder onto it, and it plays them. Nothing is uploaded: the files are read where they are and
never leave your computer.

You can also drop a playlist, and the files some tunes need alongside them:

- a ROL tune's banks of instruments;
- the samples of a TFMX module, of a song packed by the Magnetic Fields Packer or by Pierre Adane's
  packer, or of a Richard Joseph module;
- the instruments of a MaxTrax score, where they are kept separately;
- the folder of instruments next to a Sonix score.

A web page can only read the files it is given. So it can't follow a playlist to its tunes on your
disk, or a tune to its samples. If you drop a playlist on its own, or a tune that needs its samples,
the page says so and asks for the folder they are in. It only looks in that folder, and remembers it
for whatever you drop next. Or drop the folder that holds both.

Alongside the player and its list are:

- **a spectrum analyser;**
- **a light for each voice of the tune:** red for a voice the chip makes itself, blue for one that
  plays a sample, and pink for a beeper (the loudspeaker a computer's own code clicks);
- **a scope under each light**, once switched on, showing that voice's own waveform, as FastTracker
  2 drew one for each channel. A chip's note is held still as two of its cycles; a sample shows its
  last fiftieth of a second. Each voice is shown as it leaves its chip or mixer, before anything the
  voices share, such as a SID's filter or an Amiga's;
- **a picture to listen by:** a lava lamp, a mirror ball, an aurora, a pond, a fire, a fountain, rain
  or a petri dish, each drawn from what the tune's voices are doing;
- **the settings**, which are the command-line player's options.

A song is rendered to its end as soon as it starts, far faster than it plays, so you can jump to any
point in it. A tune that isn't played quite as its file asks has a small ≈ beside its name: see
[Playback caveats](#playback-caveats). Press the name of the tune's format, beside its title, to read
what [FORMATS.md](FORMATS.md) says about it while the tune plays.

Each light is also a button that mutes its voice, or plays it alone: see
[Muting a voice](#muting-a-voice).

To run the web player from a copy of this repository, see
[DEVELOPMENT.md](DEVELOPMENT.md#the-web-player).

## On a Mac, iPhone or iPad

siday is also an app for macOS and iOS 26 or later, written in SwiftUI. It has what the web page has:

- the playlist beside the player (on an iPhone, one at a time);
- the settings;
- the list of what siday plays, with each format's story.

It opens every kind of file siday plays: from the Finder or the Files app, by drag and drop, or with
Add Files and Add Folder. It keeps its list from one day to the next. In the Finder and the Files app,
Quick Look shows a tune's details, and plays it with its voices' lights and scopes, as it plays a recording: at once in the Finder, and
when you press play in the Files app. Every command is in its menus,
each with a key. It passes the system's accessibility audit (VoiceOver labels, every text size,
contrast). It is not yet in the App Store, but you can try the beta through
[TestFlight](https://testflight.apple.com/join/6eXCKs3e).

## On the command line

`siday` is the player for the terminal, on macOS 26 or later. To build it:

```
swift build -c release --package-path CLI
```

The binary is `CLI/.build/release/siday` (`swift build -c release --package-path CLI
--show-bin-path` prints the folder). Always use a release build: the emulators are far too slow in a
debug build.

### Using it

```
siday <files, folders or playlists…>
```

Folders are searched recursively, and files are recognised by their extension. Files are only ever
read, never written.

A playlist (an AYL or M3U file) is played as written: the tunes it names, in its order, each with
whatever the list says about it.

In a folder, tunes play in the order of their names. A playlist in a folder sets the order of the
tunes beside it and below it: they are played where the list is, in its order. The tunes a list
names from elsewhere are only added if the folder doesn't hold them. So a collection kept as one
folder of tunes and many lists is played once through, and a folder of nothing but lists is played
too.

While a tune plays:

| Key | Does |
|---|---|
| `space` | pause |
| `n` or `→` | next tune |
| `p` or `←` | previous tune |
| `+` / `-` (or `↑` / `↓`) | next or previous subsong |
| `i` | the story of the tune's format, from [FORMATS.md](FORMATS.md) |
| `q` | quit |

Each voice of the tune has a light on the status line: a bar as tall as the voice is loud, four to
a group. There are keys to mute a voice or play it alone: see [Muting a voice](#muting-a-voice).

A tune that isn't played quite as its file asks says what is missing when it starts, one line for
each thing.

| Option | Effect |
|---|---|
| `--shuffle` | Random order |
| `--formats pt3,sid` | Only these formats |
| `--match text` | Only paths containing the text |
| `--loops n` | Times through a looping tune before it fades (default 1) |
| `--fade seconds` | Fade-out for a tune that is still playing where it ends (default 20, and never longer than the tune itself) |
| `--default-time m:ss` | Time given to tunes whose length is unknown (default 3:00) |
| `--max-time m:ss` | Cap on any tune |
| `--subsong n` / `--all-subsongs` | Start at song n / play every song of multi-song files |
| `--chip ay\|ym`, `--clock Hz`, `--frame-rate Hz` | AY settings. Defaults: what the file says; otherwise an AY at 1773400 Hz and 50 Hz |
| `--output mono\|abc\|acb\|plastic\|wood` | What the tune is heard through (default `mono`; see below) |
| `--level off\|full\|partial` | Bring every tune to the same loudness, or halfway there (see below). Off by default |
| `--s3m-card gus\|sb` | The sound card an S3M file is played on: a Gravis Ultrasound, or a Sound Blaster Pro (8-bit, 22 kHz). Default: the one the file was saved with, where it says; otherwise the GUS |
| `--amiga-separation 0…100` | How far apart a module's left and right are kept, in percent (default 20). 100 is the Amiga's own hard left and right, which is harsh in headphones |
| `--sb-pro-separation 0…100` | The same for a VGM recording of the first Sound Blaster Pro (one FM chip on each side), or of the Creative Music System (whose voices are mostly on one side); and for a SAP file for two POKEYs, one on each side (default 20). 100 is the hardware's own |
| `--agi amiga\|amiga-later\|pc` | How a Sierra AGI sound is played: with the first routine of the games' Amiga versions (the default; square waves), with the later one (rounder waves that die away), or on the PCjr's and Tandy 1000's chip, which the music was written for |
| `--amiga a1200\|a500` | Which Amiga a module is heard on. The 1200 by default. The 500 has a low-pass filter at 4.4 kHz in the way: the darker sound much Amiga music was written on |
| `--sid-model auto\|6581\|8580` | SID model (default: what the tune asks for) |
| `--sid-engine residfp\|resid` | SID emulation. reSIDfp by default; reSID 1.0 is lighter, and its 6581 filter is drier |
| `--sid-filter-curve 0…1` | Where the 6581's filter sits, from bright to dark (default 0.5). Real chips varied this much. reSIDfp only |
| `--songlengths path` | A copy of HVSC's `Songlengths.md5`, asked before the built-in lengths; remembered for later runs. A file with no lengths in it is ignored |
| `--mute 2,4` / `--solo n` | Leave these voices out of every tune, or hear only this one: see [Muting a voice](#muting-a-voice) |
| `--wav folder` | Render to WAV files instead of playing (existing files are not overwritten) |
| `--list` | Show what would be played, with format, length and title. A `*` after the length marks a tune that isn't played quite as its file asks |
| `--shortfalls` | With `--list`, say under each marked tune what is left out or made do for |
| `--check` | Load every file and render a few seconds silently, then report per format; the last column counts the tunes `--list` would mark |
| `--bench` | Render at full speed and report the multiple of real time |
| `--about it` | Print what [FORMATS.md](FORMATS.md) says about a format (named, or given by one of its files), and exit |

**`--output`:** Mono is the default, because many AY tunes layer the chip's three channels into one
sound. `abc` and `acb` spread the channels left, centre and right. A SID has a single output, so a
SID tune stays mono with these; a module has a stereo image of its own, which they leave alone.
`plastic` and `wood` are the speaker of an early-1980s television (see
[Through a television](#through-a-television)), which is mono too.

**`--level`:** `full` brings every tune to the same loudness. `partial` goes halfway, so a quiet tune
is still quieter than a loud one, but not by as much. Each song is measured by playing it through,
silently, alongside the song you are hearing, and the next song is measured while that one plays. A
song not yet measured waits up to a second to be measured before it starts. If that isn't enough,
it starts at about its level, judged from what has been measured so far, and glides to its level over
a second once the whole song has been measured. No song is turned up by more than 6 dB. Levels are
kept in `~/Library/Caches/siday/levels.txt`. With `--list`, it says how far each tune would be turned
up or down.

### How long a tune plays

- **Tracker modules and register recordings** play to their loop point (`--loops` times).
- **AY files** carry a length for each song. Many give none, or exactly three minutes, which rips use
  as a stand-in. Those songs are run silently for up to six minutes to find where they end or start
  to repeat. If neither is found, they get `--default-time`.
- **SID tunes** use the song lengths of the High Voltage SID Collection (HVSC). A SID file doesn't
  say how long its songs are, and most never end, so the collection's team have timed every one.
  Their lengths for release 85, all 61,157 tunes, are built into the player (command line and
  browser alike), and a tune is found among them by its content.
  - A copy of the collection's own `Songlengths.md5` is asked first, when there is one: named with
    `--songlengths` (once is enough), in `$SIDAY_SONGLENGTHS`, or found in a `DOCUMENTS` folder
    above the tune. That is the way to use a newer release's lengths. It also finds a tune by its
    path inside HVSC when its content differs.
  - A SID tune in neither gets `--default-time`.
- **CMF and ROL files** end where their music does, plus a second for the last notes to die away.
- **FMT files** went round forever in their tracker. They are played through once, with the same
  extra second.
- **VGM files** that loop are played round `--loops` times, like a module. One that doesn't loop
  ends where its writes do, with the same extra second.
- **Fading out.** Only a tune still playing at its end is faded out, since it would otherwise repeat.
  One that has come to rest there has an ending of its own, and simply stops. An AY file that asks
  for a particular fade gets that one.
- **Pauses.** A tune that falls silent for five seconds is played on silently, to see whether the
  sound comes back. If it does within a minute, before the tune is over, that was a pause, and it is
  played as written, however long. (A tune made to go with a demo's pictures may wait half a minute
  between its parts.) If not, the tune ends there. A tune that begins with ten seconds of silence is
  checked the same way.
- **Multi-song AY and SID files** start with the song the file names as its first. `+` and `-` move
  between songs.
- **Modules can hold several songs too.** A game's music was often one file with a tune for every
  level, each ending in a jump back to its own start.
  - Anything in the list of patterns that playing from the top never reaches is played from there
    as another song, and so on until nothing is left.
  - A song is over when it comes back round to where it has already been. It may get there by way of
    a song found before it: another way into a tune carries on as that tune does.
  - A song that runs off the end of the list of patterns (where the tracker would have started again
    from the top, which is another song) stops there instead, and what is sounding is left to die
    away.
  - A piece that only leads into an earlier song isn't counted unless it lasts half a minute before
    getting there. Neither is one with no notes, or shorter than a second. Where the first song is
    such a piece, the first real one is played.
  - `+` and `-` move between them, and `--list --all-subsongs` shows how long each is. Some of what
    turns up isn't a song, but patterns the composer left behind after the end of the list.
- **AHX files** say where each of their songs starts, and those are their songs, except any that
  start where an earlier one has already played through: those are ways into it, not songs. A song
  is over when it comes round to a row it has played, or stops itself. HivelyTracker files are the
  same.

### Through a television

These chips were written for, and heard through, a television: one small paper cone in a vented
plastic or wooden cabinet, fed by a sound stage with little treble to give. `--output plastic` and
`--output wood` put that between the chip and your speakers. In the browser the same two are in the
list of outputs, and can be switched while a tune plays, to compare the sound with and without.
A television has one loudspeaker, which is why it is a choice alongside mono and stereo rather than
on top of them.

| Stage | What it does |
|---|---|
| One speaker | The two channels are added together |
| Sound channel | Treble falls away gently from about 4.5 kHz |
| Amplifier and cone | Loud passages are bent slightly, adding a little second and third harmonic |
| Speaker | No bass below its own resonance (about 170 Hz in `plastic`, 90 Hz in `wood`), and little above 6 to 7 kHz |
| Cabinet | A few resonances with a dip between them: the boxy low-middle and the forward upper-middle of a small set |

`plastic` is a small portable: thin and forward. `wood` is a large set in a veneered cabinet: fuller
and rounder. The level in the middle of the range is kept where it was. No particular set was
measured: the figures are typical ones, chosen by ear.

### AY files ripped at the wrong speed

An AY file can only ask for its music routine once every 1/50 s. A few games drove their music from
a free-running loop instead, and their rips only approximate that rate, not always well. Files known
to be off are corrected by their content, and show "timing corrected" when they play. So far those
are the Exolon 128K title tune, which the rip plays 14% fast, and the Kenny Dalglish Soccer Match
menu tune, which it plays 5% slow. Giving `--frame-rate` plays any file exactly as written.

## Muting a voice

Any voice of a tune can be left out, or heard alone:

- **In the browser**, each light is a button for its voice. Click it to mute the voice, and again
  to bring it back. Right-click it (or Control-click, or press and hold on a touch screen) to hear
  that voice alone, and again to bring the others back. A muted light is dimmed and loses most of its
  colour, but goes on flickering with what its voice is playing. The sound follows a moment after
  the press, and mutes last until the song changes.
- **On the command line**, while a tune plays, `1` to `9` (and `0` for the tenth) mute a voice and
  bring it back. `[` and `]` choose a voice, shown highlighted; `m` mutes it, and `s` plays it alone
  (`s` again brings the others back). A muted light is faint, and every tune starts with all its
  voices. `--mute 2,4` and `--solo n` do the same for every tune, played or rendered to WAV. Voices
  are numbered from 1, as the lights are.

A voice means something different in each player: a channel of a chip, a track of a module, a note
left ringing behind a newer one. The rule is the same for all of them. A muted voice is left out
where it joins the others, but goes on playing. So the tune keeps its timing and comes to the same
end, and what is shown of the voice (its light, its pitch, its side) is what would be shown if it
were heard.

Because it is left out only where it joins the others, whatever the voices share is still shared,
and some of that can be heard:

- **AY chip.** A muted channel's tone, noise and envelope run on; it just isn't added in. The
  Spectrum's beeper is a fourth voice, and mutes the same way.
- **Atari ST.** The ST's chip doesn't add its three channels together. It gives out one level for
  all three, from a table measured on the machine, in which three voices are not three times one. A
  muted channel is looked up as silent, so the others sound as they do beside a silent channel:
  louder than they are in the mix, by up to 4 dB.
- **SID.** A muted voice reaches the filter and the mixer as a silent voice at its resting level. It
  doesn't drive the filter, but it still modulates the others (ring modulation, sync) and is still
  read by the tune. Because a silent voice still has a level, a tune that changes the filter's mode
  often leaves faint thumps when every voice is muted. The fourth light is for samples played by
  moving the volume. They are muted by holding the volume still, and only in a song found to play
  them, since holding it would undo every fade in a song that doesn't. Samples made on a voice go with
  that voice.
- **FM chips.** A voice is left out at the chip's own output. In rhythm mode the drums share
  channels, so the bass drum mutes alone, the snare with the hi-hat, and the tom-tom with the cymbal.
- **Amiga.** Where Oktalyzer or MED split one of the Amiga's voices into two tracks, either track can
  be muted, but the pair share one volume. DigiBooster's echo belongs to its track and is muted with
  it. In OctaMED's mixing mode, a muted track feeds neither the sound nor the echo. The voices that
  TFMX 7V's, Jochen Hippel's and Mugician II's players mix onto one of the Amiga's voices are each
  muted separately, and the mix is otherwise unchanged, clipping included.
- **PC trackers.** In Impulse Tracker's replayer, a muted channel takes the notes it has left ringing
  with it, and feeds none of OpenMPT's effects; an echo or reverb that already holds some of its sound
  rings out. On Scream Tracker's Gravis Ultrasound, a muted channel still takes voices from the others
  when the card runs out, as it would if it were heard.
- **Everywhere:** a tune so loud that its mix clips clips less with a voice muted.

The browser renders each song to its end as it starts, so a mute can't simply be switched on: the
song is rendered again from the beginning without the muted voices. You go on hearing the old
rendering until the new one catches up, so nothing stops. That is why the effect comes a moment
after the press, and later in a long tune of a kind that is slow to render. The song without some of
its voices ends exactly where the whole song did, fade and all. A change between mono and stereo, or
to a setting that changes the sound, is handled the same way.

## Playback caveats

A file that is played with something missing or substituted says so, in a sentence for each thing:
"Three of its instruments play through plug-ins, and are not heard." The page puts a small ≈ beside
its name, and `siday --list --shortfalls` prints the sentences. Only what the tune itself uses is
mentioned, and only what might be heard.

**Not played:**

- **SID:** RSID tunes that need the C64's BASIC ROM, and Compute!'s Sidplayer (MUS) data.
- **Amiga:**
  - a module packed by a game's packer that ProWizard refuses;
  - Startrekker's synthesised instruments when the file of them isn't beside the module (it says so,
    and plays without them);
  - a song packed by the Magnetic Fields Packer, or a TFMX module, whose samples aren't found
    alongside it; a Richard Joseph module without its samples; a Sonix score with no folder of
    instruments beside it;
  - a DeliTracker custom module that calls for something DeliTracker's host doesn't provide (a task
    of its own);
  - a song saved by MED before MED4 (MED2, MED3), and a MED4 song whose instruments are kept in files
    of their own;
  - a module of the later SoundFX, with 31 samples.
- **PC:** a DTM file from Digital Home Studio; the other kind of file called AMF (ASYLUM's); the
  other kind called DSM (Dynamic Studio's); an STM song saved without its samples; NTK and DSS files,
  which neither OpenMPT nor libxmp reads, so there is no player to compare with.
- **MPTM:** a file in which half the notes or more are for plug-ins that aren't OpenMPT's own, or for
  samples kept in other files.
- **MT2:** a file in which half the notes or more are for VST instruments or MIDI devices, or for
  samples kept in other files.
- **J2B:** a file whose checksums are wrong, or that doesn't unpack to what its header says.
- **SymMOD:** a Symphonie module whose samples are kept in files of their own.

**Played, with a difference:**

- **SID:** a few RSID tunes that depend on exact video or serial-port timing don't play correctly.
- **SNDH:** a tune that sends its notes out of the MIDI port is silent. Of some 5,900 files tried, a
  handful don't start; the reference player doesn't start them either.
- **MED:** notes for a MIDI synthesiser aren't heard. In a MED4 file, a synthetic or hybrid sound is
  silent, and notes' hold and decay aren't read.
- **AGI:** which of Sierra's two Amiga routines each game used isn't known, so the first is played
  unless you ask for the other. On the PC's chip, the later interpreters' turning down of notes as
  they are held is left out, for want of a recording to compare with.
- **DBM:** played as DigiBooster 3 plays it, which leaves out three of DigiBooster Pro's commands:
  setting how far into an envelope a note is, sliding where a sample starts, and setting the tempo
  in beats per minute.
- **DIGI:** played by FastTracker 2's replayer, as OpenMPT plays it. A start more than 64 KB into a
  sample and the robot voice are left out, and a note played backwards isn't turned round by a note
  that starts on a later row beside it.
- **XM, IT and MPTM** from ModPlug Tracker or OpenMPT: plug-ins that aren't OpenMPT's own are left
  out, and what was sent through one is heard unprocessed.
- **GDM, PTM, ULT, MDL, DMF, J2B:** a command that Impulse Tracker's replayer has no room or no
  equivalent for is left out. An MDL command that chooses another of the tune's envelopes turns on
  the instrument's own.
- **MT2:** the tracks' own effects, the automation and the VST plug-ins are left out, as OpenMPT
  leaves them out; so is a pan setting that has no room beside a volume and a command.
- **IMF:** the chorus, the reverb and filter slides are left out, as OpenMPT leaves them out; so is a
  command with no room beside another, or one Impulse Tracker's replayer has no equivalent for.
- **AMS:** a command with no room beside a note's others is left out, as OpenMPT leaves it out; a key
  that a command releases after some ticks is released at once, as OpenMPT does.
- **SymMOD:** played as OpenMPT plays it, which leaves out Symphonie's DSP delay, its stereo detune
  and phase, its emphasis, its adding to a note's pitch and volume, and the filter types OpenMPT
  lacks. Symphonie's fine slides become the nearest Impulse Tracker's replayer has.
- **STM and STX:** played as Scream Tracker 2.3 played them, whichever version the tune was made with.
- **DSM:** played by Scream Tracker 3's replayer on a Gravis Ultrasound, as OpenMPT plays it by
  Scream Tracker's rules, but with sixteen pan positions and with surround in the middle. The file's
  master volume is left out.
- **MASI:** played by Scream Tracker 3's replayer on a Gravis Ultrasound, as OpenMPT plays these files
  by Scream Tracker's rules, with sixteen pan positions. An older file's master volume, and a
  channel's own volume where a newer file sets one, are left out.
- **ROL:** an instrument that no bank has is silent.

## Licence and credits

GNU General Public License, version 2 or (at your option) any later version; see `LICENSE`. Two parts,
the driver for CMF files and the replayer for STM files, come from work under the Apache License 2.0,
which is compatible with version 3 of the GPL but not version 2. So the player as a whole is passed
on under version 3 or later.

This project stands on other people's work: the emulators, players and readings below are ported
from theirs, or written to behave as theirs do and checked against them. `THIRD-PARTY.md` lists what
came from where, and under which terms.

### ZX Spectrum and Amstrad CPC

- [Ay_Emul](http://ay.strangled.net/) by Sergey Bulba: the tracker players, the VTX and YM handling
  and the rules of the AY file machine are ported from its source. The `.ay` format is as he and
  Patrik Rak describe it.
- [ayumi](https://github.com/true-grue/ayumi) by Peter Sovietov: the AY and YM chip.
- [z80](https://github.com/superzazu/z80) by superzazu: the Z80's cycle counts.
- ar002 by Haruhiko Okumura: the LH5 unpacking that VTX and YM files are packed with.
- Checked against [ayfly](https://github.com/l29ah/ayfly) and
  [ay_emul_c11](https://github.com/pdxiv/ay_emul_c11) for the tracker players, and
  [z80ex](https://github.com/lipro/z80ex) and Frank Cringle's
  [ZEXDOC and ZEXALL](https://mdfs.net/Software/Z80/Exerciser/) for the Z80 and the AY file machine.

### Commodore 64

- [libsidplayfp](https://github.com/libsidplayfp/libsidplayfp) and its reSIDfp, by Leandro Nini,
  Antti Lankila, Simon White and Dag Lem: the SID chip, and the way a C64 is started for a tune.
- [reSID](https://github.com/libsidplayfp/resid) by Dag Lem: the other SID chip (`--sid-engine
  resid`).
- The [High Voltage SID Collection](https://www.hvsc.c64.org/): the length of every song of every SID
  tune, timed by its team and built into the player, and the description of the SID file format.
- Checked against [SingleStepTests/65x02](https://github.com/SingleStepTests/65x02) for the 6510.

### Atari ST and the 8-bit Ataris

- [AtariAudio](https://github.com/arnaud-carre/AtariAudio) by Arnaud Carré (Leonard of Oxygene): the
  Atari ST as a tune needs it, with its sound chip, its timers and the STE's samples, and the playing
  of YM files as the ST played them. The YM format is his too. The table of how the ST mixes its
  chip's three channels was measured on the machine by Paulo Simões. The SNDH format is the work of
  the [SNDH archive](https://sndh.atari.org/) and those who keep it.
- The Ice 2.4 unpacker follows the C version Hans Wessels placed in the public domain; Ice itself is
  by Axe of Delight.
- [ASAP](https://asap.sourceforge.net/) by Piotr Fusik: the 8-bit Atari as a SAP file needs it, with
  its 6502 and its POKEY, including the POKEY's band-limited steps and the levels of its DAC as Fusik
  measured them. The SAP format is Adam Bienias's, and the music is kept in it by the
  [Atari SAP Music Archive](https://asma.atari.org/).

### Amiga

- [pt2-clone](https://github.com/8bitbubsy/pt2-clone) by Olav Sørensen (8bitbubsy): the Amiga as a
  module needs it. The replayer is his C port of ProTracker 2.3D's, and Paula, her filters and the
  reading of modules are his too; the band-limited steps in Paula's output are by aciddose. ProTracker
  itself is by Lars Hamre, Anders Hamre, Sven Vahsen and Rune Johnsrud, after Karsten Obarski's
  Ultimate Soundtracker, where the module began.
- ProWizard by Sylvain "Asle" Chipaux, as [libxmp](https://github.com/libxmp/libxmp) keeps it
  (Claudio Matsuoka and Hipolito Carraro Jr): the unpacking of modules packed by the packers games
  used. [ancient](https://github.com/temisu/ancient) by Teemu Suutari: the unpacking of PowerPacker
  and XPK.
- [libtfmxaudiodecoder](https://github.com/mschwendt/libtfmxaudiodecoder) by Michael Schwendt: its
  players of Chris Hülsbeck's TFMX, of Jochen Hippel's and of Future Composer. TFMX is Chris
  Hülsbeck's, and his players are where its timing and its seven voices were taken from. Hippel's TFMX
  is his, and so is his player of seven voices. Future Composer is The Superions'.
- The players of their own formats that Wanted Team, Delirium, Buggs, Defect, Eagleeye, mld and
  others kept for EaglePlayer and DeliTracker, which [UADE](https://zakalwe.fi/uade/) carries. What
  each does was read in its 68000 code, and UADE ran it for siday's player to be compared with, tick
  by tick. They are the players of:
  - ChipTracker (Krister Wombell) and the Magnetic Fields Packer (Shaun Southern);
  - PumaTracker (Jean-Charles Meyrignac and Pierre-Eric Loriaux) and Pierre Adane's packer;
  - Game Music Creator (Andreas Tadic) and Images Music System (Images Software);
  - SoundMon (Brian Postma, who put his replay routines into the public domain);
  - SidMon (Reinier van Vliet) and SidMon II;
  - Digital Mugician and Mugician II (Reinier van Vliet too);
  - Delta Music 2.0, and Sonic Arranger (Carsten Schlote, Branko Mikić and Carsten Herbst);
  - TFMX and Jochen Hippel's seven voices;
  - the Sonix Music Driver (Mark Riley), of the music Aegis Sonix made;
  - David Whittaker's, Ben Daglish's (with Colin Dooley), Martin Walker's, Special FX's (Matthew
    Cannon and Jonathan Dunn) and the Maniacs of Noise's (Charles Deenen and Jeroen Tel) drivers;
    Richard Joseph's player (Richard Joseph and Andi Smithers); and Dave Lowe's (Uncle Art);
  - Sierra's AGI sounds, with the routines Sierra's interpreter for the Amiga played them with.
    NewRisingSun's recordings of King's Quest II on the PCjr and the Tandy 1000, at
    [vgmrips.net](https://vgmrips.net/), show how Sierra's interpreter wrote to their chip.
- The MaxTrax Music Driver by Talin (David Joiner) and Joe Pearce, which The Dreamers Guild licensed
  to game developers and which was later released under the LGPL, as UADE carries it: ported here.
  [ScummVM](https://www.scummvm.org/)'s player of it is what it was checked against, and the tempos
  Legend of Kyrandia gives its scores come from it.
- MED and OctaMED are by Teijo Kinnunen, and the MED module is as he describes it in the format notes
  that came with OctaMED. The MED4 file, and the MMDC file packed for games, are as libxmp's authors
  read them. The players of MED modules here, and the mixing, are siday's own: nothing in them is
  taken from OctaMED's, which they were written to match.
- SoundFX is by Christian Haller and Christian A. Weber (Linel, 1988), and Oktalyzer by Armin Sander
  (1989). Their modules are as Claudio Matsuoka (for libxmp) and Harald Zappe wrote them down. The
  players of both here are siday's own: nothing in them is taken from the trackers' routines, which
  they were written to match.
- [ahx2play](https://github.com/8bitbubsy/ahx2play), also by Olav Sørensen: AHX's replayer and the
  making of its waveforms, ported by him from the tracker's own source. AHX is by Martin Wodok
  (Dexter) and Manfred Linzner (Pink) of Abyss.
- [HivelyTracker](https://github.com/pete-gordon/hivelytracker) by Pete Gordon (Xeron of IRIS): its
  replayer and mixer, and the HVL format. The replayer began as his port of AHX's, and others have
  fixed it since, kode54 and passing_by among them.
- libdigibooster3 by Grzegorz Kraszewski, published by APC&TCP: DigiBooster 3's replayer and its
  reading of DBM files, which plays DigiBooster Pro's modules too. DigiBooster Pro is by Tomasz and
  Waldemar Piasta, and DigiBooster 3 by Grzegorz Kraszewski with APC&TCP.
- The files are as [UnExoticA](https://www.exotica.org.uk/) keeps them. UADE, by Heikki Orsila and
  Michael Doering, runs an Amiga's own music players in an emulated Amiga, and can record everything
  they tell the sound chip and everything it plays. It is what most of the Amiga's players here were
  held to: OctaMED's three players, SoundFX's routine (as Wanted Team fitted it for DeliTracker) and
  Oktalyzer's (as Buggs of Defect did) among them.

### PC trackers

- Olav Sørensen's replayers, each ported by him from the tracker's own code:
  - [ft2play](https://github.com/8bitbubsy/ft2play): FastTracker 2's replayer and mixer (FastTracker
    2 is by Fredrik Huss and Magnus Högdahl, of Triton);
  - [st3play](https://github.com/8bitbubsy/st3play): Scream Tracker 3's replayer, its Gravis
    Ultrasound driver, Sound Blaster mixing and AdLib driver, and the emulation of the GUS's sound
    chip (Scream Tracker 3 is by Sami Tammilehto, Psi of Future Crew);
  - [it2play](https://github.com/8bitbubsy/it2play): Impulse Tracker 2's replayer, the reading of IT
    files, and a sound driver of his own (Impulse Tracker is by Jeffrey Lim).
- [st2play](https://github.com/viiri/st2play) by Sergei "x0r" Kolzun: Scream Tracker 2's replayer and
  mixing, which he ported from the program, version by version. Scream Tracker 2 is Sami
  Tammilehto's too.
- [OpenMPT](https://openmpt.org) by Olivier Lapicque and the OpenMPT developers, and
  [libxmp](https://github.com/libxmp/libxmp) by Claudio Matsuoka, Hipolito Carraro Jr and those who
  have kept it since: how the files of many trackers are read, what those trackers meant by their
  commands, and the few ways in which OpenMPT plays them differently from the replayer they are
  converted for. libopenmpt (and for some formats libxmp) is the player those files were checked
  against. They are:
  - MTM, DTM and AMF (MultiTracker by Daniel Goldstein of Renaissance; Digital Tracker, Softjee's;
    DSMI by Otto Chrons);
  - MPTM, OpenMPT's own;
  - GDM (as MenTaLguY describes it; BWSB and its converter by Edward Schlunder) and PTM (as JAL of
    Nostalgia describes it; PolyTracker by Lone Ranger of AcmE);
  - 669 and FAR (Composer 669 by Tran of Renaissance; Farandole Composer by Megan Potter), and C67;
  - ULT (as FreeJack of The Elven Nation describes it; UltraTracker by Marc André Schallehn), read
    after both, and for what goes where when a note has two commands, after neither;
  - MT2 (MadTracker, by Yannick Delwiche);
  - IMF (Imago Orpheus, by Lutz Roeder), which OpenMPT took from Storlek's loader for Schism Tracker;
  - AMS of either kind (Extreme's Tracker and Velvet Studio, by Extreme, later Velvet Development);
  - MDL (Digitrakker, by Prodatron), its samples unpacked as the description that came with the
    program has it, which libxmp quotes;
  - Symphonie and Symphonie Pro (Patrick Meng), read and their samples made as Devin Acker and the
    OpenMPT developers do, after Patrick Meng's own player and source;
  - DMF (X-Tracker, by D-Lusion);
  - J2B (the Galaxy Sound System, by Carlo Vogelsang, and Jazz Jackrabbit 2's music), after kode54's
    reading for his DUMB; its zlib packing unpacked as ancient does it, and checked against the
    system's zlib;
  - PLM (Disorder Tracker 2);
  - DSM of the Digital Sound Interface Kit (by Carlos Hasan);
  - DIGI (DIGI Booster, by Tomasz Piasta);
  - PSM of Epic MegaGames' MASI (Joshua Jensen's sound system; music by Robert A. Allen among
    others);
  - FMT, of which all that is written down is OpenMPT's loader (FM Tracker and its format are Davey W
    Taylor's).

### PC sound cards and chips

- [Nuked OPL3](https://github.com/nukeykt/Nuked-OPL3) by Nuke.YKT: the Yamaha OPL3, the FM chip of
  the AdLib and Sound Blaster cards, as exact as its author could make it from the chip itself. The
  chip's ROMs were read out by Matthew Gambrell and Olli Niemitalo.
- [fmdrv](https://github.com/viiri/fmdrv) by Sergei "x0r" Kolzun: SBFMDRV, the driver that played CMF
  files on a Sound Blaster, ported by him to C from the driver itself. The driver and the CMF format
  are Creative's.
- [AdPlug](https://github.com/adplug/adplug) by Simon Peter and others: its player of ROL files, by
  OPLx, and AdLib's sound driver as OPLx, Stas'M and Jepael have it there, from the code AdLib gave
  programmers. Visual Composer, the ROL format and the first bank of instruments are AdLib's; the
  instruments built into the player are theirs and those of the many people who added to that bank.
- [libvgm](https://github.com/ValleyBell/libvgm) by Valley Bell: the player VGM files were compared
  with. From it come how a file's volume and its chips' volumes are read, when a write is made, and
  how its streams of samples are written and its blocks of them unpacked. None of its own code is in
  the player.
- [SAASound](https://github.com/stripwax/SAASound) by Dave Hooper, with Simon Owen: the Philips
  SAA1099, the chip of the SAM Coupé and of the Creative Music System, as its author revised it after
  the study of the chip by the DOSBox team and others.
- [MAME](https://www.mamedev.org/)'s emulation of the SN76489 and the chips like it, by Nicola
  Salmoria and others, as libvgm has it: the chip of the PCjr and the Tandy 1000. How their noises
  differ was found by Lord Nightmare, Michael Zapf, PlgDavid, Valley Bell and NewRisingSun, among
  others, from the chips themselves.

### What it is built with

[swift-argument-parser](https://github.com/apple/swift-argument-parser) for the command line, and
[ElementaryUI](https://elementary.codes) and [JavaScriptKit](https://github.com/swiftwasm/JavaScriptKit)
for the page in the browser.
