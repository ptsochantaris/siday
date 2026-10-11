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

**On the command line:** point it at files or folders. See [On the command line](#on-the-command-line).

```
siday ~/Music/chiptunes --shuffle
```

## What it plays

| Family | Formats |
|---|---|
| AY-3-8910 / YM2149 tracker modules | PT3, PT2, PT1, STC, STP, ASC, PSC, SQT, FTC, FXM, PSM, GTR, and TurboSound pairs |
| AY register recordings | VTX, YM (YM2, YM3, YM3b, YM5, YM6). A YM file from an Atari ST is played on the ST's chip, with the effects ST musicians made between one set of registers and the next (SID voices, digi-drums, sync-buzzer) |
| Atari ST sample tunes | the two kinds of YM file that are samples and not registers: digi-mixes (MIX1) and YM tracker tunes (YMT1, YMT2) |
| ZX Spectrum and Amstrad CPC program rips | AY (ZXAYEMUL), including beeper music |
| Atari ST and STE program rips | SNDH, packed with Ice or not: the sound chip with the timer effects ST musicians got out of it (SID voices, digi-drums, sync-buzzer), and the STE's samples |
| C64 | SID (PSID and RSID) |
| Amiga modules | MOD of four channels: ProTracker's, and those of the trackers it descends from and sat beside (Soundtracker's files of 15 samples, NoiseTracker, Startrekker), packed with PowerPacker or not. Played by ProTracker's own replayer on the Amiga's sound chip, in stereo. MED, the modules of MED and OctaMED (MMD0 to MMD3), with all the songs of a file that has several, its synthetic and hybrid sounds, and all three of its ways of playing: on the Amiga's own four voices; with five to eight tracks mixed in pairs into those voices, as crudely as OctaMED mixed them; and in OctaMED Soundstudio's mixing mode, of up to 64 tracks with samples of sixteen bits and in stereo, each track where the song puts it between the speakers. Played as OctaMED's players played them, the first two on the same chip. AHX, the files of a tracker that has no samples and makes its instruments up as it plays, played by AHX's own replayer on the same chip. HVL, the files of HivelyTracker, which is AHX carried on to sixteen voices, each with its own place between the speakers, played by HivelyTracker's own replayer and mixer. SFX, the modules of SoundFX, a tracker of the Amiga's first years, with fifteen samples and a tempo that is a count for the Amiga's timer, and all the songs of a file that holds several. OKT, the modules of Oktalyzer, of four to eight tracks: each voice of the chip is whole or is split in two, and the two tracks of a split voice are mixed into it as Oktalyzer mixed them; packed with PowerPacker or not. Both played as their trackers' own routines played them, on the same chip |
| PC modules | XM, FastTracker 2's own format, and MOD files of more than four channels, played by FastTracker 2's replayer and mixer. S3M, Scream Tracker 3's format, played by Scream Tracker's replayer on either of its sound cards, the Gravis Ultrasound or the Sound Blaster Pro, with the AdLib card beside it for FM channels. IT, Impulse Tracker's format, played by Impulse Tracker's replayer, with its instruments, its many voices to a channel and its resonant filter; and an IT file that ModPlug Tracker or OpenMPT made is heard through those of its plug-ins that are OpenMPT's own |
| Modules of other trackers, on FastTracker 2's replayer | MTM, the modules of MultiTracker; DTM, those of Digital Tracker, from the Atari Falcon, with its samples of eight bits and sixteen at rates of their own; and AMF, the form that DSMI and its Dual Module Player turned every module into (versions 1.0 to 1.4 and those before). This player has no replayer of any of the three: each is read into what FastTracker 2 plays and played by its replayer and mixer, every channel in its own place between the speakers |
| Modules of other trackers, on Impulse Tracker's replayer | GDM, the files of the BWSB sound system, each of them another tracker's module (an S3M, a MOD, and others) written out again; and PTM, the modules of PolyTracker, with up to 32 channels, samples of sixteen bits and loops that go back and forth. This player has no replayer of either: each is read into what Impulse Tracker plays and played by its replayer, every channel in its own place between the speakers |
| OpenMPT's own modules, on Impulse Tracker's replayer | MPTM, the format OpenMPT keeps for what an IT file has no room for: an IT file with more written after it. Played by Impulse Tracker's replayer, which has been given what such a file asks beyond an IT file as far as that can honestly be given: OpenMPT's three ways of keeping time, its swing, tempos that are fractions or above 255, patterns of up to 1024 rows, lists of patterns of any length and several to a file (which are its songs), longer envelopes with a place to go when a key is let go, a filter that lets the high through, samples played backwards and from cue points, and OpenMPT's louder way of adding channels up. An instrument that is a patch for the AdLib's FM chip is played on that chip, as OpenMPT plays it. The plug-ins that are OpenMPT's own (its echo, two reverbs, chorus, flangers, compressor, distortion, equaliser and gargle, and DigiBooster's echo) are played, wired as the file wires them; a plug-in that is somebody else's program is left out, and an instrument that is only such a plug-in is not heard |
| AdLib and Sound Blaster FM tunes | CMF, Creative's music files for the Sound Blaster, played by the driver that came with the card. ROL, the piano rolls of AdLib's Visual Composer, played by AdLib's sound driver, with the instruments of the bank beside the file or of the bank built into the player. FMT, the songs of Davey W Taylor's FM Tracker, a tracker of eight voices for the AdLib card, played as OpenMPT reads them |

Not supported: RSID tunes that need the C64 BASIC ROM, and Compute!'s Sidplayer (MUS) data.
A few RSID tunes that depend on exact video or serial-port timing will not play correctly.
An SNDH tune that sends its notes out of the MIDI port has nothing to play here, and of some 5,900
SNDH files tried, a handful do not start; the reference player does not start them either.
A MOD file packed with XPK is not unpacked. A song that MED saved before it had modules (MED2, MED3,
MED4) is not read, and a MED module's notes for a MIDI synthesiser are not heard. A module of the later SoundFX, of 31
samples, is not played. An XM file written by a later tracker is played as
FastTracker 2 would play it, which is not always what the tracker that wrote it meant. An IT file
packed with MMCMP is not unpacked, and a sample that ModPlug Tracker packed its own way (ADPCM) is
silent. A ROL file that names an instrument no bank has is played with that instrument silent.
A DTM file saved by Digital Home Studio, Digital Tracker's successor, is not read, and nor is the
other kind of file called AMF, ASYLUM's.
An MPTM file, or an IT file of ModPlug Tracker's or OpenMPT's, is played without those of its
plug-ins that are not OpenMPT's own: what was sent through one is heard as it is. An XM file of
theirs is played without any of its plug-ins. An MPTM file whose notes are, half of them or more,
for instruments that are only such plug-ins, or for samples kept in other files, is not played. Nor
is one with an instrument tuned to a scale of its own, unless the scale is a temperament: twelve
steps to the octave, none of them more than a quarter of a semitone from where equal steps would
put it. Then each note is started at the pitch the temperament gives it, and its slides are
Impulse Tracker's.

Between a file that is played as it was written and one that is refused there are files that are
played with something missing or made do for: an instrument that a later tracker played through a
plug-in or sent to a MIDI synthesiser, a command that the tracker whose replayer plays the file never
had, a sample in stereo or packed in a way that is not read, a file that ends before its last sample
does. Such a tune says so, in a sentence for each thing: "Three of its instruments play through
plug-ins, and are not heard." The page puts a small ≈ beside its name, and the command line prints the
sentences under the tune's line (see below). Only what the tune itself uses is said, and only what
might be heard: a file is not marked for where it was made, nor for a few bytes lost from its end.

## In a browser

[ptsochantaris.github.io/siday](https://ptsochantaris.github.io/siday/) is the player as a web page,
and `Web/` is where it comes from. It is Swift too: the emulators and the page itself are compiled
to WebAssembly.

- Drop tunes or a whole folder on it, or choose them, and it plays them. Nothing is uploaded: the
  files are read where they are and never leave your computer.
- A tune with several songs lists them, by name where the file names them, and plays them in turn,
  passing over those of a few seconds: the sound effects and jingles many files keep beside their
  music, which are still there in the list to be pressed.
- A spectrum analyser follows what is being heard, and under it is a light for each voice of the
  tune, which glows as bright as that voice is loud.
- Press anywhere on the time bar to move there, in either direction.
- SID tunes know their lengths: those of the High Voltage SID Collection are built in.
- A tune that is not played quite as its file asks has a small ≈ beside its name. Rest the pointer
  on it to read what is left out or made do for, or press it to have that written out under the
  tune's details, where it stays for the tunes after it until it is pressed again. Once such a tune
  has been played, its row in the list keeps the mark.
- The list shows every tune that was added, however many, and can be searched. The cross at the end
  of a row takes that tune out of the list, and "Remove all" empties it. The buttons that add files
  or a folder are at its foot, and while it is empty it says how tunes are added.
- It has a volume of its own, apart from the computer's, which it remembers.
- One list chooses what a tune is heard through: mono, stereo (a module's own, or the AY chip's
  channels spread out), or the speaker of an early-1980s television. It is remembered too.
- Small buttons in the player's corner put the spectrum analyser, the lights and the list of tunes
  away and bring them back, for as much or as little to look at as is wanted. That is remembered as
  well.
- A fourth of them brings out a picture to listen by: a lava lamp, a mirror ball, an aurora, a pond,
  a fire, a fountain or rain. It is away until it is asked for.
- A fifth opens the settings: the command-line player's options, for how long tunes are played and
  on what. They are remembered, and one button puts them all back.
- The keys are the command-line player's.

Press anywhere on the time bar to move to that place in the song; the pointer shows the time it is
over. A song is rendered to its end as soon as it starts, far faster than it plays, and the bar
shades in behind as it goes: anywhere in the shaded part is reached at once, and a place beyond it
as soon as the rendering gets there.

The settings are the options of the command line (see the table below), each a list to choose from
or a slider, with what it does to be read by resting the pointer on it: how many times a tune that
repeats is played and how long its fade is, the time given to a tune of unknown length and the
longest any tune may play; the AY chip's make, its clock, how often the tune's player is run, and which way round its
three channels go in stereo (the command line's `abc` and `acb`, which the page's list of outputs has as one "Stereo"); the
SID's model, its emulation and where the 6581's filter sits; which Amiga a module made for one is heard on
and how far apart its two sides are (a MED in mixing mode has no Amiga in it, and its own two sides), and the sound card of an S3M. One that has been changed is marked with
a dot. A change is heard at once: the song that is playing is rendered again as it is now to be,
when the setting has anything to do with it, and goes on from where it was. Two settings are the
page's own, and are about a file with several songs. Its songs can all be played in turn, which is
how it comes, or only the one the file names as its main song, as the command line does. And when
they are played in turn, songs shorter than five seconds are passed over, or than some other
length, or none are: a game's file often has a tune or two and a dozen sound effects. So is a song
of a module in which no note is played, however long it is: a stretch of empty patterns at the top
of a file, kept there to hold its samples or for no reason at all. Passed-over
songs are fainter in the list and can still be pressed, and a file with nothing longer in it plays
them all.

The lights are the lamps of an early-1980s tape recorder's recording level, one for each voice: an AY
chip's three channels (six for two chips), a SID's three voices, the Atari's three, each channel of a
module, each of the FM chip's nine voices. What a light shows is its voice by itself, measured where
the sound is made, before the voices are mixed: how far the voice swings, in decibels, over the last
fiftieth of a second. (A SID's voices are the exception: they go by their envelopes, since the chip
mixes them before there is anything to measure.) A module shows the channels its patterns use. Some
voices are ones a tune may never use, and get a light only once they are heard: the ZX Spectrum's
beeper, the samples a SID tune plays on the volume, the samples of an Atari STE; and since many
Spectrum tunes are for the beeper alone, an AY file's three channels too. Measuring costs nothing
that can be heard and little that can be timed: the sound is the same to the sample, and rendering
is slower by nothing for a SID tune, a thirtieth for a Spectrum's and at most a seventh for a module's,
which is rendered some hundreds of times faster than it plays.

The picture to listen by is for watching while a tune plays, and is made from what the tune's voices
are doing and not from the sound they add up to: how loud each is, the pitch it is at, and the notes
it starts, all of which the player knows because it is playing them. In the lava lamp each voice is a
blob of wax, which swells as the voice gets louder, floats higher the higher its note, and sinks back
into the pool when it falls silent. The mirror ball turns slowly at the top of a dark room and throws its
spots across the wall in rows. Each voice has a height on the wall of its own, and the colour of its
light is the note it is playing, by how high it is among the notes of the tune, as the flame's is;
where two voices' lights fall together their colours add, towards white. In the aurora each voice is a
curtain of light drawn at the right of a night sky, higher for a higher note, that drifts away to the
left. The pond is water at night, seen from above: a note being struck is a drop falling into it, low
notes to the left and high ones to the right (the lowest and highest eighths of the tune's range
each fall in one place, as they are one colour in the flame, so that a melody is spread wider across
the water), and its rings spread and cross and come back off the
banks; a held note keeps the water trembling, and each voice leaves its colour in it. The water is
real in a small way, a grid of heights moved on by the rule that makes a wave. The flame is a row
of lamps on fire: each voice is a round lamp, in a row like the player's lights, as large as the
voice is loud and the colour of its note, by the colours of the analyser's bars: red for the lowest
the tune plays, round to violet for the highest, and pale for a drum. (The lowest notes of a tune
are all the one red and the highest all the one violet, an eighth of its range at each end, so that
the notes between, where the melodies are, are further apart in colour.) Flames rise slowly from
each lamp in its colour and out of the top of the picture, so the notes a voice has played are bands
of colour above the one it is playing. They are made the oldest
way there is, the heat at each place being the mean of the heat below it, less a little. The
fountain sends a light up from the middle of the bottom of the picture for every note that is
struck, as a firework goes up, though nothing bursts: to come down at a place come by chance, as
high as the note is loud, and in the note's colour, as the flame's lamps are. Each is a small light with a short tail, which
slows, turns over and falls away. A voice sends up no more than eight a second. The rain lets a
drop fall for every note that is struck, straight down from a place along the top come by chance.
Where it meets the bottom it bounces, as high as the note is loud, to the side the tune has the note
on (the left or the right as chance has it, for a note in the middle or a tune with no sides, and
whatever the tune is being listened to through), and as fast sideways as the note is high; it turns
back at the sides, and each bounce is some half as high as the last, and a little dimmer, until it
falls out of the picture. A drop is in the note's colour,
and is drawn as the way it has come in the last moment: a thin line with round ends, as bright at
its tail as at its head, long where the drop is fast and bent where it has just bounced. It is meant to be calm.
Nothing in it changes at once: a voice is followed a little behind, so the loudest note there is
brightens the picture over several frames and not in one; the kind of picture never changes of its
own accord; and its colours change, in all but the flame, the fountain and the rain, where a note's colour says
how high it is, only by themselves and too slowly to see: once round the colour wheel in
five minutes or more. It can fill the screen (the button, or `f`), where its controls and the pointer go out of
sight when the pointer is left still. The picture is painted in Swift like everything else, a small
one of some 370 dots by 210 that the browser stretches, which is what makes it soft; a frame takes
about a millisecond.

The spectrum analyser and the lights are held back by as long as the browser says the sound takes to be heard, which
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
what is installed), and nothing else: no Node, no packages to install. If Binaryen's `wasm-opt` is
installed (`brew install binaryen`), both modules go through it: the page's comes out a little over
half the size and the engine's a tenth smaller, a quarter and a twentieth once compressed. That is all
it buys. Measured on a SID, an AY, a tracker and an Atari ST tune, the engine renders no faster for it,
and what it renders is the same to the sample.

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
chosen files and the audio graph. All told it is about 1.5 MB compressed, the song lengths of the High Voltage SID Collection being some 550 kB of that and the AdLib instruments some 120 kB.

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
siday <files or folders…>
```

Folders are searched recursively and files are recognised by extension. The files are only ever read.

While playing: `space` pause · `n` or `→` next · `p` or `←` previous · `+` / `-` (or `↑` / `↓`) subsong ·
`q` quit.

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
| `--wav folder` | Render to WAV files instead of playing (existing files are not overwritten) |
| `--list` | Show what would be played, with format, length and title. A `*` after the length marks a tune that is not played quite as its file asks |
| `--shortfalls` | With `--list`, say under each marked tune what it is that is left out or made do for |
| `--check` | Load and render a few seconds of every file silently and report per format; the last column counts the tunes `--list` would mark |
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
  found before it: another beginning for a tune goes on as the tune does. A piece that only leads
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

Where a reference player and Ay_Emul's source disagreed, the source was followed. Three deliberate
departures from Ay_Emul are marked in the code: old-format PSC modules start with version-correct sample
and ornament tables; an AY file only counts as Amstrad CPC once it writes a register through the CPC's
ports; and the AY player stub is placed after the file's memory blocks rather than before.


An Atari ST tune is the program that played it, so the machine is there to run it: a 68000, four
megabytes, the sound hardware, and the few things such a program asks of the operating system. It is
AtariAudio's design, and a light one. The tune's code is called and runs to its end in no time, once
for each tick of its player and once for each interrupt of a timer it has set going, and the timers
are moved on a sample of the output at a time. The sound chip here is not the one the Spectrum's tunes
use: the ST ties the chip's three outputs together, so their level is looked up in a table recorded
from the machine and not added up. One thing is done differently from AtariAudio, and only on the way
out: the chip's 250,000 steps a second come down to the output's rate through a low-pass filter and
not a plain average, which keeps out tones that were never played. `siday --raw file.raw tune.sndh`
writes the plain average, which is what agrees with AtariAudio to the sample.

A module is played as ProTracker played it. The replayer is ProTracker 2.3D's, by way of pt2-clone's
port of it to C, and keeps ProTracker's mistakes, because tunes were written by ear against them. What
it would have told the Amiga's sound chip it tells an emulation of that chip, Paula: four voices
reading eight-bit samples out of memory, each at a rate of its own. Paula is run at 96,000 samples a
second, with each step in her output replaced by one that holds nothing above the range of hearing,
then through the filters the Amiga has on its way to the socket, and then halved. Two of the voices
are wired to the left and two to the right with nothing in between. Through loudspeakers a room mixes
the two; in headphones nothing does, and it is harsh. So a module in stereo (`--output abc` or `acb`,
which are the same thing to a module) has its two sides brought most of the way together, to a fifth
of the Amiga's separation, which is what pt2-clone does unless told otherwise;
`--amiga-separation 100` gives the Amiga's own, and mono or a television brings them together entirely. Files from other trackers of the family have the few effects they meant differently turned
into ProTracker's as they are read. One effect is left out, as it is in pt2-clone: E8x, which filters
a sample in place, because nearly every module that has it means something else by it. ProTracker has
room for 64 KB of each sample and plays no more of a longer one. No file of its own has one, but
files from other trackers do, since the Amiga's sound chip can be told to play twice that and the
routines that played modules outside the tracker did so: a longer sample is played whole. A tune ends
where it would play a row it has played before. `siday --raw file.raw tune.mod` writes the tune as
pt2-clone writes one to a file, sixteen bits with its dither and a long sample cut off where ProTracker
cuts it, and the two agree to the sample.

A MED module is played as OctaMED played it. The players here are not ports: OctaMED's own are not
free to copy, so these were written afresh and then held to them. OctaMED's players were run in an
emulated Amiga (UADE) on every MED module of a collection, and what they did was set beside what
these do, in whatever each way of playing leaves to be seen.

A module for the Amiga's four voices is played on the same emulation of Paula as a MOD file, with
the same filters and the same bringing together of its two sides. There the two are compared in
everything written to the sound chip's registers: each voice's period and volume on every tick,
where each note starts in its sample and where it goes on from, and how long each tick lasts. A
module has two halves to its tempo, how fast the ticks come and how many of them a line lasts; the
first is either a number that sets the Amiga's timer or beats a minute, and both are kept by the
timer's own arithmetic. Notes can be held for a time and then left to fade, an instrument can be a
sample recorded at several octaves, and a block can be any number of lines long with several commands
to a note. An instrument need not be a sample at all. A synthetic sound is a few short waveforms and
two lists of instructions, one for its volume and one for its waveform and pitch, that are carried on
a step on every tick: it can swap its waveform, slide, play a run of notes, take a waveform for the
shape of its volume or its vibrato. A hybrid sound is such lists played on a sample.

With five to eight tracks there are more tracks than voices, and OctaMED mixed them in pairs, each
pair into a stretch of memory that one voice then played, a tick's worth at a time; the length of the
stretch is the tempo. It mixed as a 7 MHz machine could: no smoothing, no room for two loud samples
at once, and a sample that would end during a tick is cut off before it. That is mixed here in the
same way and played through the same Paula, and what is compared is every byte the chip is given:
they are the same bytes. (A song of five, six or seven channels leaves some voices a track to
themselves. OctaMED's own player then put what it mixed for the others in the wrong place; here it
is put in the right one, which is the one thing in this mode that was not checked against it.)

Mixing mode came with OctaMED Soundstudio: any number of tracks up to 64, samples of sixteen bits
and in stereo, each track placed where the song says between left and right, an echo, and the two
sides drawn together or pushed apart. Soundstudio played that through whatever it had, a sound card
as readily as the Amiga's eight bits, so there is no one sound to imitate, and the mixing here is
siday's own: at the rate of the output, smooth between samples. What a song says is kept (how loud
each volume is, how a place between the sides divides a track, where a sample ends and goes round,
the echo's length and depth) and the player is OctaMED's player, where pitch is so many samples a
second and a slide is still so many of the sound chip's periods. To check the player, what it tells
its mixer is written down and played again through the arithmetic of OctaMED's own mixing, eight
bits and all, by a small program kept outside the package; what comes out is set beside what the
emulated Amiga's chip was given, and they are to be the same bytes. Three things that OctaMED's
player for this mode gets wrong are put right when listening, and done wrong only for that
comparison: it plays each track's first tick in silence, it takes no notice of a change of tempo in
the middle of a song, and it plays an instrument meant for a sound card a semitone sharp. And one
thing it does is not done: it made a sixteen-bit sample quieter only by halving it, so that such a
sample had seven volumes; here it has all sixty-four.

A file with several songs has them all as its songs, and each is looked through for more, as any
module is. `SIDAY_MED_TRACE=1 siday --raw /dev/null tune.med` writes what the player tells the sound
chip, a line a tick; or for five to eight channels what it mixes for the chip (the bytes go to the
file `SIDAY_MED_MIXED` names); or in mixing mode what it tells its mixer.

A SoundFX module is played as SoundFX played it, and an Oktalyzer module as Oktalyzer did. As with
MED, the players are not ports: the trackers' own routines are not free to copy, so these were
written afresh and then held to them. The routines were run in an emulated Amiga (UADE) on every such
module of a collection, 283 of SoundFX's and 42 of Oktalyzer's, and on some hundreds of modules made
at random to use what those do not, and everything they wrote to the sound chip's registers was set
beside what these write: each voice's period and volume, where each note starts in its sample and
where it goes on from, in the order they were written and on the ticks they were written on. They are
the same, for every one of those modules from its beginning to its end.

SoundFX is of 1988, and its module is the first Soundtracker's with a different front: fifteen
samples, patterns of 64 lines, and in place of a tempo the number that the Amiga's timer is to count
from between one tick and the next, with six ticks to a line. Its routine has ways of its own, and
tunes were written by ear against them, so they are kept. A slide towards a note goes on over the
lines that follow until a new note stops it, and no other command of its voice is looked at
meanwhile. A bend works on the period written on its own line, so that on a line without a note it
starts from nothing. A volume command counts from the instrument's volume, and only where the
instrument is named beside it. Every voice is told again on every line where its instrument repeats,
so that naming another instrument under a note changes what the note goes on with. A file that was
made to hold several tunes has them set apart by a pattern of silence, and those are its songs here,
found much as the player of these files for DeliTracker finds them. Four files of the collection are
shorter than their samples are said to be: the routine's own loader will not have them, and here they
are played, with silence where a sample is missing its end. One thing the routine does is not done:
an arpeggio on a voice whose last note is none of the notes sends it looking for a period through
whatever lies after its table, and here the voice is left as it is.

Oktalyzer, of 1989, got eight tracks out of the Amiga's four voices. A voice is whole, and plays a
track as any tracker would; or it is split, and has two tracks, which are mixed a tick's worth at a
time into a stretch of memory that the voice then plays. Oktalyzer had a quick way of mixing two
notes at two pitches, which is to step through only one of them. The voice is played at the period of
the higher note, whose sample can then be taken a byte for a byte, and the lower note is stretched to
fit; when the notes change, so do the voice's period and how many bytes make a tick. The two are added
four bytes at a time, as one number, so that a byte which overflows carries into its neighbour, and
samples for a split voice are made at half strength so that they do not. A split voice has one volume
between its two tracks, its samples never repeat, and it goes no higher than the A of the top octave.
All of that is done here as Oktalyzer did it, and for the seventeen modules of the collection that
have split voices what is compared is also every byte the chip was given to play, wherever it can be
told from what the emulated chip put out (which is the byte times the voice's volume: so not while
the volume is nought, nor in the moment it changes, which leaves nineteen parts in twenty of the
time). They are the same bytes, some two hundred million of them.

Two things have to be said of that. How long a stretch is mixed on a tick depends on whether the chip,
which keeps its own time, has got ahead of the player's timer; and in the emulated Amiga that turns
on a clock or two, on how many instructions the routine happened to run on the tick before. So when
it plays, this player reckons the chip's time itself, in whole clocks as the Amiga kept it, and comes
to the same length as the routine on three ticks in four (on the others a stretch is a word longer
or shorter a tick sooner or later: the same run of lengths, a tick out of step); and for the
comparison it is given the lengths the routine was seen to choose. And Oktalyzer began to fill a
stretch of memory again when the chip might not yet have fetched its last words. On an Amiga the
mixing took most of a tick to get that far; UADE runs this routine with every instruction taking one
clock, and there the chip now and then plays the last word or so of a stretch from what has just been
written over it. That is passed over in the comparison, and counted (one stretch in 260), and it does
not happen here, where a voice has a third stretch to mix into.

`SIDAY_SFX_TRACE=1 siday --raw /dev/null tune.sfx` and `SIDAY_OKT_TRACE=1 siday --raw /dev/null
tune.okt` write what the players tell the sound chip, a line a tick. What Oktalyzer's mixes goes to
the file `SIDAY_OKT_MIXED` names, and `SIDAY_OKT_WORDS` names a file of the lengths it is to go by.

An AHX file is played as AHX played it. AHX is a tracker for the Amiga with no samples. An instrument
is a few numbers: an envelope, a vibrato, and a short list of things to do as its note goes on, which
is where it says what wave it is (a triangle, a sawtooth, a square of some width, or noise) and can
change it, play notes of its own, slide, and set the square's width or the filter sweeping. From those
the tracker makes the sound as it plays: each of Paula's four voices goes round a buffer of 640
bytes, and fifty times a second, or a hundred or more if the file asks, whatever wave a voice is to
have next is copied into its buffer. The filter is not a filter at work on the sound. The tracker
works out its waves when it starts, and with them 62 more sets of the same waves, each already put
through a low-pass or a high-pass filter set a little differently, and an instrument that sweeps its
filter is choosing from one moment to the next which set to copy from. All of that is here as the
tracker did it, in whole numbers, by way of ahx2play's port of the replayer of AHX 2.3d-sp3 to C, and
with its mistakes: a note moved below the lowest there is takes its pitch from what the Amiga had in
memory before its table of pitches, and a list told to wait 128 ticks between its entries does not
wait at all, which there are tunes that count on. Paula is the one MOD files are played on, with the
same two Amigas to hear her through and her two sides brought together in the same way. A file says
where each of its songs starts; a song ends where it would play a row it has played before, or where
it stops itself. `siday --raw file.raw tune.ahx` writes what ahx2play writes to a file, which is
Paula at the rate of the output with nothing after her, at ahx2play's loudness and with its dither,
and the two agree to the sample: on a quarter of an hour of each of the 858 files tried, and on
three minutes of every other song in them.

A HivelyTracker file is played as HivelyTracker plays it. HivelyTracker is AHX carried on, by other
hands and off the Amiga: the same instruments and the same waves, to the byte, but as many as sixteen
voices where the Amiga had four, two commands on every row of a track where AHX had one, and more for
an instrument's list to do. Each voice has a place between the speakers, which the file sets for all
of them at once (from all in the middle to the Amiga's hard left and right), a track can move, and
an instrument can move for the length of a note. And an instrument can have its wave multiplied by a
second one, a triangle or a sawtooth at a pitch of its own, which is ring modulation. There is no
Amiga under it. The tracker mixes its voices itself, at 48,000 samples a second, each going round
its buffer of 640 bytes a byte at a time with nothing between one byte and the next and nothing
after, and that is what is heard here: the replayer and the mixer are those of HivelyTracker 1.9, as
they are in the players that come with the tracker, and the settings for the Amiga do not touch
them. A file says how loud it is to be mixed, and where that is more than sixteen bits can hold it
is clipped, as those players clip it. (The tracker itself lets it go round instead, so that its
composer hears that it is too loud.) The voices are where the file puts them unless the sound is
asked for in mono, which is the two sides together. A file's songs and their ends are found as an
AHX file's are.

`siday --raw file.raw tune.hvl` writes what the replayer makes, sixteen bits a side, and the two
agree to the sample: on a quarter of an hour of each of the 34 files tried, and on a minute of each of
1,800 songs in files made up at random to do everything the format can, which those 34 between them
do not. The same replayer plays AHX files, and with the variable `SIDAY_AHX_AS_HIVELY` set (to how
far apart the Amiga's two sides are to be, from 0 to 4) `--raw` plays an AHX file through it and not
through AHX's own: that way the two agree on three minutes of every song of the 858 AHX files as
well. (The `hvl2wav` that comes with the tracker is not what is compared with. It still has an older
replayer, from before the filtered waves and the noise were made to be AHX's own, and sounds a
little different.) What the replayer leaves to chance is settled here: a jump past the end of the
list of positions goes to its top, a track or a row the file does not have is empty, a note above
the five octaves there are has no pitch to slide from, and a wave other than the four there are is
silence.

An XM file, and a MOD file of more channels than the Amiga has, is played as FastTracker 2 played
it: the replayer and the mixer are FastTracker 2.09's, by way of ft2play's port of them to C. The mixer
works in whole numbers, with FastTracker's interpolation between one sample and the next and its
ramping of volumes, both switched on as they were when the tracker was new, and it places each
instrument between the speakers where the module says. FastTracker itself reads no more than 32
channels and only an even number; files from later trackers have any number, and are played the same
way. One thing is done as those later trackers did it. A sample can be in stereo in a file of theirs,
its two sides one after the other, and to FastTracker that is one long sample: here the two sides are
played together, mixed into one, since that mixer has no way to keep them apart. And they have a
command to sweep a channel from side to side, Y, with X5 to choose its wave, which is played as
OpenMPT plays it. That is for a file that gives itself away as another tracker's: by saying so, or,
where it says FastTracker as ModPlug Tracker's files do, by a name padded with nothing instead of
spaces or by what ModPlug Tracker writes after all that FastTracker reads. FastTracker lets any
letter be typed for a command, and in a file of its own a letter it has no command for is
nothing, as it was to FastTracker: often a mark for a demo to keep time by. A tune ends where it
would play a row it has played before. `siday --raw file.raw tune.xm` writes
what ft2play writes to a file, stereo samples as it has them, and the two agree to the sample.

An MTM, a DTM or an AMF file is not played as its own tracker played it. MultiTracker was a tracker
for the PC and the Gravis Ultrasound, Digital Tracker one for the Atari Falcon, and AMF is what
DSMI, the engine of the Dual Module Player and of many games, made of any module before it played
it. This player has no replayer of any of them. But all three are ProTracker's kind of module
with more channels, and FastTracker 2 plays that already, for a MOD file of eight channels. So each has a loader that reads it into the shape FastTracker holds a
module in, and FastTracker's replayer and mixer play it: with its slides, its vibrato, its arpeggio
and its way of placing a sound between the speakers, which are near to these trackers' own and are
not theirs. The replayer does four things for such a file that it does for no XM or MOD file. A
channel has a place between the speakers and stays where a command puts it, where FastTracker gives
a place to each sample. A sample plays at the rate it says it was recorded at, whatever the note
and whatever slides it. Setting the speed in an MTM file puts the tempo back to 125, and setting
the tempo puts the speed back to 6, which was MultiTracker's way and no other player's; a file that
sets both on one row was written for those other players, and is played their way. And a loop
inside a pattern does not leave the next pattern starting part of the way down, a mistake of
FastTracker's that its own files were written around and these were not. What FastTracker cannot be
told is left out: Digital Tracker 2.04 set how loud a channel was on each side, of which the place
between the speakers is kept and the loudness is not; a stereo sample in a DTM file is made one
sound; DSMI's surround sound is the middle.

There is no player of these trackers to be right against, so the check is against two that have
read these files for decades, libxmp and OpenMPT, and the loaders are written from theirs. What
each loader made of every file to hand, 394 MTM files, 92 DTM and 38 AMF, was set beside what
libxmp made of it, note by note and sample by sample (`SIDAY_FT2_LISTING=1 siday --raw /dev/null
tune.mtm` writes it out): 170 files come out the same, and every difference in the rest is one of
a few that were meant, each said in its loader, most of them where the two players read a file
differently and one had to be followed. Then a minute of every tune was played by all three, and
the loudness over time and the spectrograms compared. By that measure nothing plays a wrong note,
a wrong sample or at a wrong speed; the tunes furthest from both the others are those that lean on
what one player does and another does not, a sweep from speaker to speaker or two long samples
kept in step by their pitch. The pitch of a note is FastTracker's, from the Amiga's table of
periods, which is OpenMPT's too, to within two cents; libxmp works a note out afresh and is four
cents away on some, and plays an MTM file a sixth of a semitone lower besides, at the rate of a
European Amiga. And each kind is as loud as XM files are, by measure: the middle one of the files
of the kind is the middle one of 200 XM files.

An S3M file is played as Scream Tracker 3 played it, and that depended on the sound card. With a
Gravis Ultrasound the card did the mixing: the tracker told it, a tick at a time, what each voice was
to play, and the card played them smoothly, each in its place between the speakers, sliding from one
volume to the next. With a Sound Blaster Pro the tracker mixed for itself, into eight bits, with no
smoothing, at 22 kHz in stereo with eight channels hard to each side. Both are here, by way of
st3play's port of the tracker and its emulation of the cards. A file that Scream Tracker saved says
which card it was saved with, and is played on that one; any other is played on the GUS, and
`--s3m-card` asks for either. Scream Tracker's samples were eight bits and no longer than 64,000
bytes; files from later trackers have sixteen-bit and longer ones, which are played as they stand,
and samples tuned higher than Scream Tracker had room to write down, which are played at the pitch
they say and not at the highest Scream Tracker could have given them. They have samples in stereo
too, the right side after the left, of which Scream Tracker would play the left alone: the two are
played together, mixed into one, since its cards have no way to keep them apart. And they have
three commands that Scream Tracker passes over and the trackers after it play, in an S3M file as
in any: M, which sets a channel's volume, N, which slides it, and W, which slides the volume of the
whole tune. Those are played, as OpenMPT plays them, in a file that Scream Tracker did not save; in
one that it did save they are nothing, as they were to it and to whoever made the tune there.
`siday --raw file.raw tune.s3m` writes what st3play writes to a file, a stereo sample's left side only. The two agree to the sample when
the environment variable `SIDAY_REFERENCE_SLIPS` is set, which repeats one slip of st3play's that
Scream Tracker did not make: it loses the sign of a number on very high notes, and plays them wrong.

Nine of Scream Tracker's channels were not samples at all but voices of an AdLib card, the FM
synthesiser most PCs had before they had anything better, and there are S3M files that use them,
most of those with no samples at all. Scream Tracker's driver for the card is ported with the rest of it, and the
card's chip is an emulation of the Yamaha OPL3, a port of Nuked OPL3, which was worked out from the
chip's own ROMs and circuits. The OPL3 is the chip of the later Sound Blasters, and plays what was
written for the AdLib's own OPL2 as that did; it is here whole, with its drums, its four-operator
voices and its second set of registers, none of which Scream Tracker used. st3play has an OPL2 of
its own, so for these files the check is in two parts: the chip against Nuked OPL3 itself on streams
of register writes, and the tune against st3play with Nuked OPL3 put in place of its chip. Both agree
to the sample. Writes reach the chip no faster than a PC could make them, two samples apart, so that
a note let go and struck again in one tick is heard to be. The samples of a tune with FM in it are as
loud as in any other tune: st3play turns them down by a third at the card's first note, to leave room
for it.

An IT file is played as Impulse Tracker 2 played it, by way of it2play's port of its replayer: 64
channels, each of which can have many notes sounding at once, since an instrument says what becomes
of its note when the next one comes (cut, left to play on, released or faded), up to 256 voices in
all; envelopes for volume, place and pitch; and a resonant low-pass filter worked by an envelope or
by the Zxx effect. Pitch slides are worked out in whole numbers, as Impulse Tracker did before its
last version, which few people had. The sound is not from one of Impulse Tracker's own drivers,
which were written for the sound cards of the 1990s and cannot play a stereo sample, but from the
driver it2play adds to them: it mixes in floating point, reads samples through an eight-point
windowed sinc, ramps volumes so that notes do not click, and gives the filter the wider range
ModPlug Tracker gave it where a file asks for that. Compressed samples are unpacked.
`siday --raw file.raw tune.it` writes what it2play writes to a file, and the two agree to the sample.
Impulse Tracker has room for 100 samples, 100 instruments and 200 patterns, and it2play refuses a
file with more. Later trackers wrote such files, and they are played: up to 253 samples, 254
instruments and 254 patterns, which is as many as the format's single bytes can number. (Impulse
Tracker uses the numbers just past its hundredth sample to mean a note sent out by MIDI; for a file
with more samples those meanings are moved to the top of the range.) There is no reference to check
these against, since it2play does not play them.

Four other things are done differently. The filters start open, as they do in Impulse Tracker's drivers:
it2play leaves it to a line of the tracker's MIDI settings to open them, and a file that brings
settings of its own with that line blank is played with every filter shut, muffled from end to end
(the environment variable `SIDAY_REFERENCE_SLIPS` repeats that, for comparing the two). A sample that
is said to begin at the very end of the file has no sound, where it2play gives up on the whole file:
that is how ModPlug Tracker wrote an empty sample, in one file of twenty-five. A sample whose own
vibrato has the "ramp up" wave, which OpenMPT added and Impulse Tracker has not got, gets that wave,
where it2play reads past the end of its three. And where it2play would read sound from outside a
sample, which a few files lead it to do, there is silence.

And some things are done as the tracker that made the file did them, where that was not Impulse
Tracker. Two are commands. S9F plays a sample backwards, and S9E forwards again, in every tracker
that came after Impulse Tracker, to which they are nothing: they are played in a file that says
another tracker made it. And the command after Z in the alphabet is ModPlug Tracker's, a Z whose
macro is sent a little at a time, so that a filter slides over the row to where Z would have put
it at once: it is played in a file of ModPlug Tracker's or OpenMPT's. The third is about instruments.
An instrument can be given a MIDI channel, and Impulse Tracker then sends its notes to a synthesiser
and plays no sample for them. ModPlug Tracker and OpenMPT played the sample all the same, and their
composers often left a channel set, on the drums of a tune brought in from a MIDI file above all:
such a file, if it says one of those two made it, has those instruments' samples played, as its
composer heard them. And such a file is heard through its plug-ins, where they are OpenMPT's own:
ModPlug Tracker could send a channel or an instrument through the effects that came with Windows,
which OpenMPT has since built into itself, and some eight hundred IT files to hand do. They are
the same effects, wired the same way, as for an MPTM file (see below), and a plug-in that is
anybody else's is left out and said to be. Set beside libopenmpt, three hundred of those files
agree in spectrum to 0.983 for the middle one, where without the plug-ins it was 0.960. (An XM file
of those trackers can have plug-ins too, and is still played without them.) A file Impulse Tracker
made is played as Impulse Tracker played it, and `--raw`
writes every file so, to set beside it2play. The filter is the one place where the web
player and the Mac's do not agree to the last bit: each asks its own maths library for a power of two.

A GDM file and a PTM file are played by Impulse Tracker's replayer too, which is not their own: as
with the three kinds of file that FastTracker's plays for want of theirs, what is heard is another
tracker's reading of the tune. GDM was the one format of BWSB, a
sound system that DOS games were built with: nobody composed in it, and a GDM file is an S3M, a MOD
or some other tracker's module written out again by BWSB's converter, with up to four commands
beside a note. PTM was the format of PolyTracker, which set out to be a better Scream Tracker: 32
channels, samples of sixteen bits, loops that go back and forth. Neither BWSB's player nor
PolyTracker's is ported, and there is nothing here to say how either sounded to the sample. What is
done is what Impulse Tracker did with an S3M file: the file is read into Impulse Tracker's own shape,
its commands given as the letters that do the same, and played with "old effects" on. Each channel is
where the file puts it between the speakers. What was read from every such file to hand, 56 of them,
has been set beside what two other players read from it, libxmp and OpenMPT, whose loaders these are
made after; where it differs from libxmp's it is by choice, and where those two disagree the source
says which was followed and why. What is heard has been set beside libxmp's playing by measure, of
how the loudness goes and of the spectrum, which finds a wrong note or a missing channel and cannot
find a wrong nuance.

Some of what these files ask is not Impulse Tracker's to give. A PTM sample played backwards is
handed to it as a sample of its own, written out backwards. PolyTracker's slides by semitones are
played as smooth slides that get as far. Its volumes, which a Gravis Ultrasound did not space quite
evenly, are spaced evenly. Sliding by semitones and retuning a sample in the middle of a tune (E3x
and E5x in both) are left out, and so is any command of a GDM note's four that neither the one
command Impulse Tracker has room for nor its volume column can do. And two things are changed on the
way in, because Impulse Tracker alone would take them otherwise: an instrument named on a row with
no note is given as the instrument's volume, where Impulse Tracker would have played the note again,
and in a tune that began as a MOD a slide of nought does nothing, where Impulse Tracker's would go on
with the last.

An MPTM file is another matter, because the tracker that writes it is alive and plays its own files.
OpenMPT descends from ModPlug Tracker, which wrote IT files, and when it wanted more than an IT file
can say it kept the IT file and wrote the rest after it: so an MPTM file is an IT file, and Impulse
Tracker's replayer plays it. What is written after is read as OpenMPT reads it, and the replayer has
been given as much of it as it can honestly be given, each thing in a way that an IT file never
reaches. It keeps time in OpenMPT's three ways: Impulse Tracker's own; one where the tempo is ticks
in a second; and the "modern" one, where the tempo is beats in a minute and a beat is so many rows,
whatever the speed, with the rows of a beat swung longer and shorter if the song or the pattern says
so. A tempo can be a fraction, or above 255. A pattern can have 1024 rows, the list of patterns can
be longer than 256, and a file can have several lists, which are its songs. A command's value can
go on into the rows below it; a note can be delayed and cut by one command, started at a place its
sample names, and played backwards. An envelope can have more than 25 points, and a point to go to
when its key is let go. A filter can let the high through instead of the low. And a file can ask
for OpenMPT's own way of adding its channels up, which is twice as loud as Impulse Tracker's and
puts a channel that is to one side at no more than one in the middle.

OpenMPT has three more things that Impulse Tracker never had: FM, plug-ins and tunings.

Since 2018 an instrument of OpenMPT's can be a patch for the AdLib's FM chip in place of a sample,
and one file in seven to hand has such instruments. They are played, on the same chip as plays the
AdLib's own music here. The replayer plays an FM note as it plays any other, on a voice of its own
whose sample has no sound in it, so that all that can be done to a note is done to this one; and
after each tick the chip is told what OpenMPT would have told it: which of its eighteen voices the
note has, the patch, and from then on a pitch, a level and a side. OpenMPT's own chip is another
emulator of the same chip, so the sound is not its sound to the sample, but what is set in the
chip's registers can be put side by side, and was, tick by tick, for the first minute of every
such file. Of the notes sounding in libopenmpt 99.97% are sounding here with the same patch; their
pitch is the same number in 83% of ticks, within two of the chip's steps in 94% and within two
hundredths in 99%; the level of the operator that is heard is within one step of 63 in 98.7%. What
is left is not the chip's doing but the replayer's, which is Impulse Tracker's: a vibrato that
starts from another point of its wave, an envelope a tick ahead, a note bent by a command that is
left out. The chip is as loud against the samples as OpenMPT makes it.

Half the MPTM files to hand use plug-ins. A plug-in is somebody's program, and none can be run
here; but OpenMPT has a few of its own built in, which it plays on any machine, and four files in
five that use plug-ins use only those: an echo, two reverbs, a chorus, two flangers, a compressor,
a distortion, an equaliser and a gargle, all made after the effects that came with Windows, and the
echo of DigiBooster. Those are here, each carried over from OpenMPT's own and set beside it: given
the same sound and the same settings (every setting that the files to hand keep among them), each
gives what OpenMPT's class gives, to the last bit, when that is built to round as Swift does. They
are wired as the file wires them. A voice goes to the plug-in of its instrument, or failing that of
its channel; what a plug-in makes goes to the listener or on to another plug-in; a plug-in can be
put on the whole sound; and how much of what it was given is heard beside what it makes, how the
two are put together and how loud, are the file's to say. A tune can change a plug-in's settings as
it plays, by a kind of note that is for nothing else or by a macro, and that is done; a change slid
over a row is made in one step at its start. A plug-in that is not OpenMPT's own is left out as
OpenMPT leaves out one it cannot find: what was sent to it is heard as it is. An instrument that is
nothing but such a plug-in is not heard, and a file whose notes are, half or more, for such
instruments is refused.

And an instrument can be tuned to a scale of its own. Most such scales have nothing to do with the
twelve steps a module's notes otherwise are, and a file with one is refused. A temperament is
twelve steps that are not quite equal, and is played: each note is started at the pitch the
temperament gives it, as OpenMPT starts it. (What OpenMPT then does with a slide on such an
instrument is its own, and is not done; the slide is Impulse Tracker's.) Of 700 files, 694 are
played: five are refused for their tunings, and one for keeping its samples in other files. And a
file that is played with something left out says what, a sentence for each kind of thing.

There is a difference of another kind, which no list of features covers. OpenMPT plays these files
in its own way and not in Impulse Tracker's wherever the two differ, and the file says which of
some hundred and forty small matters it wants played which way. A handful of those are followed
here, where they decide the tempo or where a tune goes next; for the rest this is Impulse Tracker's
replayer, and the file gets Impulse Tracker's answer. What that comes to was measured against
libopenmpt, OpenMPT's own player as a library. What is read from each of 625 files is the same
as what libopenmpt reads, but for a fade and a place between the speakers that the extras give
more finely than an IT file's instrument can hold. Where the tune is on every tick, and how many
frames the tick lasts, is the same for ten minutes or to the song's end in every one of them but
one, where a pattern that jumps about within itself is taken to have come round sooner than OpenMPT
takes it to. (That was before the files with FM were played, and they have not been counted
again.) What is heard was set beside libopenmpt as it plays, plug-ins and all, by the same two
measures as above, for the first minute of each file. For the files with no plug-ins the spectrum
agrees to 0.996 for the middle file and 0.976 for the file a tenth of the way up from the worst;
for those whose plug-ins are all OpenMPT's own, to 0.993 and 0.957, where without the plug-ins it
was 0.972 and 0.894; and for those with a plug-in that is left out, which libopenmpt leaves out
too, to 0.997 and 0.976. The files with FM come to 0.983 and 0.957. The rest of the difference is
OpenMPT's filter, whose cutoff is not Impulse Tracker's unless the file asks; slides in a tune that
uses the Amiga's; a pitch that OpenMPT rounds where Impulse Tracker does not; and whatever an
instrument does at random.

A CMF file is a tune for the FM chip alone: its instruments, each the handful of numbers the chip
wants for one, and the music as MIDI. It was Creative's format, and what played it was SBFMDRV,
the driver on the disk that came with a Sound Blaster. That driver is what is here, by way of fmdrv's
port of it to C, and it is a small and particular MIDI player: nine voices, or six and the chip's five
drums when the tune asks for them; a key's speed worked into the instrument's own level; four
controllers of its own, one of them to move a channel's pitch by fractions of a semitone; and no
bending of pitch as MIDI has it, which it passes over. What it did oddly is done oddly here, since the
tunes were written to how it sounded. The tune's clock is the PC's timer, and the timer and the chip
ran off the one crystal, so a tick is a whole number of twenty-fourths of one of the chip's samples
and the two are kept in step exactly. `siday --raw file.raw tune.cmf` writes the chip's own samples,
at its own 49,716 a second, and they agree to the sample with fmdrv playing on Nuked OPL3: on all
932 files to hand, from end to end.

A ROL file is a piano roll from AdLib's Visual Composer, the program that came with the AdLib card:
nine voices, or six and the drums, each a list of notes and, beside it, the times at which its
instrument, its volume and its pitch change. It is played by AdLib's own sound driver, as AdPlug has
it from the code AdLib gave programmers. A ROL file holds no sounds. It names its instruments, eight
letters at most, and the sounds were in a bank file beside it: `STANDARD.BNK`, which came with the
program and which people added to and passed on, or a bank of the tune's own. So an instrument is
looked for in three places, and the first to have it wins:

1. a bank with the tune's name beside it (`TUNE.BNK` for `TUNE.ROL`);
2. `STANDARD.BNK` beside it;
3. the bank built into the player.

The built-in bank is what lets a ROL file be played by itself, and it is all the browser has to go
on. It has 9,683 instruments: AdLib's own 145; some 1,200 more from a dozen enlarged banks that
travelled with collections of ROL files; and the rest from the bank of IMPlay, a later player of the
same kind of music, for the sake of the names. Banks do not always agree about a name. Where they
differ, AdLib's bank has it, and after that the sound that most banks give it.
`swift Scripts/pack-bank.swift` makes the table from bank files. Of 1,509 ROL files tried, 1,479 find
every instrument there and 30 are left with one, two or three that no bank to hand has, which are
silent; the tune's detail says how many. `siday --raw file.raw tune.rol` writes the chip's own
samples, as for a CMF file, and they agree to the sample with AdPlug's ROL player on Nuked OPL3 given
the same bank, on every one of those files. (AdPlug refuses a ROL file that has no bank beside it,
and wants one bank to have everything.) A beat is played as sixty ticks at most however many the file
gives it, as AdLib's driver had it, and tunes with more were written to that.

Both are heard as the card put them out: one channel, through the filter on the card's board that
kept its output centred, and brought from the chip's rate to the player's through a windowed sinc.

An FMT file is a song from FM Tracker, a small tracker for the AdLib card by Davey W Taylor: eight
voices, each with one instrument that it keeps for the whole song, and patterns that hold nothing but
notes and the places where notes stop. Neither the tracker nor any account of its files by the man
who wrote it has turned up. What there is, is OpenMPT's loader for them, by someone who wrote songs
in the tracker, and the player here goes by that and by what OpenMPT then does with the song. It
reads a file as OpenMPT reads it. It gives each note to the chip as the numbers OpenMPT gives it,
which puts middle C at 257 Hz, a third of a semitone under concert pitch, and leaves the very
highest notes as much as a sixth of a semitone out, OpenMPT's sums being in whole numbers. And it
stops a note as OpenMPT stops one in these files, by giving the voice a pitch of nothing, so that
the note is cut off where another tracker's would die away. The clock is the PC's timer left alone,
18.2 ticks a second and kept in step with the chip as a CMF file's is, and each place in the song
has a delay of one to eight ticks to the row. The tracker waited out the delay before it played a
row, not after, so the last row of every pattern goes at the next pattern's speed, and songs were
written to that. How the tracker itself sounded is not known beyond this. For the four songs to hand
and for files made to try every note, every register the player sets, and the tick it sets it on, is
what OpenMPT sets. What is heard can be held to OpenMPT only by measure, since OpenMPT plays FM on
another emulation of the chip: tick by tick the two are as loud as each other to within a third of
a decibel for half the ticks and one decibel for nine in ten, and their spectra keep close.
It is heard as the other two are, and turned down by half, by measure, to be as loud as they are.

A YM file is played one of two ways. One recorded on an Atari ST goes to the ST's chip and timers
(`STYMRenderer`): that is every YM2 and YM3, which are the ST's by definition, and a YM5 or YM6 that
gives the ST's clock of 2 MHz or uses the effects. Any other is a plain recording of an AY or YM chip
on some other machine and is played like a VTX, with the stereo choices that go with that. Asking for
a chip, a clock or a frame rate by name (`--chip`, `--clock`, `--frame-rate`) gets the plain recording
whatever the file is.

Tracker players keep the field names and control flow of the Pascal they came from, so the two can be
read side by side. Tracker modules are loaded into a 64 KB wrap-around memory and all file parsing is
bounds-checked, so a corrupt file plays wrongly or is skipped but does not crash the player.

## Licence and credits

GNU General Public License, version 2 or (at your option) any later version; see `LICENSE`. One part,
the driver for CMF files, comes from work under the Apache License 2.0, which goes with version 3 of
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
  the format that came with OctaMED. The players of MED modules here, and the mixing, are siday's
  own: nothing in them is taken from OctaMED's, which they were written to do the same as.
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
- [it2play](https://github.com/8bitbubsy/it2play), also by Olav Sørensen: Impulse Tracker 2's
  replayer, ported by him from the tracker's own assembly, the reading of IT files, and the sound
  driver, which is his own. Impulse Tracker is by Jeffrey Lim.
- OpenMPT once more: an MPTM file is its own, and what is read from one, and what the replayer has
  been given to play one with, follow its source.
- libxmp and OpenMPT again: how a GDM and a PTM file are read, which is made after both of theirs,
  and libxmp the player that the reading and the playing of those files were checked against. The GDM
  format is as MenTaLguY describes it, and BWSB and its converter are by Edward Schlunder; the PTM
  format is as JAL of Nostalgia describes it, and PolyTracker is by Lone Ranger of AcmE.
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
