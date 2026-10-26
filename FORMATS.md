# siday's formats

This is the story of each format siday plays: where it came from, how siday plays it, and where
siday's way differs from the original. Each player can show you the chapter for the tune you are
listening to: press the format's name beside a tune in the web player or the app, or use
`siday --about FORMAT` on the command line (or `i` while a tune plays). How siday is built, and how
each player was checked, is in [DEVELOPMENT.md](DEVELOPMENT.md).

### How loud each format is

Every kind of file is made about as loud as every other. That comes before how loud each was in its
own player: a loud tune should be loud whatever its format, and a quiet one quiet.

The levels are set by how loud the sound is heard, measured the way broadcasters measure it
(ITU-R BS.1770, in LUFS). That measure weights what the ear hears most and skips over silences.
Before October 2026, the levels were set by plain signal power instead. The two mostly agree; where
they didn't, it was bright chip sounds, and the bass and FM of some formats, that plain power had
got
wrong.

Within a format, though, a tune is as loud as its file makes it. Among 423 tunes of nearly every
kind, the middle nine-tenths spread over 14 dB.

### Levelling

If you would rather hear every tune at the same loudness, ask for it in the player's settings, or
with `siday --level` (off unless you ask, since October 2026):

- Each song is measured whole, as it is played, loops and fade included.
- It is then turned up or down to the level the formats themselves are set to, -22.95 LUFS; or
  halfway there, if you ask for that.
- A song is turned up by 6 dB at most, so that one meant to be quiet isn't made loud. Its peaks are
  never brought within 1 dB of the top.
- Each song is measured once. The level found is kept, on the computer or in the browser.

### Files that need other files

Some files are not a whole tune, or not a tune at all:

- a playlist names tunes in other files;
- a ROL tune takes its instruments from a bank in a file alongside it;
- a song packed with the Magnetic Fields Packer, with TFMX, or by Pierre Adane's packer keeps its
  samples in a file of their own;
- a Sonix score keeps its instruments in a folder alongside it, which is brought in whole.

These companion files are all found the same way: by the names they are known to have, next to the
file that needs them, and ignoring the difference between capital and small letters, as Windows
does.

On the command line and in the app, that means the folder on disk. A web page can only read the
files it has been given. So in a browser, a tune or companion file you have given the page is known
for as long as the page is open. When one that is needed hasn't been given, the page says so and
asks for the folder it is in. It looks in that folder for what it needs, and adds nothing else from
it. A companion file (a bank, a file of samples) isn't a tune, and isn't listed as one.

## PT3 and the other AY trackers, VTX and AY files — the ZX Spectrum and the Amstrad CPC

The AY-3-8910 is a sound chip that General Instrument made from 1978. It has three voices of square
wave, one source of noise that the three share, and one envelope, also shared. It is the sound of
the ZX Spectrum 128, the Amstrad CPC and the MSX, and, as Yamaha's YM2149, of the Atari ST.

Music for the chip is a matter of what is written to its fourteen registers, fifty times a second.
The files played here keep that in three ways:

- **Tracker modules:** the notes, with the ornaments and the "samples" (lists of volumes and tones,
  a tick at a time) that the tracker's own player turns into register writes.
- **VTX files:** a recording of what a tune wrote to the registers, tick after tick, packed.
- **AY files:** not music at all, but the part of a game that played its music. An AY file is Z80
  code, lifted out of a game or a demo with the memory it needs.

The trackers are the Spectrum's. Most are from Russia and its neighbours, where the Spectrum and the
machines copied from it were the home computer for years after the rest of the world had put it
away. They are:

- Sound Tracker (STC) and Sound Tracker Pro (STP);
- Pro Tracker 1, 2 and 3 (PT1, PT2, PT3);
- ASC Sound Master (ASC);
- SQ-Tracker (SQT);
- Pro Sound Creator (PSC);
- Fast Tracker (FTC);
- Pro Sound Maker (PSM);
- Global Tracker (GTR);
- Fuxoft's AY Language (FXM), which is a program more than a module.

Pro Tracker 3 is the one most of the music is in, and music is still written in it. TurboSound is
two of the chips in one Spectrum, and a tune for it is two modules played together.

An AY file is also the one way to keep beeper music, which is older than the chip. The first
Spectrum had a loudspeaker that its processor could push out or pull back, and nothing more. Its
music is the processor doing that at the right moments, hundreds or thousands of times a second, and
doing nothing else while it did.

### How siday plays it

Each tracker's player here is Sergey Bulba's, from Ay_Emul. Ay_Emul is the program this music has
been kept and listened to with on the PC for twenty years and more. An AY file is run on a Z80, as
it ran on the machine.

A corrupt file plays wrongly or is skipped, but it does not crash the player.

### Differences and limits

siday departs from Ay_Emul on purpose in three small ways. Two of them change how a file is read
(the third is internal):

- Old-format PSC modules start with sample and ornament tables that are correct for their version.
- An AY file only counts as an Amstrad CPC one once it writes a register through the CPC's ports.

## YM — recordings of two machines' chips

The YM file is Arnaud Carré's, made for his player ST-Sound. It holds what an Atari ST's tune wrote
to the chip, recorded from an emulator fifty times a second and packed. Later kinds of the file
(YM5, YM6) also say which of the ST's timer effects were running, since no list of registers can
hold those. The name came to be used for plain recordings of the same chip in other machines, too.

### How siday plays it

A YM file is played in one of two ways:

- **Recorded on an Atari ST:** the file goes to the ST's chip and timers. That is every YM2 and YM3,
  which are the ST's by definition, and any YM5 or YM6 that gives the ST's clock of 2 MHz or uses
  the effects.
- **Any other:** a plain recording of an AY or YM chip on some other machine. It is played like a
  VTX, with the stereo choices that go with that.

Asking for a chip, a clock or a frame rate by name (`--chip`, `--clock`, `--frame-rate`) gets the
plain recording, whatever the file is.

Two kinds of damaged file are played anyway:

- **Overwritten headers.** Many YM files were passed round with the first two bytes of their
  archive's header, its size and checksum, written over with "xx", and its packed size too. The rest
  of that header is whole and says enough to unpack them, so they are played. There are twenty in
  the collection.
- **Missing ends.** A file whose registers lie one after another may have the end of the last two
  missing. Those two make no sound, and hold the timings of the effects. Such a file is played with
  that end read as nothing, and says so.

## SNDH — the Atari ST and STE

The Atari ST of 1985 had the same chip, in Yamaha's make of it, and no other sound. Its musicians
got more than three square waves out of it by writing to it far more often than fifty times a
second, from the ST's timer interrupts:

- **"SID voices"**, named after the Commodore's chip: a voice's volume switched fast enough to make
  a wave of its own.
- **Digi-drums:** samples played as a stream of volumes, which were their drums.
- **Sync-buzzer:** the envelope started again and again in step with a note, which makes a buzz no
  register setting gives.

The STE of 1989 added two channels of real samples.

An SNDH file is such a tune as it was: the 68000 code that played it, lifted out of its game or
demo. A header in front names it, and says how its songs are started and how often it is to be
called. The SNDH archive has kept the ST's music this way, some thousands of tunes.

### How siday plays it

An SNDH tune *is* the program that played it, so siday runs it on an emulated ST. That is a 68000
with 4 MB of memory, the sound hardware, and the few things such a program asks of the operating
system. The design is AtariAudio's, and a light one.

The sound chip here is not the one the Spectrum's tunes use. The ST ties the chip's three outputs
together, so their level is looked up in a table recorded from the machine, not added up.

siday does one thing differently from AtariAudio, and only on the way out. It brings the chip's
250,000 steps a second down to the output rate with a low-pass filter, where AtariAudio takes a
plain average. The filter keeps out aliasing.

The STE's blitter, the chip that copies blocks of memory for pictures, is there too, because a demo
or two moves its sound about with it.

Older SNDH files may be named `.snd`, as they were before the format had its name. The titles in
SNDH and YM files are read in the ST's own characters. Those are much the PC's, with Hebrew and more
accented letters where the PC drew lines.

## SID — the Commodore 64

A SID file is named after the chip, the Sound Interface Device: the 6581 that Bob Yannes designed
for the Commodore 64 in 1981. It has three voices. Each can be a triangle, a sawtooth, a pulse of
any width or noise, with an envelope of its own. A voice can be locked to its neighbour's pitch, or
multiplied by it. Any of them can be sent through one filter, which is analogue, and was never quite
the same in two chips. Nothing else in a home computer sounded like it.

The 8580 that took its place in later machines is cleaner, and has a filter of another character. It
is also quieter at one thing the 6581 did by accident: a click on every change of the volume.
Programmers turned that click into a fourth voice that played samples.

Like an AY file or an SNDH file, a SID file is neither a recording nor a score, but the program. It
is the 6502 code that played the tune in a game or a demo, lifted out. A header says where it goes
in memory, what to call to start each of its songs, and what to call fifty times a second after
that.

The format began with PlaySID, a player for the Amiga, in 1990. The High Voltage SID Collection,
which has gathered the Commodore's music since 1996, kept it. It added a second kind, RSID, for the
tunes that need a real Commodore 64 around them to run: their own interrupts, the timers of its two
CIA chips, the raster of its video chip.

### How siday plays it

siday has a 6510, the Commodore's 6502, written for this project. Around it is as much of the
machine as tunes ask for, with a start-up state and a driver for PSID files that are libsidplayfp's.

The chip is reSIDfp, the emulation in libsidplayfp. It works out the filter and the mixing of the
waveforms as the circuits they were. reSID 1.0, Dag Lem's, from which reSIDfp descends, is here as
well: it is lighter, and its 6581 filter is drier. Both are ports, checked bit for bit against the
C++ originals.

A SID file does not say how long its songs are. The collection keeps a list of the lengths, found by
people who listened, and the list of its release 85 is built in. A newer `Songlengths.md5` can be
given, to be asked first.

### Settings

- `--sid-engine resid` plays a tune on reSID in place of reSIDfp.
- A tune is played on the chip it asks for, unless `--sid-model` says otherwise.
- `--sid-filter-curve` moves the 6581's filter between its bright chips and its dark ones.

## SAP — the 8-bit Ataris

Atari's 400 and 800 came out in 1979 with a sound chip of their own: the POKEY, which Doug Neubauer
designed. It also read the keyboard, the paddles and the serial port, which is
where its name comes from.

Its four channels each count down from a frequency of their own. They count from the machine's clock
divided by 28 or by 114, and the first and third from the clock itself. Each time a channel comes to
zero its output may change, and how it changes is its "distortion". It is a plain square wave, or
one let through only where the chip's shift registers of 4, 5, 9 or 17 bits say so. Those make the
buzzes, rumbles and hisses that are as much its sound as the square waves are.

The chip has three more tricks:

- Two channels can be joined into one of sixteen bits, for finer pitches.
- The first two can be passed through high-pass filters clocked by the other two.
- A channel can be held at one of its sixteen levels, so that what is written to it is a sample.

The XL machines of 1983 and the XE of 1985 kept the chip. So did the musicians of the Atari scene,
in Poland above all, long after the machines were sold.

SAP is to these machines what SID is to the Commodore: not a recording, but the program that played
the tune. It is 6502 code and its data, lifted out of a game or a demo. A header of a few lines of
text says where it goes and how it is to be called.

Adam Bienias made the format in the 1990s, for his Slight Atari Player, the first player of it, for
Windows. The Atari SAP Music Archive, ASMA, has kept the machines' music in it since 1999, after the
High Voltage SID Collection's example. It has some 8,000 songs.

A file is of one of four types:

- **B:** its start is called once, with the song's number. Its player is called as often as the
  header asks, once a frame or several times.
- **C:** music made in Chaos Music Composer, whose player is called at places of its own.
- **D:** its start is run as the machine's program and never returns. Its player is called as the
  vertical blank interrupt would have called it.
- **S:** the same as D, with a counter counted down in place of a player, for SoftSynth's music.

A tune for two POKEYs, one on each side, is marked as stereo. One for the American machines' 60
frames a second is marked as NTSC.

### How siday plays it

The player here is a port of ASAP, Piotr Fusik's Another Slight Atari Player: its POKEY, its 6502,
and as much of the machine as a tune needs. It matches ASAP to the sample over the first 30 seconds
of every one of the 8,349 songs in the collection.

ASAP's 6502 is not the C64's of this project, which makes each of its accesses to memory in a cycle
of its own. ASAP's runs an instruction whole, and counts its cycles before it. Its tunes are heard
as they are because of where in its cycles each write to the POKEY falls.

Of the rest of the machine, siday has:

- the screen's lines, which tunes count;
- the nine cycles of each line that ANTIC, the chip that draws the screen, takes from the processor
  to refresh the memory;
- the WSYNC register, which holds the processor until a line ends;
- the console's one-bit loudspeaker, the one that clicked the keys.

Some tunes play on that loudspeaker beside the POKEY, and some play on it alone, as a ZX Spectrum's
beeper is played. It has a light of its own, pink in the browser as a beeper's is, which shows once
it is heard.

The POKEY is not stepped cycle by cycle. ASAP works out when each channel's output next changes, and
puts each change into the sound where it falls between two samples, as a band-limited step. So the
chip's highest tones come out without aliasing. The four channels are added as the chip's own DAC
adds them, a little less than in proportion. The sum goes through a gentle high-pass filter.

The songs' lengths are the ones the file gives, which ASMA's people found by listening. Where one
ends, a song that is still playing is faded, and one that has fallen silent stops. ASAP makes its
tunes louder than the other formats here, so siday turns them down to match.

### Differences and limits

ASAP also reads the native files of the Atari's trackers (CMC, RMT, TMC, MPT and the rest), which it
plays by putting each tracker's own player beside them. siday does not read those: ASMA has them as
SAP files.

### Settings

The two sides of a stereo tune are brought most of the way together, as a Sound Blaster Pro's are,
because each POKEY all on its own side is harsh in headphones. A fifth of the difference between
them is kept, unless the listener asks for more with `--sb-pro-separation` or the setting in the
browser. 100 is the machine's own.

## AGI — Sierra's adventure games

Sierra On-Line made King's Quest for IBM's PCjr in 1984. The interpreter it was written for, the
Adventure Game Interpreter, ran Sierra's games for the rest of the decade: King's Quest I to IV,
Space Quest I and II, Police Quest, Leisure Suit Larry, The Black Cauldron, Gold Rush!, Manhunter I
and II, Mixed-Up Mother Goose and Donald Duck's Playground.

The PCjr had a sound chip of three voices and a noise, Texas Instruments' SN76496. The Tandy 1000
that followed it had one made like it, and that is what the music was written for.

A sound in one of these games is four voices, three of tones and one of noise. Each voice is a list
of notes. A note gives how long it lasts, in sixtieths of a second, and the three bytes that were to
be written to the chip for it. Two are for its tone (or its noise's kind and rate) and one is for
its volume.

A file here is one sound taken out of a game's volumes, the AGI file as UnExoticA has them. It has
four places that say where the voices begin, then the voices, each ended by a duration of 65,535. It
plays once and ends, as it did in the game.

### How siday plays it

The games came to the Amiga in the later 1980s, where there was no such chip for their sounds to be
written to. Sierra's interpreter for the Amiga played them on Paula, the Amiga's sound chip, with
routines of its own. Wanted Team kept those routines in their player of the sounds for EaglePlayer
(2006). siday's player was written from that one. The Amiga's way is how a file is played unless the
listener asks otherwise.

There were two routines in the interpreter's time, and Wanted Team's player keeps both:

- **Sierra's first routine** plays a tone as a square wave, a wave of two samples. Its period is
  sixteen of Paula's clocks for each the chip's clock would have been divided by. So it is at the
  chip's pitch, or as near as Paula's slightly slower clock has it. Its volume is the note's, from
  64 at the loudest down to zero in fifteen even steps, not the chip's steps of 2 dB. So a quiet
  note is louder than it was on the PC.
- **The later routine** plays the tone as a wave of eight steps, more nearly a sine. It turns each
  note down as it is held: by two of the chip's steps at first, then one, then none. Then it turns
  it further over a second, to eleven steps under where it began, where it is left. Its noise is
  turned down the same way only once, over the sound's first second: what is begun for a tone at
  each of its notes is begun for the noise with the sound.

The noise is a stretch of 4,096 bytes from a shift register of sixteen bits. It is played at one of
three rates, as the chip's were; the fourth, which follows the third tone, is taken as the slowest.
The chip's other kind of noise, its periodic one, is played as the first.

Each voice is started once, at its first note, and left running. A note after that changes only its
period and its volume, so a tone goes on from where the last one left off. The interrupt that starts
the notes comes round sixty times a second, all but exactly.

Which games had which routine is not known. Wanted Team's player plays the first unless it is told
otherwise, and that is how these files are heard on the Amiga today. So it is here.

Both routines were compared with Wanted Team's player itself, run by UADE, on all 745 files of
UnExoticA's collection.

On the Amiga the sounds are as loud as a MOD file, which is played on the same chip, with either
routine. On the PC's chip they were louder than that, and are turned down to match.

### Playing on the PC's chip

The other way of playing the files (`--agi pc`) is on the chip they were written for, as the
interpreter for the PCjr and the Tandy wrote to it. That is as NewRisingSun's recordings of King's
Quest II on those machines show (at vgmrips.net).

Sixty times a second, each voice whose note has had its time is given its next. Its bytes are
written to the chip as they are in the file: the tone's lower bits first, then its upper ones, then
the volume. When a voice comes to its end it is silenced.

Some details follow the recordings and the chip closely:

- **Silent notes:** a note of silence has zero in its two tone bytes, and the recordings show that
  the interpreter wrote those too. The chip, as MAME has it, takes a byte that does not name a
  register as being for the last one named. For those bytes that is the last voice's volume. So a
  silent note can leave the voice before it at its loudest until that voice's next note.
- **Noise notes:** a noise's note is given its two commands alone, its noise's and its volume's. The
  zero beside them is not written, since it would turn the noise to its other kind. No recording
  has a noise from these interpreters to say what they wrote.

### Differences and limits

ScummVM's reading of Sierra's later interpreters for the PC has them turn every note down as it is
held, as the Amiga's later routine does. That is not done here, for want of a recording to compare
it with.

### Settings

- `--agi amiga-later`, or the setting in the browser, plays the Amiga's later routine.
- `--agi pc` plays the sounds on the PC's chip.

## MOD — ProTracker and the Amiga

The module began on the Amiga in 1987, with Karsten Obarski's Ultimate Soundtracker. It had four
tracks, one for each voice of Paula, the Amiga's sound chip; patterns of 64 rows; and fifteen
samples. All of it was in one file, the instruments with the tune, which is what made it a module.
Others took it up and carried it on, with 31 samples and more commands, NoiseTracker and then
ProTracker among them. ProTracker's file became the one every later tracker's descends from.

### How siday plays it

A module is played as ProTracker played it. The replayer is ProTracker 2.3D's, by way of pt2-clone's
port of it to C. It keeps ProTracker's mistakes, because tunes were written by ear against them. Its
raw output agrees with pt2-clone's to the sample, for every module but those of the trackers before
ProTracker (below), which pt2-clone plays at ProTracker's speed.

What the replayer would have told Paula, it tells an emulation of Paula: four voices reading
eight-bit samples out of memory, each at a rate of its own. Paula is run at 96,000 samples a second.
Each step in her output is replaced by one that holds nothing above the range of hearing. Then the
sound goes through the filters the Amiga has on its way to the socket, and is halved.

Two of the voices are wired to the left and two to the right, with nothing in between. Through
loudspeakers a room mixes the two; in headphones nothing does, and it is harsh. So a module in
stereo has its two sides brought most of the way together (see Settings).

Files from other trackers of the family have the few effects they meant differently turned into
ProTracker's as they are read. A tune ends where it would play a row it has played before.

The trackers before ProTracker played their tunes once each frame of the display, 49.92 times a
second on a PAL Amiga, and had no tempo, only a speed: NoiseTracker 2.0's own source runs its music
from the vertical blank, and so does Karsten Obarski's Ultimate Soundtracker replay of 1987. ProTracker
played by a timer, 125 beats a minute being fifty ticks a second. So a file that shows it came from
NoiseTracker or His Master's Noise (`N.T.`, `M&K!`, `FEST`), or a fifteen-sample Soundtracker module
at the tempo of 120 every Soundtracker wrote, is played on the frame, a sixth of a percent slower than
ProTracker would play it:

- Their F command is a speed alone: above 31 it is 31, and in His Master's Noise's files F00 is
  speed 1, as their players have it. The later Soundtrackers read only its last figure.
- NoiseTracker's and His Master's Noise's songs begin again where the file says, not at the start.
- A Soundtracker module with another tempo was made by Ultimate Soundtracker 1.8 or 2.0, which played
  by a timer worked out from it, and is played by that timer exactly.

A module tagged `M.K.` may have come from NoiseTracker too, which wrote the same tag, but nothing in it
says so, and it is played as ProTracker's.

### Differences and limits

- **E8x is left out**, as it is in pt2-clone. It filters a sample in place, and nearly every module
  that has it means something else by it.
- **Long samples are played whole.** ProTracker has room for 64 KB of each sample and plays no more
  of a longer one. No file of its own has one, but files from other trackers do. Paula can be told
  to play twice that, and the routines that played modules outside the tracker did so.

### Settings

- In stereo (`--output abc` or `acb`, which are the same thing to a module), the two sides are
  brought to a fifth of the Amiga's separation. That is what pt2-clone does unless told otherwise.
- `--amiga-separation 100` gives the Amiga's own separation.
- Mono or a television brings the sides together entirely.

### Packed files

Amiga users packed what they kept, to get more of it onto a disk, and modules with the rest. They
packed them whole, with packers of files that knew nothing of what they packed. Two of those are met
with among modules. A file packed by either is unpacked before it is read, whatever kind of module
is inside it:

- **PowerPacker,** Nico François's, was the one most used.
- **XPK** is a set of packers that any program could call on, by Urban Dominik Müller and others.
  Each packer is a library of its own, with four letters for a name. Modules are found packed by
  three of them: SQSH, which was made for sampled sound; NUKE; and DUKE, which is NUKE with each
  byte first turned into its difference from the one before.

One of the XPK files in the collection unpacks to a module packed again by The Player 4.1, a packer
made for modules. That is unpacked in its turn, as below.

### Modules packed for games

The programmers who put music into games packed it with packers made for modules. These knew what a
module was, and kept it as their own replayers wanted it. ProTracker kept every note in four bytes,
room for anything and mostly nothing, so a packer kept only what was there. Some put the samples'
differences in place of the samples, or kept a track used twice only once.

Each group had its own, and the music of a game is as often found in one of them as not:

- The Player, in its versions 4, 5, 6.0 and 6.1;
- NoisePacker, in three versions;
- ProRunner, in two;
- ProPacker, in two;
- Pha Packer, Tracker Packer, AC1D Packer, the Novotrade Packer and Digital Illusions' packer;
- Promizer 1.8a, whose files begin with its own replayer;
- the files of Game Music Creator, a tracker of its own whose songs are near enough to ProTracker's
  to be read as one. A file named for it is played by its own player, though (see PUMA).

What was packed was a ProTracker module, or one in all but name. Each is unpacked to that again, to
be played as ProTracker played it. Sylvain Chipaux's ProWizard knew how to unpack them all. libxmp
keeps it, and the unpacking here is a port of the part of it these packers need. Every one of the
787 files of UnExoticA's collection that ProWizard unpacks is unpacked here to the same bytes.

A few files are taken otherwise than ProWizard takes them, which changes what is heard:

- **Pha Packer:** a file does not say how long its song is. ProWizard counts it to the last place in
  the order that plays a pattern other than the first. So a jingle whose every place plays one
  pattern comes out as a song of no length. siday plays it as that pattern once (fourteen files, of
  Brian the Lion and of Frankenstein).
- **Ultimate Pinball Quest** has modules that say "KURT" where ProRunner's say "SNT.". They are
  taken as ProRunner's, and so are unpacked as UADE plays them. So are the eight of Winter Olympics,
  which say "+SNT" there.
- **NoisePacker 3:** siday accepts some files that ProWizard's test refuses, as Nicolas Franck's
  Deli-Wizard, UADE's converter, does. So the first level of Last Ninja 3 and two of the shortest
  sound effects of Dragonstone play. Two more of Dragonstone's, 46 bytes each, are nothing of the
  kind, and are not played.
- **The Player 6.0** could also pack the samples themselves into half their size, each byte two
  steps of four bits. ProWizard does not unpack those. They are unpacked as Deli-Wizard unpacks them
  (the intro of Statix, which comes out the size its file says).
- **Promizer 1.8a** is unpacked with each pattern taken from where the song first plays it, as
  Deli-Wizard takes it. ProWizard takes the pattern of each number from that place in the order
  instead. So it plays the wrong patterns of a song that plays one again before its last is first
  heard, as the one of Aquanaut does.

Some files still do not play whole:

- Two of Brian the Lion's are silent, because ProWizard numbers their patterns wrongly; UADE plays
  them.
- One of Evil's Doom's is silent both here and in UADE.
- A file whose last sample is cut short (sixteen of The Player 4's, as the games' rippers left them)
  says so, and plays with that sample silent.

### ChipTracker, Channel Players and SoundTracker 2.6

ChipTracker, Krister Wombell's tracker of 1991, kept a module as ProTracker did, except for its
notes. Its title and its 31 samples are where ProTracker's are. After them, where ProTracker has the
length of its song, it has "KRIS". In place of patterns it has tracks, each one voice's 64 rows. For
each place in the song it has the four tracks to play there, each moved up or down by so many
semitones. A note is kept as its place in a table of six octaves, two below ProTracker's three.

A ChipTracker file is read into the ProTracker module it would be, as ChipTracker's own replayer
reads it. Wanted Team keep that replayer in their player of the files for EaglePlayer. The module
has:

- a pattern for each different four tracks and moves;
- each note's period from that table, after its move;
- no finetune, which that replayer does not use;
- the start of a loop counted in bytes, not in ProTracker's words.

As OpenMPT reads them, some ChipTracker files have sounds of their own making, from waveforms kept
before the tracks. No file in the collection has them, nor is there a replayer of them to play them
by, and such a file is not played.

Fury of the Furries (Kalisto, 1993), with Frédéric Motte's music, kept its modules packed by a
packer of its own, in three versions. ProWizard does not know it, but UADE's converter, Deli-Wizard,
does ("Channel Players"). It keeps an order of where each voice's notes begin, and the notes in
three bytes, two or one. A `.chan` file is unpacked here as Deli-Wizard unpacks it.

SoundTracker 2.6 and Ice Tracker kept a module the same way as ChipTracker, but without its moves.
They have tracks of 64 lines, and for each place in the song the four of them to play, with "MTN" or
"IT10" where ProTracker has "M.K.". Such a file is read into a ProTracker module of a pattern for
each different four tracks, as Deli-Wizard reads it.

In SoundTracker 2.6, a speed command with both its digits set is two speeds taken in turn from line
to line, as libxmp plays it. It is left here as ProTracker reads it. The file in the collection has
none.

### The oldest modules

Some of the oldest modules, with 15 samples and nothing to say what they are, have numbers left in
their order past the end of the song. They are of patterns the file does not have: seven of Jean
Baudlot's, for Bad Dudes and Castle Warrior, are like this. Counted over the whole order, the file
is too short for its patterns. Counted over the song, the samples follow them to the byte, and so
they are read that way. (UADE does not play them.)

### Startrekker and Audio Sculpture

Startrekker, by Exolon of Fairlight, could play instruments it made itself, from a waveform and an
envelope, as well as samples. It kept them in a file of their own beside the module, the `.nt` file.
The collections have it as `title_nt.mod` beside `title.mod`; Audio Sculpture, which came after,
called its own `.as`. The module has empty samples in their places.

They are played here as ASREPLAY plays them, The Synchron Assembly's replay routine for Audio
Sculpture and Startrekker. That is as UADE plays them, tick for tick:

- one of four waveforms of 32 bytes, over and over;
- noise made afresh on every tick;
- a level that rises and falls through five stages;
- a pitch that slides;
- a vibrato of its own.

Startrekker modules are played as that routine plays them, in other ways too:

- A module goes round to the place in its order that it names, and not to its start (154 of them
  name one).
- A speed of nothing is taken as the fastest, one, where ProTracker stops the song. The four modules
  that have it use it so, for a row or two, and play on.

Some things differ or are left out:

- A Startrekker module whose file of instruments is not beside it says so, and plays with those
  voices silent. Four of the nine of Escape 2 are then silent altogether.
- The file of instruments, given as a tune, says what it is.
- Audio Sculpture's command E, which ran a program of the composer's from the file, is not run. No
  tune in the collection has one.
- ASREPLAY leaves a sample silent whose byte of finetune is not nothing. That would silence seven
  modules, one of them altogether, so those are played.

### AMOS

AMOS, François Lionet's BASIC for the Amiga, kept a program's music as one of the program's banks:
"AmBk", of the kind "Music". It holds instruments, songs and patterns. Each pattern is a list of one
voice's notes and commands, with a command to wait between them.

Programs and games written in AMOS have their music in these banks. Each bank is read into a
ProTracker module as UADE's player of them reads it, and played as one. Five banks of Tyran crash
UADE: their first pattern is 22 lines and a jump, and UADE reads on past the end of the bank for the
rest of its 64 lines. Here the rest of that pattern is left empty, as it is never heard.

### The Magnetic Fields Packer

The Magnetic Fields Packer was Shaun Southern's, by the replayer's own word and libxmp's, from 1994
and 1995. The games that used it kept a module in two files: the song, and its samples in a file of
their own.

The song has the samples' lengths and loops without their names, and the order of the places in the
song. Each voice of each pattern is kept as a tree: four bytes that each lead to four, that each
lead to four, that each lead to a note. So a stretch of rows like another is kept once. It is read
back into the ProTracker module it was, and played as one.

The samples are looked for beside the song, in this order:

1. `title.smp` for `title.mfp`; or, where songs share them, the name up to its last hyphen with
   `_set` (`KidChaos Level 1_set.smp` for `KidChaos Level 1-3.mfp`);
2. as the Amiga's own disks named them, `smp.title` for `mfp.title`;
3. failing those, the one file ending `.smp` beside the song, if there is only one.

Without them the song is not played, and says why.

A table in the file says where each voice's tree begins. It is read here as the format's own
replayer reads it, with an entry for each place in the song. Read with an entry for each pattern, as
older libxmp read it, songs whose patterns are not in the order of their numbers come out scrambled.

## MED — MED and OctaMED

MED was Teijo Kinnunen's tracker for the Amiga, from 1989. It was a rival to the Soundtracker
family, with ideas of its own:

- several songs in a file;
- sounds made from short waves and a list of instructions, as well as samples;
- notes for a MIDI synthesiser.

OctaMED, soon after, played eight tracks on the Amiga's four voices. OctaMED Soundstudio, in the
middle of the 1990s, mixed any number.

### How siday plays it

A MED module is played as OctaMED played it. The players here are not ports: OctaMED's own are not
free to copy, so these were written afresh and then held to them. OctaMED's players were run in an
emulated Amiga (UADE) on every MED module of a collection, and what they did was compared with what
these do.

A module for the Amiga's four voices is played on the same emulation of Paula as a MOD file. It has
the same filters, and the same bringing together of its two sides.

A module has two halves to its tempo: how fast the ticks come, and how many of them a line lasts.
The first is either a number that sets the Amiga's timer, or beats a minute; both are kept by the
timer's own arithmetic. Notes can be held for a time and then left to fade. An instrument can be a
sample recorded at several octaves. A block can be any number of lines long, with several commands
to a note.

An instrument need not be a sample at all:

- **A synthetic sound** is a few short waveforms and two lists of instructions, one for its volume
  and one for its waveform and pitch. The lists are carried on a step on every tick. A sound can
  swap its waveform, slide, play a run of notes, or take a waveform for the shape of its volume or
  its vibrato.
- **A hybrid sound** is such lists played on a sample.

A file with several songs has them all as its songs, and each is looked through for more, as any
module is.

### Five to eight tracks

With five to eight tracks there are more tracks than voices. OctaMED mixed them in pairs, each pair
into a stretch of memory that one voice then played, a tick's worth at a time. The length of the
stretch is the tempo.

It mixed as a 7 MHz machine could: no smoothing, no room for two loud samples simultaneously, and a
sample that would end during a tick is cut off before it. That is mixed here in the same way, and
played through the same Paula.

A song of five, six or seven channels leaves some voices a track to themselves. OctaMED's own player
then put what it mixed for the others in the wrong place; here it is put in the right one.

### Mixing mode

Mixing mode came with OctaMED Soundstudio. It has:

- any number of tracks, up to 64;
- samples of sixteen bits, and in stereo;
- each track panned where the song says;
- an echo;
- the two sides drawn together or pushed apart.

Soundstudio played that through whatever it had, a sound card as readily as the Amiga's eight bits.
So there is no one sound to imitate, and the mixing here is siday's own: at the rate of the output,
interpolated.

What a song says is kept: how loud each volume is, how a pan position divides a track between the
sides, where a sample ends and loops, and the echo's length and depth. The player is OctaMED's
player, where pitch is so many samples a second and a slide is still so many of Paula's periods.

Three things that OctaMED's player for this mode gets wrong are put right here:

- it plays each track's first tick in silence;
- it takes no notice of a change of tempo in the middle of a song;
- it plays an instrument meant for a sound card a semitone sharp.

And one thing it does is not done here. It made a sixteen-bit sample quieter only by halving it, so
such a sample had seven volumes; here it has all sixty-four.

### MED4 songs

Before it saved modules, MED saved songs. The last kind of those, MED4, is what MED 2.10 to 3.00
saved: a file that begins "MED" and a 4. It says what an MMD0 module says, packed tight. So a MED4
file is read into the MMD0 module MED would have saved of it, and played as that is.

A song of MED 2 is taken, as libxmp takes it, not to keep how many ticks a line lasts. It is given
five where it asks for the trackers' sliding, and six where it does not. None of the files in the
collection is of MED 2, to show whether that is so.

Left out:

- a synthetic or hybrid sound, which MED4 keeps in a shape of its own;
- the hold and decay of notes, in a part of the file no description lays out;
- a song whose instruments are in files of their own, which a page in a browser could not open.

A file that uses the first two says so.

### Packed MED modules

Some games kept their MED music packed. Such a file is an MMD0 module that says "MMDC", each of
whose blocks has its notes kept as runs, of so many zeros or so many bytes as they are. The player
Wanted Team made for these files is the one of Knightmare, which they credit to Antony 'Ratt'
Crowther, 1991.

Such a module is unpacked into the MMD0 module it was, as libxmp unpacks it. It is then played as
that is, by OctaMED's way of playing and not by the game's player.

## SFX and OKT — SoundFX and Oktalyzer

SoundFX is of 1988. Its module is the first Soundtracker's with a different front: fifteen samples,
patterns of 64 lines, and six ticks to a line. In place of a tempo it has the number that the
Amiga's timer is to count from between one tick and the next.

Oktalyzer, of 1989, got eight tracks out of the Amiga's four voices. A voice is whole, and plays a
track as any tracker would. Or it is split, and has two tracks, which are mixed a tick's worth at a
time into a stretch of memory that the voice then plays.

### How siday plays it

A SoundFX module is played as SoundFX played it, and an Oktalyzer module as Oktalyzer did. As with
MED, the players are not ports: the trackers' own routines are not free to copy, so these were
written afresh and then held to them. What they write to Paula is the same as what the routines
wrote, for every one of the 283 SoundFX and 42 Oktalyzer modules in the collection.

SoundFX's routine has ways of its own, and tunes were written by ear against them, so they are kept:

- A slide towards a note goes on over the lines that follow until a new note stops it. No other
  command of its voice is looked at meanwhile.
- A bend works on the period written on its own line. So on a line without a note it starts from
  nothing.
- A volume command counts from the instrument's volume, and only where the instrument is named
  beside it.
- Every voice is told again on every line where its instrument repeats. So naming another instrument
  under a note changes what the note goes on with.

A SoundFX file that was made to hold several tunes has them set apart by a pattern of silence. Those
are its songs here, found much as the player of these files for DeliTracker finds them.

Oktalyzer had a quick way of mixing two notes at two pitches, which is to step through only one of
them. The voice is played at the period of the higher note, whose sample can then be taken a byte
for a byte, and the lower note is stretched to fit. When the notes change, so do the voice's period
and how many bytes make a tick.

The two are added four bytes at a time, as one number, so a byte which overflows carries into its
neighbour. Samples for a split voice are made at half strength so that they do not. A split voice:

- has one volume between its two tracks;
- never repeats its samples;
- goes no higher than the A of the top octave.

All of that is done here as Oktalyzer did it.

### Differences and limits

- Four SoundFX files of the collection are shorter than their samples are said to be. The routine's
  own loader will not have them; here they are played, with silence where a sample is missing its
  end.
- In SoundFX, an arpeggio on a voice whose last note is none of the notes sends the routine looking
  for a period through whatever lies after its table. Here the voice is left as it is.
- Oktalyzer began to fill a stretch of memory again when the chip might not yet have fetched its
  last words. In an emulated Amiga, the chip now and then plays the last word or so of a stretch
  from what has just been written over it. That does not happen here, where a voice has a third
  stretch to mix into.

## AHX

AHX is by Martin Wodok and Manfred Linzner, Dexter and Pink of the group Abyss, from the middle of
the 1990s. It was made so that a tune for a small intro could be a few kilobytes. It is a tracker
for the Amiga with no samples at all: it sets out to sound like the Commodore 64's chip, on an
Amiga.

An instrument is a few numbers: an envelope, a vibrato, and a short list of things to do as its note
goes on. That list is where it says what wave it is (a triangle, a sawtooth, a square of some width,
or noise). The list can change the wave, play notes of its own, slide, and set the square's width or
the filter sweeping.

From those the tracker makes the sound as it plays. Each of Paula's four voices goes round a buffer
of 640 bytes. Fifty times a second, or a hundred or more if the file asks, whatever wave a voice is
to have next is copied into its buffer.

The filter is not a filter at work on the sound. The tracker works out its waves when it starts, and
with them 62 more sets of the same waves. Each set is already put through a low-pass or a high-pass
filter, set a little differently. An instrument that sweeps its filter is choosing, from one moment
to the next, which set to copy from.

### How siday plays it

An AHX file is played as AHX played it. All of the above is done as the tracker did it, in whole
numbers, by way of ahx2play's port to C of the replayer of AHX 2.3d-sp3. Its raw output agrees with
ahx2play's to the sample on all 858 files tried.

It keeps the replayer's mistakes:

- A note moved below the lowest there is takes its pitch from what the Amiga had in memory before
  its table of pitches.
- A list told to wait 128 ticks between its entries does not wait at all, and there are tunes that
  count on that.

Paula is the one MOD files are played on, with the same two Amigas to hear her through, and her two
sides brought together in the same way. A file says where each of its songs starts. A song ends
where it would play a row it has played before, or where it stops itself.

## HVL — HivelyTracker

HivelyTracker is AHX carried on, by other hands and off the Amiga. It has the same instruments and
the same waves, to the byte, and more:

- as many as sixteen voices, where the Amiga had four;
- two commands on every row of a track, where AHX had one;
- more for an instrument's list to do;
- a pan position for each voice, which the file sets for all of them simultaneously, from all in the
  middle to the Amiga's hard left and right;
- moving pan: a track can move it, and an instrument can move it for the length of a note;
- ring modulation: an instrument can have its wave multiplied by a second one, a triangle or a
  sawtooth at a pitch of its own.

### How siday plays it

A HivelyTracker file is played as HivelyTracker plays it. There is no Amiga under it. The tracker
mixes its voices itself, at 48,000 samples a second. Each voice goes round its buffer of 640 bytes a
byte at a time, with nothing between one byte and the next and nothing after.

That is what is heard here: the replayer and the mixer are those of HivelyTracker 1.9, as they are
in the players that come with the tracker. The settings for the Amiga do not touch them. Its raw
output agrees with that replayer's to the sample on all 34 files tried.

A file says how loud it is to be mixed. Where that is more than sixteen bits can hold, it is
clipped, as those players clip it. (The tracker itself lets it wrap round instead, so that its
composer hears that it is too loud.)

The voices are where the file puts them, unless the sound is asked for in mono, which is the two
sides together. A file's songs and their ends are found as an AHX file's are.

### Differences and limits

What the replayer leaves to chance is settled here:

- A jump past the end of the list of positions goes to its top.
- A track or a row the file does not have is empty.
- A note above the five octaves there are has no pitch to slide from.
- A wave other than the four there are is silence.

## DIGI — DIGI Booster

Before DigiBooster Pro, below, there was DIGI Booster, Tomasz Piasta's tracker for the Amiga. The
files in the collection were saved by its versions 1.5 and 1.7. It was ProTracker widened to eight
channels, which it mixed itself, two to each of the Amiga's four voices.

Its file says what it is in its first letters, "DIGI Booster module". After that it is a MOD file in
all but its layout:

- **Samples:** the same 31, each with a volume and a fine tuning, but as long as it likes.
- **Patterns:** the same 64 rows of periods and ProTracker's commands. They are packed a row at a
  time, with a byte that says which channels have anything. Or they are not packed, and then the
  channels come one after another, not the rows.
- **Commands of its own:** playing a sample backwards, stopping a note, starting further into a
  sample than 64 KB, and a "robot" voice.

### How siday plays it

DIGI Booster's replayer was never published. DigiBooster Pro's, which siday has, is another
program's, for another kind of file. OpenMPT plays these files as a MOD file of a kind of its own.
It uses ProTracker's commands, with the memory of their values that it gives every kind of module
but ProTracker's. It adds a few of DIGI Booster's ways, the same ones it gives DigiBooster Pro's
files.

siday does the same. It reads the file into its FastTracker 2 replayer, as it does MOD files of more
than four channels and MTM files. That means ProTracker's commands on more channels, with the same
memory of their values (a slide by nothing repeats the last slide). They run on the Amiga's periods
and fine tunings.

ProTracker's own replayer, which plays four-channel MOD files, is not the one used, although DIGI
Booster was the Amiga's. That replayer is the Amiga's four voices, played as Paula, the Amiga's
sound chip, plays them. DIGI Booster had eight channels that it mixed for itself. And ProTracker's
commands remember nothing.

For these files alone, the replayer behaves as OpenMPT plays them:

- **Clock:** a period is of a PAL Amiga's clock, 3,546,895 Hz, not the one FastTracker reckons a MOD
  file's periods by. So every note is some sixteen cents lower.
- **Arpeggio:** it is a step behind ProTracker's: its second note on the row's first tick, the note
  itself on the next, then its first. It counts from the channel's note, and leaves the pitch at the
  last note it played.
- **Vibrato and tremolo:** both follow DIGI Booster's own wave, of 32 steps and not quite even. The
  vibrato's wave carries on from note to note. The vibrato is not heard on a row's first tick, which
  is at the note itself; the tremolo is heard on that tick too.
- **Slides:** a slide up and a slide down remember one value between them.
- **Pattern loops:** a loop is not begun while another channel's loop is going. So of several loops
  on one row, each goes round in turn.
- **E40:** it stops the note. So a note named beside it starts nothing, and nor does an instrument
  named after it with no note.

A sample played backwards (E3x) is made a sample of its own, its sound turned round, placed after
the file's 31. E30 plays it from its end to its start. E31 and the rest play it back and forth over
the whole of it after that. This is what OpenMPT does.

A file that says its patterns are not packed has them a channel at a time, as OpenMPT reads them.
The channels are panned to the centre, as OpenMPT has them, which is how FastTracker plays a MOD
file's channels. The files are made about as loud as other modules are, by measurement.

### Differences and limits

DIGI Booster turned a backwards note round again when a note started on the other channel of its
voice. On the same row, siday sees to this. A note that is to go back to its start, with another
starting beside it, is at once going forwards from its end, and is not heard. On a later row it is
not done, and a file in which the note might still be sounding then says so.

Two commands are left out, and a file that uses them says so. One is the robot voice, which OpenMPT
leaves out as well. The other is a start further than 64 KB into a sample (E8x).

All three files in the collection are played, and their pitch and volume match libopenmpt's on
47,813 of 47,892 ticks.

## DBM — DigiBooster Pro and DigiBooster 3

DigiBooster Pro is by Tomasz and Waldemar Piasta, from Poland. It was the tracker of the Amiga that
left the Amiga's sound chip behind. It played through AHI, the Amiga's way of driving sound cards,
and so it could have:

- as many tracks as a tune wanted;
- samples of sixteen bits;
- two commands beside every note;
- envelopes of volume and of panning for an instrument, each with two places to hold at;
- an echo of its own on every track.

Its DBM file is made of chunks, as an Amiga's IFF files are. It can hold more than one song, each a
list of patterns of its own. The files in the collection were saved by its versions 2.12 to 2.21,
from the second half of the 1990s.

DigiBooster 3 came after it, by Grzegorz Kraszewski with APC&TCP. In 2014 its makers published their
replayer, libdigibooster3, under the BSD licence. They said that it plays DigiBooster Pro's modules
too, the two being mostly the same in what they do.

### How siday plays it

siday plays these files by that replayer, ported whole. There is nothing else to play them by that
DigiBooster's makers wrote. And nothing is written down of what DigiBooster Pro itself did beyond
the names of its commands.

DigiBooster plays like no other tracker. That is why it has a player of its own here, and is not
read into another's:

- **Slides in units of the speed.** Everything that slides is kept in units of the speed, so a slide
  can move by less than a step a tick. A volume slide is so many sixty-fourths times the ticks to a
  row. A pitch slide is so many eighths of a semitone times the same.
- **Fine slides spread over the row.** A "fine" slide adds its one step a row a little at every
  tick, where other trackers add it at once.
- **Every tick.** The slides move on every tick of a row, the first among them, and once more on the
  next row's first.
- **Pitch in eighths of a semitone.** A pitch goes by a table of the eighths of a semitone, and
  between those by a table for each speed of the parts of one. A pitch slide is so many eighths of a
  semitone at any pitch, not so much of an Amiga period.
- **Panning by level and by delay.** A track is panned both by how loud it is on each side and by
  being heard a little later on one side, by up to a third of a millisecond.
- **Echo before volume.** A track's echo comes after its instrument and before its volume. So the
  echo follows the volume down, and goes on when the note is done.
- **Interpolation.** Each sample is interpolated between each two of its points to the output's
  rate. It is read from a buffer that is filled a thousand samples ahead. A sample that does not
  loop is let go when that buffer reaches its end, a little before the sample's own end.

What you hear is the replayer's, but for four things:

- **Echo settings.** An echo starts as the file sets it. The replayer reads the file's settings for
  the echo and keeps them. But it starts every echo as DigiBooster 3 does by default, and goes by
  the file's settings only once a command changes one.
- **Letting a key go late.** DigiBooster Pro has a command to let the key go so many ticks into a
  row. The replayer passes over it. siday lets the key go then, as letting go of the key on a row
  does at once.
- **Level.** The replayer divides the sum of the tracks by how many there are, so that it can never
  be too loud. A file of 24 tracks is then a sixth as loud as a file of four. DigiBooster Pro made
  up for the number of tracks itself, and OpenMPT and libxmp play these files about as loud whatever
  the number. So siday divides every file by eight, however many tracks it has. The rest is set by
  measurement, so the files are as loud as XM files.
- **Looping.** A song that comes to the end of its list goes round to its top, as DigiBooster does;
  the replayer's example program stops there. A song found part of the way down a list stops there.

### Differences and limits

Three of DigiBooster Pro's commands are not in the replayer: setting how far into an envelope a note
is, sliding where a sample starts, and setting the tempo in beats a minute. What each did is not
written down closely enough to do it. So they are left out here too, and a file that has them says
so: 20 of the 180, most of them by one composer.

Two commands for the Amiga's own filter are passed over, as the replayer passes over them.

The replayer turns away five of the 180 files that siday plays:

- two with a sample whose loop runs one sample past its end; siday brings the loop back to the end,
  as OpenMPT does;
- one with something else put after the module;
- one cut short, which says so;
- one packed with XPK, which is unpacked first, as a MOD file is (see MOD).

OpenMPT and libxmp play DigiBooster's slides and vibratos as ProTracker's. So those two sound nearer
each other than either does to DigiBooster's replayer.

Without the four changes above, siday's output is the same as libdigibooster3's to the sample on all
187 songs of the 175 files it plays.

## TFMX — Chris Hülsbeck's music system

TFMX, "The Final Musicsystem eXtended", was Chris Hülsbeck's music system for the Amiga. It was the
sound of Turrican and its sequels, of Apidya, X-Out and Mad TV, and of many more German games of the
years around 1990. It was his own, and then a product: an editor sold as Chris Hülsbeck's
Workstation, and a player for each version, which composers who used it put in their games.

The players, as Wanted Team keep them for EaglePlayer, say of themselves:

- "(c) 1988-90" for the first;
- "(c) 1990-94" for TFMX Professional, which most of the music is in;
- "(c) 1991-94" for TFMX 7V.

TFMX 7V plays seven voices on the Amiga's four. Three play as they are, and four are mixed by the
processor into a stream that the fourth plays. Jochen Hippel made seven voices first, for a TFMX of
his own, and gave the idea to Chris Hülsbeck's.

A module is two files: its notes and instruments in `title.mdat`, and its samples in `title.smpl`.
siday finds the samples beside it (and in a browser, among the files it has been given), as it finds
the files that come with any tune. Where a folder's songs share one file of samples, it is
`set.smpl` or `smpl.set`.

A module holds several songs, often a game's in-game tunes and its jingles together. A song is a
table of steps. Each step gives each of eight tracks a pattern to play and the voice to play it on.
Each note of a pattern starts a macro, the instrument.

A macro is a little program run on every tick. It tells the sound chip where a sample is and how
long, sets the note's period and its volume, waits and loops. It also transforms the sound as it
plays: a vibrato, a slide, an envelope, a sample's start moved along, and in the later players a
sample made afresh from others as it plays.

### How siday plays it

siday's player began as Michael Schwendt's, from his library libtfmxaudiodecoder. He wrote its core
in assembly language around 1991, with the editor's handbook and files to go by, and he keeps it
today. It was ported here line for line.

That library is not always what Chris Hülsbeck's players did. What you hear in siday is his players,
as Wanted Team keep them for EaglePlayer and as UADE runs them. Where siday differs from the
library:

- **Which player a module is played as.** siday chooses as UADE does, by a test of the file's
  contents. It also makes the load-time mends that Wanted Team's players make to a few modules.
- **What each player does.** Many details follow the players, not the library. For example, a slide
  that reaches its note waits there for the next note, where the library ends it. That is why a
  jingle of Einmal Kanzler sein dropped straight to its last note.
- **How often the player runs.** The library runs fifty ticks a second, or two fifths of a song's
  beats a minute. TFMX Professional's player and the first player set the computer's timer from the
  song's beats a minute. Professional's runs slower than the library by nearly one part in a
  hundred. A song that sets no timer was played each frame of the display, as Hülsbeck's players
  left it ("vbi is active", says Professional's source): 49.92 times a second on a PAL Amiga, and
  so in siday. UADE plays it a little faster, on DeliTracker's timer.
- **How TFMX 7V's four voices are mixed.** They are mixed as the player mixed them: at its own
  16 kHz, with nothing between one sample and the next, and clipped to a byte. A buffer is mixed
  from what the voices were told the tick before, and heard the tick after, as it was on the Amiga.
  siday's Paula, the Amiga's sound chip, plays the buffers as the fourth voice, so the seven voices
  are filtered and panned as the Amiga had them.
- **When a song ends.** The library takes a song to have finished when its tracks have all come to
  an end, or to patterns that go round for ever. It then stops the song, to know how long it is.
  Chris Hülsbeck's players play on: the patterns go on round, or the notes that were sounding go on
  as their macros have them. So they do in siday, and that is where the song is counted as having
  come round. (A song that says Stop, stops.)
- **Level.** TFMX music is quieter than modules played on the same chip, and is turned up to match.

Over the first 40 seconds of the first song of each module, 315 of the 320 that play write the same
periods and volumes as UADE's players, tick for tick.

### Differences and limits

- One of Masterblazer's modules plays sounds at random, which its player takes from where the
  screen's beam is. That cannot be followed.
- One of Fatal Heritage's modules gives two voices their new notes a tick early, from 21 seconds on,
  for no reason that has been found.
- Three differ by a tick or two where a tempo changes, or at the start.

Three modules are silent, one of them a game's sound effects. Two are refused, having no songs.

## HIP and FC — Jochen Hippel's TFMX, and Future Composer

Jochen Hippel, "Mad Max", wrote music for the Atari ST and the Amiga from the late 1980s. His games
include Amberstar, Dragonflight, Lethal Xcess, Leavin' Teramis and Astaroth. His player was his own,
and he called it TFMX too, though it has nothing but the name in common with Chris Hülsbeck's. The
two knew each other, and Hülsbeck's TFMX 7V took the idea of seven voices from Hippel's.

Hippel's modules are kept in a few ways:

- **HIP, SOG:** most often, a module is kept with the 68000 player it was made for at its beginning.
- **COSO, kept as HIPC or SOC:** later modules were compressed.
- **HIP7, S7G:** some play seven voices on the Amiga's four, three as they are and four mixed by the
  processor onto the fourth.

The player changed from game to game, and no one copy of it plays every module.

Future Composer is an editor made public by The Superions: versions 1.0 to 1.3 in 1989, whose files
say "SMOD", and 1.4 in 1990, whose files say "FC14". It is Hippel's player with a few changes, and
an editor of its own. That is why siday plays the two by one player, and tells of them in one place.

### How siday plays it

siday's player is Michael Schwendt's, from libtfmxaudiodecoder. It began as a player of Future
Composer and grew to play Hippel's TFMX in all its kinds. It tells them apart by their contents, by
the player code at their beginning, and by checksums of the modules that need it. It is ported here
line for line.

Three things in siday are not the library's:

- **TFMX 7V's mixing.** The four mixed voices are mixed as Hippel's own player of it mixed them, as
  Wanted Team keep it for EaglePlayer. That is the same way as Chris Hülsbeck's (see TFMX), but at
  24 kHz, as UADE runs it. The player runs first and the buffer is mixed after, so what the four are
  told is heard a tick after the rest. The library adds the four at the rate of its output.
- **Amberstar.** Amberstar's songs keep their notes only: their header says that their samples begin
  where the file ends. The game had one file of samples for all of them, `set.smp` (`samp.hipc`
  beside the older copies). siday finds that file beside a song, as it finds any file that comes
  with a tune, and puts it after the song, so the songs are heard. Neither the library nor UADE
  plays them, so there is nothing to compare them with.
- **Level.** Hippel's music is louder on the Amiga's chip than modules are, and is turned down to
  match.
- **COSO's speed.** Hippel's COSO player was called "each vbi", its source says: each frame of the
  display, 49.92 times a second on a PAL Amiga. siday plays it so. The library and UADE play it fifty
  times a second, a little faster. How the other kinds were called is not known, and they are played
  as UADE plays them.

All 229 files of music in the collection are played; the one file left over is Amberstar's samples.
Over the first minute, siday's stereo loudness envelope matches UADE's to 0.975 on average, where
the library's matches to 0.962.

## PUMA, PAP, GMC and IMS — four small players of games' music

Not every game's music was made in a tracker anyone could buy. A programmer or a studio often had a
player of its own, and an editor for its musician. The music was kept as that player wanted it, and
went no further than the games it was made for.

Four such players are here, each with the games of UnExoticA's collection that used it. Each is
played by its own 68000 code. Wanted Team and others kept that code as players for EaglePlayer and
DeliTracker, and UADE runs it today.

### PumaTracker

PumaTracker was Jean-Charles Meyrignac's and Pierre-Eric Loriaux's ("(c) 1991", its player says).
The music of Toki, Liquid Kids, Snow Bros and Elf was made in it, by Loriaux, Jean Baudlot and
Matthew Cannon (45 files).

It is part tracker, part synthesizer. A song is a list of orders. Each order gives each of the four
voices a pattern of 32 rows, and moves its notes and instruments up or down. An instrument is two
little scripts run on every tick: one for the volume and the sound, the other for the pitch. It can
play one of the module's ten samples, or one of 42 short waveforms of the player's own, and sweep
from one waveform to the next as a note plays.

Three of PumaTracker's files (two of Toki's, one of Snow Bros') play notes past the end of the
player's table of periods. There the player reads on into what follows the table. What that is
depends on where the game put the module in memory, and siday reads it as it is where UADE puts it.

### Pierre Adane's packer

Pierre Adane packed the music of two more of Loriaux's games, Pang and Ivanhoe (22 files), with a
packer and player of his own ("(c) 1990 by Pierre Adane"). A file is a tracker's module made small:
each voice has its own list of patterns, and the empty rows after each note are left out.

The samples, which the tunes of a game share, are in a file of their own. It is `set.smp` beside
them in UnExoticA's collection, or `smp.set`, the Amiga's name for it. siday finds it as it finds
any companion file.

One of Pang's modules has one sample's length wrong. Pierre Adane's player mends it as it loads it,
by a test that only that module meets, and siday mends it in the same way.

### Game Music Creator

Game Music Creator was Andreas Tadic's tracker. Its replayer went into some twenty games of the
collection (50 files), from Deuteros and Fatal Mission to Manic Miner and Jet Set Willy 2. It has
fifteen samples, patterns of 64 rows, and a few commands, much as the first SoundTracker had.

Its modules are near enough to ProTracker's that ProWizard can unpack them into ProTracker modules,
though it refuses some or finds them cut short. siday plays them with Game Music Creator's own
player
instead, which Delirium and Buggs adapted for DeliTracker and EaglePlayer. So they are all heard,
and
as they were made:

- Its slides go on every tick until the voice's next note, where ProTracker's stop at the next row.
- A note starts with its voice turned off for a tick.
- After a jump in the order, the voices after the one that jumped read their notes from where the
  player has been left pointing. Deuteros's music depends on this.

A Game Music Creator file named as a ProTracker module is still unpacked by ProWizard (see MOD).

### Images Music System

Images Music System was the tracker of Images Software ("(c) 1990"). In it Matthew Simmonds and
Jolyon Myers wrote the music of the games the company brought to the Amiga: The Hunt for Red
October, Shadow Dancer and Beast Busters (12 files). Its modules are much like SoundTracker's, but
each note is three bytes: a note of the player's own table rather than a period.

A module may hold several songs. Each ends with a jump in the order, and the next begins after it,
which is how Wanted Team's player finds them. Beast Busters has more songs than its jumps tell, and
has the list of them that Wanted Team made for it.

Images Music System's E command turns the Amiga's filter on or off, as ProTracker's E0x does, and is
heard so. The one file that has it only turns it off.

Images Music System's player was run each frame of the display, from the frame's interrupt, as its own
code shows. siday plays it so, 49.92 times a second; UADE plays it on DeliTracker's timer, a little
faster.

### How siday plays it

Each of the four players is here as its own code is, tick by tick. All 129 files are played, and
none was found to be other than it is named. On every file of the collection, the players' register
writes match UADE's tick for tick from the first sound, over the first one to five minutes.

Worth knowing, about siday's choices and the players' own ways:

- **Song ends.** A song has come to its end when its first row is played again. For Game Music
  Creator's files that loop only by jumping (Deuteros), it is when the order comes back to a place
  it has played. The players either say nothing, or say so a row or so before.
- **Reading past the end.** Sometimes the players would read past the module or their own tables, or
  stop, or never end. Then siday reads what they would read, or plays silence, or ends the song, as
  told in the code.
- **Level.** Each of the four players' music is louder on the Amiga's chip than modules are, and is
  turned down to match.

## DUM and others — more players of games' music, ported

Some of the Amiga's games kept their music as data for a player of their own. The players for
DeliTracker and EaglePlayer then took those players over, ripped from the game or written again.
siday ports each such player to Swift, from the source UADE carries of the player that plays it.

Some of these players wait for Paula, the Amiga's sound chip, between voices. siday plays each
voice's register writes at their moment in the tick, as they fall in UADE. Some of these scores play
one sample on two voices a little apart in pitch, and how far apart the two start is heard.

On the files of UnExoticA's collection, each player matches its original player, as UADE runs it,
tick for tick, except where told below.

- **Infogrames** (`.dum`, with its instruments in a `.ins` file beside it): the music of Infogrames'
  games, by the player Andy Silva ripped for DeliTracker. The games are Bob Morane Ocean (whose
  files are those of Operation Neptune too), Bivouac (those of Chamonix Challenge and Final Assault
  too), Stir Crazy featuring Bobo and Captain Blood. Each tune is a song that plays once, at 107
  ticks a second. The instruments are found as the player finds them, by the score's name or that
  name less its last letter (`BOB4.INS` for `BOB4B.DUM`).
- **Infogrames' shared instruments:** Stir Crazy's and Captain Blood's scores share one file,
  `rh.ins`, which the player does not look for and siday does.
- **Fashion Tracker** (`.ex`): Richard van de Veen's, for Combine and Mini Golf Plus. A file is the
  game's own replayer and its music, at the address the game had them, found as Wanted Team's player
  finds them. A song ends where it comes round to its first pattern. The player says so as its last
  pattern begins, which would cut that one off. The replayer ran each frame of the display, as its own
  code puts it on the frame's interrupt, and so it does in siday.
- **Peter Verswyvelen Packer** (`.pvp`): the replayer of Whiz Kidz's Ziriax (1989), with Tomas
  Dahlgren's music for it and Zarathrusta. It is near enough to ProTracker to be taken for a packer
  of its modules. But its vibrato only ever goes down, and twice as far, so siday plays it by its
  own replayer, with its other ways too.
- **Alcatraz Packer** (`.alp`): Andy Sterbenz's of 1995, for Cedric and Oldtimer, most with their
  samples in a file beside them (`title.smp`). Eleven of the twelve files use a command (9) that
  Wanted Team's player does nothing with. From the music it looks to be a slide of the volume, which
  the twelfth file does with another command (8). siday plays it as that slide. Without it, Cedric's
  lead holds its notes flat; with it they swell and fade. Heard both ways, the slides are the music.
  Its replay ran each frame of the display, from the frame's interrupt, as its code shows, and so it
  does in siday.
- **Digital Sonix & Chrome** (`.dsc`): David Hanlon's music, with Andrew E. Bailey, for Dragon's
  Breath (1990), by the game's own player. Each row is a sample for each of the four voices, or
  nothing. A sample is played once and then its loop so many times, counted by Paula's interrupts.
  The files are seven tunes and five banks of the game's sound effects. On one note in forty, a
  note's first interrupt is lost to a race of the player's with the chip, and it falls on other
  notes in the two Amigas, siday's and UADE's.
- **Andrew Parton** (`.bye`): his music for MicroProse's B-17 Flying Fortress (1993), by the game's
  own player. It has twenty samples, each with its envelope and vibrato, and notes as a stream much
  like MIDI's. A tune ends when its stream does and its notes have died away (or five seconds after,
  for one that ends on a held note).
- **Editeur Musical Séquentiel** (`.ems`): Thomas Pimmel's, version 1.24 of 1991, for OCB and
  Imperial (Jean-Marc Boursot's music). Its modules are near enough to Ultimate Soundtracker's, with
  commands numbered its own way.
- **Forgotten Worlds** (`.fw`, "FWMP"): Mark Cooksey's music for Arc Developments' Amiga version of
  the game (1989), by the game's own replayer, which Psygore's player for EaglePlayer carries. That
  player is broken: it turns on the wrong registers in place of the voices. So in UADE four of the
  five files are silent, and the rest stall; siday was compared with copies of it mended in scratch.
  The tunes go round for ever, each voice on a length of its own. A song ends here once every voice
  has gone round at least once.
- **Leggless Music Editor** (`.lme`): Steve "Leggless" Hasler's of 1990, for Ninja Spirit (17 songs)
  and Punisher. Its instruments are samples, or square waves of its own whose width it varies. On a
  note's first tick, Wanted Team's player gives the note a volume of eight times its voice's number,
  by a slip of a register. siday gives it its instrument's volume, as Hasler's own code gave it.
- **JamCracker** (`.jam`, "BeEp"): JamCrackerPro's, by M. Gemmel and Xag of Betrayal, as DEFECT's
  player for EaglePlayer has it. It is here for Roll or Die (Ingmar Hansch's) and Paramax (Martin
  Tykesson's). Its instruments are samples or short waves mixed afresh on every tick, each note with
  its own speed, arpeggio, vibrato and slide.
- **A.M.Composer** (`.amc`): Marc Hawlitzeck's, of 1989, version 1.2, for his Magic Jumper and
  Thomas Porschen's Krymini. It has no patterns, but eight lists of events, four of notes and four
  of effects, at a speed each module sets for itself.
- **Professional Sound Artists** (`.psa`): the player of the game The Punisher ("(c) 1990 by Dave
  'Sinbad' Hasler", Wanted Team's player says). Its instruments are samples or a square wave whose
  width it varies, with an envelope of four stages.
- **The Musical Enlightenment** (`.tme`): N. J. Luuring jr's, of 1989 and 1990, for Labyrinth's
  sixteen tunes. Its instruments have lists of instructions for their vibrato and tremolo,
  envelopes, arpeggios, slides and glides. Its author made it "to be added to your
  vertical-blank-handler", and siday runs it each frame of the display.
- **Steve Turner** (`.jpo`): Graftgold's first driver, Steve Turner's, at a hundred ticks a second.
  It played his Rainbow Islands and Jason Page's Paradroid 90, Simulcra and Ivan "Ironman" Stewart's
  Super Off Road. Its instruments have up to three parts to their pitch, and envelopes with tremolo,
  vibrato and slides. siday plays them as the game's own driver played them.
- **Steve Turner's songs in Wanted Team's player:** that player takes a voice a song does not use
  for one of the game's sound effects, and plays an instrument on it. It also makes every song go
  round, where the driver goes on to the song the song names, or stops (twenty of them do).
- **Cinemaware** (`.cin`): Cinemaware's own player, from Wings (1990), its last game for the Amiga,
  with Gregory Haggard's music. It is near enough to MIDI: sixteen channels of notes, programs,
  pitch bends and controllers, given to the four voices as the player chooses. Each instrument has
  envelopes of pitch and volume, vibrato, and up to three IFF samples by the note. The samples come
  from a folder beside the scores (`Instruments`), as Sonix's scores have theirs. The game set its
  timer to NTSC's sixty ticks a second whatever the Amiga, so on a PAL Amiga it ran a little slower,
  59.45 a second, and so it does in siday (UADE plays it at sixty).
- **Paul Shields** (`.ps`): his music on Paul Hunter's player, of 1988 to 1991, for Airball, Jug,
  Goldrunner II, Amiga Soccer and Psygnosis' Amnios. It is played by two of the player's replayers.
  The first has seven waves of its own, one of them 400 bytes of the player's own code played as
  noise. The second, for Amnios, has envelopes of pitch and volume by the instrument.
- **SoundPlayer** (`.sjs`, with its `.smp`): Scott Johnston's driver for DMA Design's Lemmings
  (1991), with Tim Wright's music, and that of Oh No! More Lemmings and Christmas Lemmings 1994
  (Brian Johnston's) and Christmas Lemmings 1993 (Andy Whyte's). Each voice reads its own column of
  the score from its own place, so a wait in one lets the others go on. The samples are IFF files
  one after another in the file beside the score. The tick is the score's own, about 49 a second in
  Tim Wright's.
- **SoundPlayer's fades:** Wanted Team's player moves a fading volume without telling the sound
  chip; siday follows the game's own player, which does tell it. No file in the collection fades.
- **Paul Robotham** (`.dat`, with its `.ssd`): his music on Pete Barnett's driver, "another 4 voice
  MIDI clone" as Wanted Team's notes call it. It is here for Space 1889, Ashes of Empire, Dawn
  Patrol, MegaTraveller 2 and Starlord. Starlord's player (MicroProse's, of 1994) is the one played,
  with the two commands for the Amiga's filter that Dawn Patrol's has. The samples are in a file
  beside the scores, by the score's own name or, as most of a game's scores share them,
  `mdtest.ssd`.
- **Paul Robotham's scores:** as `.dat` is the name of many files of other kinds, a file is played
  only when the player's own check finds it a score.
- **Paul Robotham's song ends:** a song stops where all its voices have ended, as the driver has it.
  Wanted Team's player begins it again as soon as its first voice reaches its end, which cuts the
  last notes of the others short, by up to four seconds. Most of Ashes of Empire's scores, and Space
  1889's, go round a loop of a hundred times or more. siday takes that as for ever, and each time
  round is the song's end.
- **Thomas Hermann** (`.thm`, with its `.smp` or its folder of instruments): his player of 1989 for
  Magic Bytes' Beam, Blue Angel 69 and Nightdawn. The samples are in a file beside the module.
  Failing that, each is in an IFF file in the folder `Instruments` beside it, by the name the module
  gives it, in any case. The song runs on a timer of its own, about 43 times a second, and the
  slides and envelopes on the game's frames, 49.92 a second.
- **Thomas Hermann's songs:** which songs a file has is known only by its size, as the player knows
  it: Blue Angel 69's five, and three in Beam's unused music.
- **Thomas Hermann's timer:** Wanted Team's player writes the second timer's two bytes the wrong way
  round, and runs the effects about 26 times a second. siday follows the game's way, as the game's
  own code has it. siday also plays that code, as Blue Angel 69's custom module.
- **Synth Dream** (`.sdr`, with its `.smp`): the player of Laurens "Lotus" Tummers and John Tonnard,
  of 1991, for Eclipse's Monster Business, whose eight modules share their samples in `set.smp`. Its
  instruments are samples, or synthesised: on every tick the player copies one of sixteen square
  waves into the voice's sixteen bytes. Each instrument has tables of volume, pitch, added note and
  wave, each with counts and repeats. A note's last tick turns its voice off and the next note turns
  it on, so notes have a tick of silence between them.
- **Synth Dream's pitch tables:** Wanted Team mended the end of a table of pitch, whose test in the
  original hung on where in memory the player was loaded; siday follows their mend.
- **Blade Packer** (`.uds`, with its `.smp`): Tord "Blade" Jansson's, made on the Atari ST and taken
  to the Amiga and the PC (1991-96), here for Unique Development's preview of Obsession (1995). The
  patterns are packed through a dictionary of cells. The commands are near ProTracker's, with a few
  of its own: a slide down that goes up, a note struck again, and a command that begins the song
  again. A file is many songs, one after each jump or restart in its patterns.
- **Blade Packer's timing:** the player keeps its own copy of the sound chip's registers, and passes
  it to the chip at the start of the next tick. So everything is heard a tick late, as it was. A
  voice that has had no note yet is given a period of zero, so its first note is not heard, as on
  the machine. Two songs differ from UADE's by two or three ticks of silence that UADE hurries
  through.
- **Tim Follin** (`.tf`): his music for Ghouls 'n Ghosts, Sly Spy: Secret Agent and Puzznic, played
  as Andy Silva's Follin Player II for DeliTracker plays it. Each voice reads a stream of notes and
  commands, with calls, jumps and loops. The player writes waves of changing width into its samples
  as they play. Puzznic's file is the game's own, with its code; the others are the music alone,
  behind the head of an Atari ST program. A file is taken for Tim Follin's by its name, since the
  player's own check takes some of Ron Klaren's too.
- **Tim Follin's song ends:** the player has no song end of its own, so a song ends here when every
  voice has stopped or gone back. One of Puzznic's songs calls without returning. In the player,
  that fills up its stack until, after seven times round, the song falls silent. siday leaves out
  the calls that would overflow, and the song goes round as it began.
- **Paul Summers** (`.snk`): the music drivers of Paul Summers's and Mike Chilton's games of
  1989-90: Fighting Soccer, Postman Pat, Everton F.C. Intelligensia's jingles and P47 Thunderbolt.
  Each file is the game's own driver, from which the player finds its samples, songs and periods.
  Each song has its own timer. Wanted Team's player reads the wrong byte, and so lets the fourth
  voice's samples go round for the whole of a note, and slows Everton's jingles by one tick in every
  few. siday follows the games' drivers, which do neither.
- **Action Amics** (`.ast`): Action Amics' SoundTools, here Eike Steffen's music for Dyna Blaster.
  It is played as its player for EaglePlayer plays it, read in that player's 68000 code. Its
  instruments have envelopes and runs of samples, notes and pitches, and a stretch of a sample that
  can be turned upside down a byte at a time. Of its 32 songs, the 20 before the tool's empty ones
  are played.
- **David Hanney** (`.dh`): his music for Tearaway Thomas, whose files carry only the notes. The
  game's three samples and sixteen instruments are carried in siday, as Wanted Team's player for
  EaglePlayer kept them. Thirteen of the instruments are short waves that the player changes as they
  play. The player is made after a reading of its 68000 code.
- **Ron Klaren** (`.cm`, `.rk`): his music for Battle Squadron, Cyberblast and Plague, with Ivo Zoer's
  replay routine, "CustomMade". A `.cm` file is the game's own code with its music, as the game had
  it in memory; a `.rk` file is the same, some kept as an Amiga program. Wanted Team's player for EaglePlayer
  carries a copy of the routine of its own, from Cyberblast, and plays every file with it, finding in
  each only its songs, samples and arpeggios. siday ports that player, read in its source. It reads
  the speed of the game's timer wrongly, a byte of the next instruction for the timer's low byte, so
  UADE plays the music about one per cent slow. siday plays it at the games' speed. Battle Squadron's
  four tunes and Plague's ingame are here as DeliTracker's custom modules too, the games' own code.
- **Jason Page** (`.jpn`, its samples in a `.smp` file beside it): Graftgold's second music driver,
  for Realms (1991), Fire & Ice (1992), Uridium 2 (1993) and Empire Soccer 94. It is not Steve
  Turner's, Graftgold's first. Wanted Team's player for EaglePlayer holds the driver as three games
  had it, Realms', Empire Soccer 94's and ViroCop's, and siday ports the first two from its source.
  ViroCop's is not played, as no file of it is here to check it by. An instrument is a list of
  commands: its sample, period, volume, envelope and vibrato, and the copying or morphing of part of
  one sample towards another as it plays. Realms' ingame tune is played in its sixteen parts, as
  Wanted Team's player splits it.
- **SoundControl** (`.sct`): Holger Gehrmann's music system, which he began in 1982 for the VIC-20,
  and took to the C64, PCs and the Amiga. Wanted Team's player holds its versions 3.0, 3.2, 4.0 and
  5.0, each as a game had it (Dynatech's, Penthouse Hot Numbers Deluxe's and Biing!'s), and tells
  them apart by how a module is laid out. siday ports all four from its source. They play the music
  of Gehrmann's own games, of Allan Pedersen's North Sea Inferno and of Silvio Tognazzi's Penthouse
  Hot Numbers Deluxe. Version 3.2's routine plays a note it does not move a semitone down, as UADE does.
- **Synth Pack** (`.osp`, with the samples a game's songs share in `set.smp` beside them): Karsten
  Obarski's music for Centerbase and Dyter-07. He wrote SoundTracker too, but this shares nothing with
  it. Wanted Team's player for EaglePlayer holds the two games' routines, which lay out their songs in
  two ways. An instrument is a sample, or a window of 128 bytes swept through a bank of waves, with an
  envelope of four stages, tremolo, vibrato, bends of its pitch as it starts and as it is let go, and
  arpeggios. siday ports both routines from a reading of that player's 68000 code; there is no source.
- **Silmarils** (`.mok`): the music of Silmarils' games of 1989 to 1992 (Ishar, Crystals of Arborea,
  Storm Master, Starblade, Colorado, Targhan, Metal Mutant, Boston Bomb Club and others), by Michel
  Pernot's replayer, on three voices, at 216 ticks a second. A file is one of the games' own resource
  files, with the game's script in it, which puts the samples in their places and starts a score: siday
  runs that script as Wanted Team's player for EaglePlayer does, and ports the player from a reading of
  its 68000 code. Three of Boston Bomb Club's tunes keep only two samples of their own and find the
  rest in `BostonBombClub.mok` beside them, the file of their name up to its first underscore, as the
  player looks for it; UADE does not find it there, and plays them only when it is given it under its
  Amiga name. One note in Colorado's first song is lost in UADE, by a race of the player's with Paula
  that siday does not follow.
- **Soundfactory** (`.psf`): Profiteam's Soundfactory 1.0 of 1989, by Zuheir Urwani and Thomas
  Kolbe, mostly heard in the music of Oliver Becker and Michael Volz (Master Control Program). Each
  voice reads a stream of notes and 29 commands, with calls and returns, loops, a fade and the
  Amiga's filter. Which voices a song has are its subsongs. Danger Castle's first has none, and is
  passed over.

Each of these players is brought to the level of other modules.

## BP — Brian Postma's SoundMon

Brian Postma's SoundMon was a tracker for the Amiga in which the instruments are made by the player
as much as they are recorded. An instrument may be a sample. Or it may be a waveform of 64 bytes
from the module's own tables, which the player shapes as it plays, with:

- an envelope of its loudness (ADSR);
- a vibrato (LFO);
- an envelope (EG) that turns the first part of the waveform over a byte at a time.

SoundMon 2.2 added a modulation that rewrites one byte of the waveform, and effects that smooth it
or bend it towards another. So a whole tune of SoundMon's could be a few kilobytes, and many games'
music was made in it. Its files name their version where the title ends: "V.2" for SoundMon 2.0's,
"V.3" for 2.2's. Brian Postma put his replay routines into the public domain.

UnExoticA's collection has 80 SoundMon files (58 of 2.0, 22 of 2.2). They are by Allister Brimble
above all (Alien Breed, Project-X, the Dizzy games and a score more), Christian Blaha (Aztec
Challenge, Frantic Freddie, Real Popeye) and Ingmar Hansch (Roll or Die).

A module has fifteen instruments, then a list of steps. Each step gives each of the four voices a
pattern of sixteen rows, and moves its notes and instruments up or down. Then come the patterns, the
waveform tables and the samples.

### How siday plays it

siday plays each file by the player of its version, as UADE runs it: Brian Postma's replay routines,
as mld adapted them for UADE. What the player writes to Paula, the Amiga's sound chip, on every tick
matches UADE's, for all 80 files over their first three minutes.

The first SoundMon's files, which say "BPSM", are played by neither of these players, and siday does
not take them. There are none in the collection.

Worth knowing, about siday's choices and the players' own ways:

- **Song ends.** A song has come to its end when the list of steps comes round. It has also ended
  when a jump goes back to a step it has played and would be taken again the next time. A jump the
  player is told to take a number of times is not an end until the count is done. The players say
  nothing of an end.
- **The filter.** The filter command (option 3) turns the Amiga's filter on, or off with zero, and
  is heard so. One file (CLUMSY) has it, and turns the filter on only in its third song.
- **Past the tables.** Where a note or an instrument falls past the player's tables, the player
  reads what follows them, as it would where UADE puts the player and the module.
- **Level.** SoundMon's music is a little louder on the Amiga's chip than modules are, and is turned
  down to match.

### Several songs in a file

Many of the games' files hold several of their tunes in one module, each looping on itself. The game
set the player going at the step it wanted (ANTICS has five such tunes). The players themselves have
no songs but the one from the first step, which is all UADE plays.

siday looks through the steps that song never plays for more songs, as it does for a module of any
other kind. A song begins at the first step not yet played. It is kept if a note is played in it and
it lasts a second or more. But it is not kept if it only leads, in less than half a minute, into a
song found before it.

One thing is added for SoundMon. A short piece that goes on into an earlier song only where that
song is silent is a song. The games end their jingles so, each jumping to one step of silence that
goes round on itself. So 22 of the 80 files have more than one song, 149 songs in all (DIZZYMUSIC2
has thirteen, most of them jingles).

A song is begun as the player is once its set-up has run, but at its own step, as a game that set
the player's step there would have begun it. SoundMon 2.0's count of repeats is then at one, so the
first jump of 2.0's that no count was set for is not taken. (In BIGNOSE, whose first four steps each
jump to a tune, two songs begin with a step of silence.)

## SIDMON — SidMon and SidMon II

SidMon was a tracker of Reinier van Vliet's for the Amiga ("SID-MON BY R.v.VLIET (c) 1988", its
player says). It is named for the Commodore 64's sound chip, and makes its sound much as that chip's
music did: short waveforms shaped as they play, rather than recorded instruments. SidMon II, "the
MIDI version", followed.

Their tunes rewrite their own waveforms as they play. SidMon II's player flips the bits of a
sample's bytes as it goes. SidMon's later player mixes two waveforms into a third, and negates a
byte of another, on every tick.

UnExoticA's collection has twelve of SidMon II's (Cobra, Cubulus, Ice Runner) and three of SidMon's,
Venom Wing's. SidMon's are named SID like the Commodore 64's files, and keep their player's 68000
code in front of the music.

siday tells them apart by how they begin. The Commodore's files say "PSID" or "RSID". SidMon's begin
with its player, which its own check finds. Of all the SID files in the collection, it takes exactly
Venom Wing's three. Their code is one of two versions of the player, an earlier and a later. siday
tells the two apart by their bytes, and plays each by its own rules. The 68000 is not emulated, and
a file with a player of another kind is not taken.

### How siday plays it

Each is played by its own player, as UADE runs it. The register writes for Paula, the Amiga's sound
chip, and the bytes Paula plays from the rewritten waveforms, match UADE's for all fifteen files
over their whole songs.

Worth knowing, about siday's choices and the players' own ways:

- **Song ends.** A song has come to its end when its list of steps comes round. The players say
  nothing of an end.
- **Three ways found by comparison.** Three things about SidMon's players were found only by
  comparing them with UADE. Paula takes no odd addresses for a sample, so a sample that begins at an
  odd address begins a byte before. The later player's start leaves its tick counter as the file has
  it. And a sampled instrument goes straight to its note when the value the voice before left behind
  says so.
- **Level.** SidMon's and SidMon II's music is louder on the Amiga's chip than modules are, and is
  turned down to match.

## MUG — Digital Mugician and Mugician II

Digital Mugician was Reinier 'Rhino' van Vliet's tracker after SidMon ("(c) 1990-94", its player
says; its files begin " MUGICIAN/SOFTEYES 1990"). In it, synthesised and sampled instruments are
played together, and its effects rewrite the waveforms as they play.

Mugician II ("(c) 1991-94") plays seven voices on the Amiga's four. Three play as they are, and four
are mixed by the processor into a buffer that the fourth plays. Chris Hülsbeck's and Jochen Hippel's
players of seven voices did the same.

UnExoticA's collection has 26: 24 of the first (Borobodur, Bump 'n' Burn, Winter Camp, Quest of
Agravain, and five of Hoi AGA's, named DMU) and two of Mugician II (Clockwiser, Borobodur). A file
holds several songs, counted as the players count them.

### How siday plays it

Each is played by its own player, as Wanted Team keep it for EaglePlayer and UADE runs it, from
their source. The player's register writes, and what it writes into its waveforms, match UADE's for
every song of every file over its first 40 seconds (but for one voice that plays nothing).

Mugician II's four mixed voices are mixed as its player mixes them, at 22 kHz as UADE sets it (the
player's own default is 16). They are heard a tick after they are mixed. Each of the seven voices
has its own light, scope and note, and can be muted or heard alone; the mixed ones are then left out
of the mixing.

Worth knowing, about siday's choices and the players' own ways:

- **Note starts.** The players turn a note's voice off as they read its row, and on again only at
  the end of their work, so the note is silent until then. That is 1.8 ms into the tick for the
  first player, and 13 ms for Mugician II, after its mixing. siday starts notes where they start in
  UADE's playing of the collection (its median). Everything else the players write is done at the
  tick's start.
- **The filter.** The commands for the Amiga's filter ($45 on, $46 off, $47 the other way) are
  heard, as the players set it. The filter is off when a song starts.
- **Level.** Digital Mugician's music is louder on the Amiga's chip than modules are, and is turned
  down to match.

## DM2 — Delta Music 2.0

Delta Music 2.0 is a tracker of synthesised and sampled sound. Its modules carry their own player in
front of the music. UnExoticA's collection has eleven, all of them Bent Nielsen's music for
Nebulus 2. Their players are the same code, except for the places it is loaded at. Delta Music
1.3's files,
which UADE also plays, are not in the collection.

### How siday plays it

siday's player is its own reading of that code. The code in a module is not run, so a module whose
player is other code than this is not taken. siday matches UADE tick for tick on all eleven files.

Worth knowing, about siday's choices and the player's own ways:

- **Note starts:** The player turns a note's voice off as it reads its row, and on again at the end
  of its work for the tick, about a millisecond in. That is where siday's notes begin, as UADE's do.
- **Low notes that carry on:** On the Amiga, and in UADE, a low note sometimes carries on rather
  than starting again. That is because Paula, the Amiga's sound chip, stops a voice only at the end
  of a word. It happens to about one note in forty, and to a third of Hardy Hitech's bass notes.
  Which notes it happens to depends on Paula's timing more closely than the player's timing can be
  known here, so in siday every note starts again.
- **Song end:** A song has come to its end when its first voice's list starts again from its loop.
- **Filter:** The command for the Amiga's filter is heard. Any value but zero turns it on, and it is
  off when a song starts.
- **Level:** Delta Music is louder on Paula than other modules are, so siday turns it down to their
  level.

## MXTX — MaxTrax

MaxTrax was a music driver for the Amiga, written by Talin (David Joiner) and Joe Pearce. The
Dreamers Guild licensed it to game developers. Its source was later released under the GNU Lesser
General Public License, and UADE carries it.

It is not a tracker. A score is a list of MIDI-like events on sixteen channels, played on sampled
instruments with envelopes. The driver chooses which of the Amiga's four voices plays each note, so
that music written for MIDI could be heard on an Amiga.

It was used for games brought to the Amiga. UnExoticA's collection has 83 files of it, from Dune II
and Legend of Kyrandia (Westwood), Darkseed, A-Train, Might and Magic III, SimAnt, SimEarth,
Contraption Zack and the Gold Box games.

### How siday plays it

A file may hold several scores, each a song in siday, and the instruments. Or it may hold the scores
alone, with their instruments in a file beside them: `set.smpl` in the collection (A-Train's and two
of Kyrandia's). siday finds that file as it finds any companion file. Four files hold instruments
and no score, and are not tunes.

Legend of Kyrandia's tempos are set by the game as it starts each score. siday takes them from the
game as ScummVM, which plays the game, has them.

siday's player is a port of the driver, routine by routine. Checked against ScummVM's player, with
the ways that player departs from the driver put back, it matches tick for tick on 282 of the 283
songs.

Worth knowing, about siday's choices and the player's own ways:

- **Timing:** The driver runs on the Amiga's display, a little less than fifty times a second (49.92
  for a PAL frame). Its filter commands are heard.
- **Tempo slides:** A falling tempo slide races before it settles, because the driver takes the
  change as a number without a sign. siday plays it so, as the source has it, though the games may
  have had an older driver.

### Differences and limits

- **Missing instruments:** Notes of instruments a file does not have are left out, as the driver
  leaves them. Four files have such notes, and say so.
- **Scores with no end:** A score that runs off its end without an ending event is ended there. Two
  do, and say so.
- **Empty scores:** Nine scores are empty.

## SA — Sonic Arranger

Sonic Arranger was a tracker of synthesised sound by Carsten Schlote, Branko Mikić and Carsten
Herbst ("(c) 1991-95", its player says). Its instruments are waveforms, shaped by a score of effects
as they play.

UnExoticA's collection has 118 files. Most of them are Matthias Steinwachs' music for Ambermoon and
Lionheart. There is also Nils Ruzicka's music for Marvin's Marvellous Adventure, and Frank
Lautensack's for Dimo's Quest. They come in three forms:

- **The editor's modules**, which say "SOAR" (42 files).
- **Games' songs**, with the parts unnamed (28).
- **Songs with Sonic Arranger's own replay routine** in front of them (47).

One more, of Ambermoon's, is a sample, not a module.

### How siday plays it

siday plays each as UADE plays it. The editor's modules and the games' songs are played as Wanted
Team's player of the format plays them. The songs with a replayer in front are played by that
replayer's rules. These differ from Wanted Team's in small ways: the master volume, the instrument
number, and how a voice is stopped. The replayer comes in two builds, which siday tells apart by
their bytes. The 68000 is not emulated.

siday matches UADE tick for tick on all 240 songs of the 117 modules.

Worth knowing, about siday's choices and the player's own ways:

- **Random numbers:** Two effects read the position of the display's beam as a random number. In the
  three files that use one, siday takes it from the tick's time instead.
- **Song end:** A song has come to its end when it goes past its last position, or when a jump goes
  back to a position already played.
- **Filter:** The filter command, E, turns the Amiga's filter on with zero and off otherwise, and is
  heard so. No song in the collection turns it on.
- **Level:** Sonic Arranger's music is louder on Paula, the Amiga's sound chip, than other modules
  are, so siday turns it down to their level.
- **Speed:** Each song says how many ticks a second it runs at, and the replayer sets the Amiga's
  timer from the PAL count for a second over that number. siday does the same for every module,
  those with their own replayer too, which UADE runs fifty times a second whatever the song says.

## SONIX — the Sonix Music Driver

Aegis Sonix (1987) began as Musicraft, a music program Commodore had made for the Amiga and never
sold. Aegis Development bought it, and had the two who wrote it, Mark Riley and Gary Koffler, carry
on with it. It was a score editor that wrote music as notes on staves. Beside it were a synthesiser
of the Amiga's four voices and an editor of sampled sounds.

Sonix kept its songs as SMUS, the Simple Music Score that Jerry Morrison of Electronic Arts had set
down as part of IFF. IFF is the Amiga's way of keeping files of every kind. A SMUS file names its
instruments but does not hold them. Sonix kept each in a file of its own, `NAME.instr`, and the
sound of a sampled one in another, `NAME.ss`, in a folder named Instruments.

Games used Sonix's music through the Sonix Music Driver, Mark Riley's player of it ("Sonix Music
Driver (C) Copyright 1987-91 Mark Riley", its copies say). Its scores come in three kinds:

- **SMUS**, as Sonix saved it.
- **TINY**, a shorter form. The games numbered its instruments. The copies here give them names of
  four letters instead, which is how Wanted Team's player of them asks for them to be kept.
- **SNX**, the driver's own.

UnExoticA's collection has 237 scores: 128 of SMUS, 82 of TINY and 27 of SNX. They come from
eighteen games, with a demo of one and another version of another. The games are Spirit of
Excalibur, War in Middle Earth, Rocket Ranger, TV Sports Football and Boxing, It Came from the
Desert and Antheads after it, four of the Carmen Sandiego games, Stellar 7, A-10 Tank Killer,
California Games, 4x4 Off-Road Racing, Alternate Reality, Bo Jackson Baseball and New York Warrior.

An instrument is synthesised or sampled. A synthesised one is a waveform of 128 bytes. As it is
loaded, the driver passes it through 64 filters, from bright to dark. It plays it through one of
them as its envelope and vibrato move it, with its phase and pitch slid, and it writes each voice's
waveform anew as it plays. A sampled instrument has its sound in the `.ss` file, in octaves. An
instrument can also be an IFF 8SVX sample, or, for SNX, an AIFF one.

### How siday plays it

Wanted Team's player of the scores for EaglePlayer, which UADE carries, holds three of Mark Riley's
own players, one for each kind. Wanted Team took them from games. siday's player is those three,
read in their 68000 code. The Amiga's memory, which the instruments are loaded into and the
waveforms written into, is kept as the Amiga kept it. siday matches UADE tick for tick on all 237
scores.

Worth knowing, about siday's choices and the players' own ways:

- **Timing:** Each player sets the Amiga's timer itself. SNX's player sets it from its tempo, with a
  tick of the score each time the timer runs out. TINY's and SMUS's set it from a table of 128
  tempos, a tick of the score being one to fifteen of the timer's. A tick lasts as long as the timer
  says, and a timer set during a tick counts from the next, as the Amiga's does. SNX's driver works
  its timer out from an NTSC Amiga's clock on any Amiga, so on a PAL one its songs go about one part
  in a hundred slower than UADE plays them, and so they do in siday.
- **The Instruments folder:** The whole Instruments folder beside a score is brought with it, on the
  command line and in the browser alike. The player finds in it the instruments the score names,
  without regard to capitals. On UnExoticA's copies, a full stop in an instrument's name has become
  an underscore in its file's name (`SNARE2.R8` is in `SNARE2_R8.instr`). siday takes either for the
  other.
- **Level:** The Sonix Music Driver's music is louder on Paula, the Amiga's sound chip, than other
  modules are, so siday turns it down to their level.

### Differences and limits

- **Missing instruments:** The driver would not play a score with an instrument missing. siday plays
  it without, and says which are missing. A score none of whose instruments is found is not played.
  In the collection, none is missing.
- **Damaged files:** Where a damaged file would have the player divide by zero, or read or write on
  through memory without end, siday stops short instead. No file in the collection comes near it.

## BD — Ben Daglish's drivers

Ben Daglish came to the Amiga from the Commodore 64. He played his music on it with a driver of his
own ("(c) 1988-92 by Colin Dooley & Ben(n) Daglish", Wanted Team's player of it says). The driver
went into each game with its music, in a copy made for that game.

A `.bd` file is that driver: 68000 code with its music behind it. It holds a table of entry points
(start a song, play a tick, stop), the four voices' variables, the code, its tables and the samples.
A song is four lists of patterns, one for each voice, with counts of repeats, transpositions,
changes of instrument and an end. A pattern is notes and their lengths, and commands for vibrato,
pitch slides and volume envelopes.

Periods come from a table of the twelve steps of an octave, scaled by each instrument's own. A
looping sample is changed to its loop two ticks in. A sample that does not loop is stopped as it
ends by an interrupt of Paula, the Amiga's sound chip. The driver waits for that interrupt before it
lets the note go.

UnExoticA's collection has 41 files of it, 135 songs. They come from Artura, Rick Dangerous and its
sequel, Switchblade, Super Cars, Pac-Mania, Motörhead, Blasteroids, Continental Circus, Deflektor,
Dynamite Dux, Heroes of the Lance, Hostile All Terrain Encounter, Mickey Mouse, Skidz and others. It
also has three files of another kind of his (`.bds`), his SID-like music, which is played as told
under CORE.

### How siday plays it

UADE plays them with Wanted Team's player for EaglePlayer. That player finds the driver's songs, and
makes the driver run as a routine and not as the interrupt it was written to be. It puts hooks into
it, and calls it fifty times a second. siday does the same in Swift, and runs the driver on its own
emulated Amiga (see DW). Paula's interrupts that end a sample are answered as UADE's Amiga answers
them.

siday matches UADE tick for tick on 129 of the 135 songs, and two more are silent in both.

Worth knowing, about siday's choices and the player's own ways:

- **Sample ends:** In four songs, a sample comes to its end within a few hundred of Paula's clocks
  of the moment the driver looks to see whether it has. Which tick sees it is a race, and UADE's
  slower 68000 and siday's run it differently. From one tick on, a note is let go one tick (1/50 s)
  sooner or later.
- **Louder early drivers:** In the earliest drivers (Heroes of the Lance, John Lowe's Ultimate
  Darts, Mickey Mouse), Wanted Team's player takes out the instruction that quarters a note's
  volume, "more volume power". siday's does too, as the reference has it. Those songs are four times
  as loud as the driver alone made them.
- **Song end:** A song has ended when the driver says so, and it starts again in the same tick, as
  the player has it.
- **Level:** Ben Daglish's music is louder on Paula than other modules are, so siday turns it down
  to their level.

## DW — David Whittaker's own drivers

David Whittaker wrote the music of a great many Amiga games (from 1987 to 1994, Wanted Team's player
of it says). He played it with a driver of his own, which went into each game with its music. A
`.dw` file is not music for a player to read. It is that driver, 68000 code with the music behind
it, as it was taken out of the game.

The driver begins with a few calls for the game to make: start a song, play a tick, stop, start a
sound effect, and in later ones fade. Its code writes straight to Paula, the Amiga's sound chip.
Every address in it is counted from one place within it, so that a game could load it anywhere, and
it keeps its own variables.

Each voice has a list of patterns that goes round. A pattern is a run of bytes for notes and their
lengths, the instrument, the volume envelope, an arpeggio or vibrato, and commands for slides, speed
and fading. A note's period is the note's own scaled by the instrument's, so that samples of any
rate play in tune. (The earliest driver works that out from each sample's rate, by the clock of the
American Amiga, as it first starts.)

The tempo can be a fraction of a tick: a count adds the speed each tick, and a tick is passed over
when the count goes round. Sound effects share the voices with the music, and while one plays, the
music is not heard on its voice.

That is what a tracker of 1987 did not give a game: music and effects from one small driver, a tune
for each part of the game, fades, and tempos finer than a tick. (This is read from the code;
Whittaker did not say it.)

UnExoticA's collection has 119 files:

- **115 of his**, from 89 games and versions of them. Among them are Shadow of the Beast, Xenon and
  Xenon 2, Speedball, Bubble Bobble, Golden Axe, Carrier Command, Licence to Kill, Days of Thunder,
  Total Recall, Tetris, Loopz and Alfred Chicken.
- **Three drivers of Ray Norrish's**, for sound effects alone, made in Whittaker's way and with no
  music in them. They are not played.
- **Rob Hubbard's Q-Ball**, his own small driver made in Whittaker's way, whose samples are each
  ended by Paula's own interrupts: four songs, the tune and three jingles. siday runs it on its
  Amiga with those interrupts, as Wanted Team's player sets them up. In UADE the second voice loses
  its first interrupt on many of its notes, by a race of a few clocks between the driver and Paula;
  siday's Amiga takes every one, and so does UADE once the driver's two writes are put the other way
  round.

### How siday plays it

UADE plays them with Wanted Team's player for EaglePlayer, which does not play the music itself. It
finds the driver's entry points by the instructions Whittaker used, counts its songs, mends a few
things in it, and calls it fifty times a second. siday does the same. What that player does to find
and mend a driver is done in Swift. The driver itself is run on an Amiga of siday's own (see below).

siday matches UADE tick for tick on all 551 songs of the 115 modules, and every song ends where
UADE's does.

Worth knowing, about siday's choices and the player's own ways:

- **Song end:** A song has ended when every voice has come round its list of patterns, or when the
  driver stops the music. Wanted Team's player puts hooks into the driver to know it. siday's does
  too, with the same few instructions in their place.
- **Dan Dare III:** Wanted Team's player refuses its driver, for want of room after its last sample.
  UADE plays it all the same, and so does siday, the same as UADE.
- **Level:** Whittaker's music is louder on Paula than other modules are, so siday turns it down to
  their level.

Of what Wanted Team's player mends, siday mends what is heard:

- **Drivers saved after they had already run:** their samples were made ready a second time.
- **A delay loop** in one driver, made to wait on the beam.
- **A voice** given a silent envelope to begin with.
- **The random choice of a song** in some, made a plain one.
- **The volume** of Chrono Quest's and Explora's, put back each tick.

What only feeds EaglePlayer's own displays is left out. So the driver's writes come a little earlier
in each tick than UADE's, which changes nothing that is played.

### The Amiga it runs on

The driver runs on siday's 68000, the one that plays the Atari ST's tunes, with chip memory. Around
it are the Amiga's custom chips, as far as sound needs them: Paula's registers, the DMA and
interrupt switches, and the beam's position, which drivers wait on. Both CIAs are there, with their
timers.

What the driver writes to Paula is heard at the moment in the tick it writes it, as on the Amiga. So
a voice stopped, waited on and started again is heard that way. The same Amiga runs the other
composers' drivers that come in their own files.

Its display's frames are long ones, of 313 lines, 49.92 a second, as on an Amiga that has started its
Kickstart: Kickstart sets the bit that makes them so as it starts, and nothing but an interlaced
display changes it after. UADE starts no Kickstart, and its frames are short ones, of 312 lines, 50.08
a second. So music a game ran from the frame plays about a third of a percent slower in siday than in
UADE, as it did on the Amiga. Where a game's own code shows that it ran its music from the frame,
siday's player runs it so too; where nothing shows how it was run, it is run as UADE's is, on
DeliTracker's timer, a hair under fifty times a second.

## MW — Martin Walker's own drivers

Martin Walker wrote the music of games such as Hunter, R-Type II, Dragon Breed, Atomic Robo-Kid,
AV8B Harrier Assault, Thunderhawk, Kingmaker, Reach for the Skies, Spindizzy Worlds, 9 Lives and
D/Generation ("(c) 1990-94 by Martin Walker", Wanted Team's player of his music says). As David
Whittaker did, he played it with a driver of his own that went into each game with its music. It was
a routine to start a song and one to play a tick, assembled with the data.

Each voice has a list of steps that names patterns, with steps that set a fade, stop the music or go
back. A pattern holds notes and instruments, with bits for slides and effects. An instrument says
its sample, vibrato, arpeggio and envelope. On each tick the driver writes to Paula, the Amiga's
sound chip, itself, and waits on the chip before it turns the voices on.

Some games have a driver of sound effects in front of it, which shares the voices with the music.
UnExoticA's collection has 22 files of it, 106 songs.

### How siday plays it

UADE plays them with Wanted Team's player for EaglePlayer, which knows five kinds of these drivers.
It finds their entry points, puts hooks into them to know when a song has ended, and calls them
fifty times a second. siday does what that player does to them in Swift. It runs the drivers
themselves on its own Amiga, as it runs David Whittaker's (see DW).

siday matches UADE tick for tick on all 106 songs, and every song ends where UADE's does.

Worth knowing, about siday's choices and the player's own ways:

- **Song end:** A song has gone round when all four voices have come back to the start of their
  steps, as the player's hooks tell it. A song whose driver stops the music, at a step that says so
  or at the end of a fade, has stopped. The player would start it again, which is not heard here.
- **Waits:** The waits the drivers make between turning a voice off and on are made the player's own
  wait on the beam, as the player makes them. The hooks it puts in only for EaglePlayer's displays
  are left out.
- **Level:** Martin Walker's music is louder on Paula than other modules are, so siday turns it down
  to their level.

## JD — Special FX's driver

Special FX was a team that made games for Ocean. Its music was played by a driver of its own ("(c)
1989-91 by Matthew Cannon & Jonathan Dunn", Wanted Team's player of it says). Wanted Team write that
it was used mostly by Jonathan Dunn, Matthew Cannon and Keith Tinman.

As with David Whittaker's, a `.jd` file is the driver itself, 68000 code with the music behind it,
as it went into a game. But it was assembled to run at one address in the game's memory. Each of its
four voices walks a list of patterns, with commands to go round, transpose and repeat. A pattern is
notes and their lengths and some sixteen commands: for the instrument, tables of arpeggio and pitch,
vibrato, slides, volume envelopes and rests.

It was the game's sound as well as its music. A sound effect takes a voice from the music by its
rank, and gives it back when it is done. UnExoticA's collection has 29 files of it, 359 songs. They
come from Batman, RoboCop 2, Midnight Resistance, Operation Thunderbolt, The New Zealand Story, Head
over Heels, Navy SEALs, Hudson Hawk, Rambo III, Elf, Battle Command, Wild Wheels and Striker.

### How siday plays it

UADE plays them with Wanted Team's player for EaglePlayer. That player moves the driver's addresses
to where it has been loaded, mends a few things, and puts hooks into it to know when a song has
ended. It calls the driver fifty times a second. siday does the same in Swift, and runs the driver
on its own Amiga (see DW), loaded where UADE loads it.

siday matches UADE tick for tick on all 355 songs that are heard, and every song ends where UADE's
does.

Worth knowing, about siday's choices and the player's own ways:

- **Song end:** A song has ended when every voice it uses has reached the end of its list, as the
  player's hook tells it. Three songs have no voices, and are empty.
- **Timing:** The player's hooks are written afresh as its own are, instruction for instruction, so
  that the driver takes the time it takes in UADE. Only the call that tells EaglePlayer a song has
  ended is made a word sent to siday.
- **Level:** Special FX's music is louder on Paula, the Amiga's sound chip, than other modules are,
  so siday turns it down to their level.

## MON — the Maniacs of Noise's drivers, Charles Deenen's and Jeroen Tel's

The Maniacs of Noise were the Dutch musicians Charles Deenen and Jeroen Tel, and those who worked
with them. They came to the Amiga from the Commodore 64, where a musician's driver was his
instrument. They played their music on the Amiga with drivers of their own, two generations of them,
kept as 38 files in UnExoticA's collection.

**The earlier driver** is Jeroen Tel's and Charles Deenen's, of 1989 and 1990 ("(c) 1989-90 by
Jeroen Tel & Charles Deenen", Wanted Team's player of it says). It was put together for each game at
the addresses it was to run at. Its files (`.jt`, and an older rip of most of them as `.mon`) are
that memory, taken out of the games: Stormlord, Tusker, Onslaught, Insects in Space and Unreal.

In the earlier driver, each voice has a list of patterns, with bytes that transpose, go round or
stop. A pattern is notes with their lengths, and bits for ties, rests, instruments and slides.

An instrument of the earlier driver has an envelope that rises, falls, holds and is let go; a
vibrato that waits before it starts; an arpeggio; and a sweep of its sound, made by moving where its
sample starts. The earlier driver's tick is in two halves. First the notes are worked out and the
chip given its samples. Then the periods and volumes are written and the voices turned on.

**The later driver** is Charles Deenen's (`.mon`, 21 files, from Battle Chess II, Dragon Wars,
Flimbo's Quest, Lord of the Rings, Mysterious Worlds, Rubicon and Unreal). It was written afresh to
run wherever it is loaded, with a table of entry points. Its commands go by tables of routines. Its
envelopes of volume and vibrato loop and hold, and its slides are worked out by division.

In the later driver, each song has its own speed, volume and filter. The game can fade it in and
out, and can have it pass over one tick in six, so that it keeps its tempo where the display runs at
60 Hz.

### How siday plays it

UADE plays the later driver with its own player of them, which calls the file's own driver. It plays
the earlier with Wanted Team's player, which runs a copy of its own of the driver of Unreal's title,
its addresses moved to where the file is. Both are run here on siday's Amiga (see DW).

For the earlier driver, siday runs each file's own driver, loaded back at the address it was put
together for. The few changes Wanted Team made to theirs are made to it too: it is the same code as
theirs, except for its addresses and a few instructions written another way. siday tells which of
the two drivers a file has by how it begins, whatever it is named.

siday matches UADE tick for tick on all 87 songs.

Worth knowing, about siday's choices and the players' own ways:

- **Later driver, song end:** A song has gone round when the places the four voices are at come back
  to where they have been, as the source of UADE's player tells it. A song that the driver stops
  after a fade has stopped. Its stop command leaves the last notes sounding, in UADE too, because it
  turns the voices off with the wrong byte; siday lets them ring.
- **Later driver, master volume:** UADE's player sets the driver's own master volume to the full 64
  before every song. siday does too, as the reference has it. So one song of Mysterious Worlds,
  which asks for 50, is the louder for it.
- **Earlier driver, song end:** A song has ended when a voice's list goes round, and has stopped
  where it says to stop, as Wanted Team's player tells it.
- **Level:** Both drivers' music is quieter on Paula, the Amiga's sound chip, than other modules
  are, so siday turns it up to their level.

## CORE and others — more composers' own drivers, by Wanted Team's recipe

Many of the Amiga's composers wrote their own drivers. What was ripped from the games is the driver
with its music: 68000 code that plays one game's tunes. Wanted Team made players for EaglePlayer of
many of them, and made most of them the same way:

1. Find the driver's routines, by a header they put before it or by searching its code.
2. Mend a few of its instructions, with patches they wrote in its place.
3. Call its routine to start a song, with the song's number.
4. Call its routine for a tick, fifty times a second.
5. Know that a song has ended by a hook among the patches.

### How siday plays them

siday does what each of their players does, in Swift, and runs the driver on its own Amiga (see DW),
loaded where UADE loads it. The formats here share one recipe for it. Each was compared with UADE
running Wanted Team's player, on every song of UnExoticA's collection; the list below says how each
came out.

Some rules are siday's own. A song of which nothing is heard, where the module's other songs are
heard, has nothing to it and is passed over. An empty song of a module is passed over in the same
way: the song a player counts past the end of a module's own list of them, or an effect that makes
no sound. A song that has been played through unheard for a minute is played no further to find its
end.

These come out louder on Paula, the Amiga's sound chip, than other modules are. siday turns each
down by its own amount to the level of the rest.

### The formats

- **Core Design** (`.core`): Benn Daglish's music for Core Design's games, of 1989 and 1990, as the
  player's credit has it: Action Fighter, Dynamite Dux, Monty Python's Flying Circus, Rick
  Dangerous, Axel's Magic Hammer and Saint & Greavsie. Six files, 145 songs, many of them sound
  effects. It is played by Paula's audio interrupts as well as its tick, and siday sets up its
  routine for them as the player does. Every song's writes are the same as UADE's in value, and 142
  in order too. Every song ends where UADE's does (123 of them never).
- **Janko Mrsic-Flogel** (`.jmf`): his music of 1986 to 1988, for Fire Blaster, Space Station,
  Protector, Bomb Jack, War Zone and Luxor. Six files, 16 songs, on three voices that play short
  waves of the driver's own. The same as UADE's in every song.
- **Benn Daglish SID** (`.bds`): the music of his that Wanted Team's player calls his "SID" music,
  of 1987 and 1988: Terramex, Chubby Gristle and The Flintstones. Three files, five songs, on three
  voices of short waves whose volumes its audio interrupt writes. Its wait for the sound chip counts
  the beam's lines, and siday's Amiga runs a little slower than UADE's. So now and then a volume is
  caught a step later. Every song ends where UADE's does. (His other music is under BD, and Core
  Design's above.)
- **Fred Gray** (`.gray`): his music of 1987 and 1988, for Star Goose, Victory Road, Eco and Black
  Lamp. Four files, 21 songs, the same as UADE's in every song. The same music is also among
  DeliTracker's custom modules (see CUST).
- **Howie Davies** (`.hd`): his music and Gary Antcliffe's, of 1990 and 1991, for Yogi's Great
  Escape, Blazing Thunder and Future Bike Simulator. Three files, 12 songs. They are the same as
  UADE's in every song, except for when a few ticks come. That comes from a wait of the driver's
  that counts the beam's lines from where the timer happened to start.
- **Sound Programming Language** (`.spl`): Holger Gehrmann's music of 1987 and 1988, by the name
  Wanted Team's player gives it, for Hollywood Poker, Clever & Smart, Graffiti Man and Boulder Dash.
  Four files, 12 songs, each module setting the speed of its own ticks. UADE's Paula carries on
  playing a voice that is turned off and on again before its sample runs out; siday's starts it
  afresh. So about a tenth of the times a note starts are not UADE's.

- **Beathoven Synthesizer** (`.bss`): Thomas Lopatic's ("(c) 1987-91"). It was used for The Great
  Giana Sisters, Katakis, Denaris, Zoom, Ganymed, Detonator, Final Mission, Phalanx II, Ringside,
  Street Gang, In 80 Days Around the World and the German game shows Glücksrad, Der Preis ist heiss,
  Riskant and Wetten dass. There are also Oliver Becker's Cosmic Bouncer and Rock Challenge. 21
  files, 37 songs, of its versions 1.00, 1.09 and "NEW". Each module is an AmigaDOS program whose
  header gives its routines, and may set its own speed, from 48 to 237 ticks a second. Every song
  matches UADE's tick for tick, and ends where UADE's does. Final Mission's module sets the frame's
  interrupt going for its music itself, and is played each frame, 49.92 times a second, where UADE
  plays it on DeliTracker's timer.
- **Sound Master** (`.sm`): Michiel Soede's Sound Master 1.0 to 3.0 ("(c) 1991-94"), used mostly by
  Jeroen Soede, Wanted Team write: Doofus and Future Shock, twelve files of a song each. The same as
  UADE's in every song. One, Doofus's third tune in the game, comes round again only after 13:44,
  and is that long in siday too: a song is played through for up to twenty minutes to find its
  length.
- **Darius Zendeh** (`.dz`): his own replayers, for R-Type, Katakis, Denaris and Crash and Burn,
  called with a command in a register. 15 files, 40 songs, every one the same as UADE's to the tick.
  Neither his player nor UADE ends the songs that go round, which is most of them. siday ends a song
  when the module itself marks its music as over, or, in Katakis's and Denaris's, when it comes back
  to where it started.
- **Mark II** (`.mii`): the Mark II Sound System, which grew from his editor (Andreas Scholl went on
  with it, and Cachet Software sold it). It holds Katakis's and Denaris's title and end music again,
  in four files, the same as UADE's to the tick. Its player ends a song where it goes round. As it
  does so, it clears the wrong word of the module's, so after the first time round one voice is
  silent. UADE plays it so, and so does siday.
- **Steve Barrett** (`.sb`): his music of 1988 to 1990, and Wally Beben's for Street Fighter:
  Advanced Ski Simulator (at a hundred ticks a second, as the player has it), Artificial Dreams,
  Chronicles of Omega, Dragon Scape and Kelly X. Six files, 16 songs, the same as UADE's in every
  song. Street Fighter's first song differs a little, as its voices are turned off and on again (see
  SPL).
- **Rob Hubbard** (`.rh`): his music of 1989 to 1991, for Populous, Budokan, PGA Tour Golf and The
  Bard's Tale III. Five files, 18 songs, the same as UADE's to the tick.
- **Rob Hubbard ST** (`.rho`): his music of 1987 and 1988 on Steve Bak's replayer from the Atari ST,
  made for the Amiga: Gold Runner, Jupiter Probe and Battleships. Three files, on three voices of
  short waves. The same as UADE's, except for one silent voice of Jupiter Probe's, which is started
  a tick early.
- **Fred Monitor** (`.fred`): Frederic Hahn's, as UADE's own player of it names it: Fuzzball and
  Ilyad, four files, 24 songs, the same as UADE's in every song. UADE never ends them (its player's
  test for an end fails on these files, it says). siday ends a song once every voice has come to
  where its list jumps back, or when the module stops itself.

- **Desire** (`.dsr`): Dentons' music of 1993 and 1994, as the player's credit has it, for Power
  Drive and Batman Returns. Three files, 26 songs, the same as UADE's in every song. Most of the
  songs go round, and the player ends only those that stop; siday also ends a song once every voice
  has come round, its longest loop played through once. One song of Batman Returns goes round a part
  of it twenty times, as its code says, so it is over eight minutes long. The last song of each of
  Power Drive's is past the end of the list of them, and is silent, in UADE too.
- **SCUMM** (`.scumm`): the music and sounds of Lucasfilm's Maniac Mansion (Chris Grigg's) and Zak
  McKracken (Matthew Kane's). Each file is one sound's own 68000 code, as Andy Silva's player for
  EaglePlayer calls it. Ten files, the same as UADE's. A sound says when it is done, which the
  player does not heed; siday ends the song there. Three loop for ever, in UADE too.
- **Sean Connolly** (`.scn`): his music for Surf Ninjas, of 1993, and his replayer, which its own
  text calls his "EMS". One file, seven songs, the same as UADE's, each ending where UADE's does.
  The player holds three versions of his replayer. Only the one this file has is played; the other
  two are refused, with no file to check them by.

- **Sound Images** (`.tw`): Tony "Tiny" Williams's music of 1988 to 1993, as the player's credit has
  it. It is the music for Shinobi, Viz, Narc, Smash TV, Judge Dredd, Nitro, Teenage Mutant Hero
  Turtles, Super Monaco GP, International Ice Hockey, Future Basketball, MoonFall, Never Mind,
  Sharkey's Moll, Chuckie Egg II and Blinky's Scary School. 30 files, 133 songs, each with a handler
  of its own for Paula's interrupts that gives a voice its next sample. Every period and volume is
  the same as UADE's, and every song ends where UADE's does. Which notes' first samples the handler
  catches differs now and then, on both Amigas.
- **Wally Beben** (`.wb`): his music of 1988 to 1990 ("Wally 'Hagar' Beben"), on his Ariston
  replayer. It is the music for Elite, Hammerfist, Superman, Colossus Chess X, Dark Side, Total
  Eclipse, Pool of Radiance, Hyperdome, Lancaster, Circus Games, Time Machine and others. Richard
  Joseph's Wicked is on the same replayer too. 21 files, 82 songs. The code is saved where it ran in
  the game, and is moved to where UADE loads it, as the player moves it. The same as UADE's in every
  song.
- **Mike Davies** (`.md`): his music of 1989 to 1994. The games are Strider and Strider II, Mercs,
  Alien Storm, Die Hard 2, Indiana Jones and the Last Crusade, Dynasty Wars and Italy 1990 (which is
  the same file as World Class Soccer). Nine files, 50 songs, moved as Wally Beben's are, and the
  same as UADE's to the tick.
- **Jason C. Brooke** (`.jcb`): his music of 1987 to 1990: Out Run, Space Harrier, Thunder Blade,
  After Burner, 1943, Side Arms, Ikari Warriors, Pac-Land, Vixen, Heavy Metal, Harley-Davidson,
  Rockford, Feud, World Darts and others. 20 files, 85 songs, the same as UADE's except for
  Pac-Land's. Its code reads its envelopes through a register it never sets. UADE's host leaves that
  register such that every envelope is silent, and siday's such that they are heard.
- **Ashley Hogg** (`.ash`): his and Jonathan Menzies' music of 1991 to 1993: Nobby the Aardvark,
  Spike in Transylvania and CJ in the USA; and the two of 1993, Cosmic Spacehead and Fantastic
  Dizzy, whose samples are in a file beside them (`title.smp`). Five files, 69 songs, the same as
  UADE's. A song of 1993 that jumps back to repeat ends there, which is siday's own rule.
- **Mark Cooksey** (`.mc`, and `.mcr` with `.mcs`): his music on Richard Frankish's player, of 1988
  to 1990: Commando, Ghosts'n Goblins, Paperboy, Gremlins 2, Mighty Bomb Jack, Grand National and
  World Championship Soccer. Then there is the earlier kind: an Atari ST program with its song data
  in a second file beside it (`title.mcs` for `title.mcr`). Its games are Live and Let Die (also
  Aquablast), Overlander, A Question of Sport and Mike Read's Pop Quiz. 13 files, 74 songs, the same
  as UADE's, with the player's mends of the replayer (Commando "sounds better", its notes say).
- **Kris Hatlelid** (`.kh`): his music of 1989 to 1991. The games are The Cycles, Grand Prix
  Circuit, Test Drive II, Hardball II, Wings of Fury, Super C and Teenage Mutant Ninja Turtles. His
  replayer also plays Igor Shimsky's music for Fiendish Freddy's Big Top o' Fun. 13 files, 71 songs.
  Most are music alone, played by his replayer in a file beside them named `songplay`. Each song
  sets its own speed. 62 songs are the same as UADE's to the tick. In nine, his handler for Paula's
  interrupts runs on a few ticks in one Amiga and not the other. (The custom modules of Grand Prix
  Circuit are the same music; see CUST.)
- **Sean Conran** (`.scr`): his music of 1989 to 1991. The games are Count Duckula, Defenders of the
  Earth, Yogi Bear, Hong Kong Phooey, Top Cat, Ruff and Reddy, Wacky Races, Mega Twins, Infestation,
  Videokid and WWF Wrestlemania. 14 files, 38 songs, the same as UADE's. Each note is begun on the
  longest of periods, and given its own a moment later. UADE's Paula takes up a period only as a
  note's first sample plays, and so never counts the long one; siday's now does the same. Two sound
  effects of Defenders of the Earth play samples that are not in the file, and are silent.
- **Jesper Olsen** (`.jo`): his music of 1990 to 1995 for Guldkorn Expressen (the same as Kalas
  Puffs Expressen), Georg Glaxo and Lollypop. The last two's are music and samples alone. The game's
  own driver beside them plays them; Wanted Team kept it as `WantedTeam.bin`. 29 files, 74 songs and
  Lollypop's 30 sound effects, the same as UADE's in every one. Where a song leaves voices to the
  game's sound effects, which never come, it ends when the voices that are heard have come round.
- **Dynamic Synthesizer** (`.dns`): Chris Hülsbeck's, of 1987 and 1988, for Hollywood Poker Pro,
  with its samples beside it (`title.smp`). Two files, 13 songs. The code is moved from where it was
  assembled to run, as the player moves it, and is the same as UADE's. The game played it from a
  copper interrupt at the end of each frame, as its in-game module sets going itself, and siday plays
  both files each frame, 49.92 times a second, a little slower than UADE.

## CUST — DeliTracker's custom modules

DeliTracker, Frank Riffel's and Peter Kunath's player of the Amiga's music, took its players of each
format from files of their own. It also took one kind of file that is its own player: a custom
module. That is an Amiga program that holds a game's music and its replay code together. A list of
tags at its start tells DeliTracker what to call to start a song and to play it.

Its code calls DeliTracker back for what it needs: to have the sound chip, to set the timer it is
played by, and to say a song has ended. It is the way a game's music is kept when its player was the
game's own and fits no format. UnExoticA's collection has 369 of them: Defender of the Crown, The
King of Chicago, Lemmings, The Bard's Tale, Speedball 2, Battle Squadron, Paradroid 90, Cadaver,
Loom, Indiana Jones and the Last Crusade, Starglider, and some three hundred more.

### How siday plays it

UADE plays them by running them as DeliTracker did, in an Amiga of its own. Its host for the players
(`score`) answers what they call for, as DeliTracker would. siday does the same. Its Amiga (see DW)
has been given the rest of what the hardware does for them: interrupts taken as they come due from
the display, the timers and Paula, the Amiga's sound chip.

siday's host does what UADE's does. It answers DeliTracker's calls, and the few calls to the Amiga's
own system that the modules make: memory, the timers and the sound chip's device, and loading a
file. It starts the module's tick from the timer the module asks for.

Of the 2,539 songs of the 416 modules played on that host (these, and Dave Lowe's own; see DLN),
2,381 match UADE tick for tick. Most of the others are the same, except where the processor and the
chip race to a moment, which UADE's processor and siday's reach a little differently.

Immortal and Zany Golf part from UADE early on. siday plays them as a 68000 plays them: their code
depends on a borrow from a subtraction, which UADE's processor, as it is built, does not keep.

Fifteen of Electronic Arts' modules ask for more than that: Archon and Archon II, Arcticfox, Seven
Cities of Gold, One-On-One, Skyfox, Marble Madness's six, M1 Tank Platoon's two and World Tour Golf.
Their music runs as tasks of its own, with messages between them, timed by the system's timer, and
it plays every note through the system's audio device instead of setting the sound chip itself.
UADE plays none of them. siday gives them a small system of its own: the tasks, their signals and
messages, memory given back when freed, the timer's frames, and an audio device that sets Paula as
Kickstart 1.3's does, in the same order and at about the same moments. That is the Kickstart these
games were sold for. They were checked against Copperline, an emulator of the whole Amiga, running
each module on Kickstart 1.3 itself. Their 48 songs have the same notes there, most of them on the
same tick, and the rest a tick to one side, where the Amiga's own system took longer over them.

Worth knowing, about siday's choices and the host's own ways:

- **Song ends:** Most customs never say when a song has ended. siday plays each song through unheard
  for up to ten minutes to see. But take a module whose code cannot call to say so: once one of its
  songs has been played that long without ending, the module is taken to have no songs that end. So
  one of seventy songs loads in a moment and not in minutes. A song with no end plays for the time
  given to such tunes.
- **Silent songs:** A song of which nothing is heard, where the module's other songs are heard, has
  nothing to it and is passed over. After a minute unheard it is played no further. A module none of
  whose songs is heard is left as it is.
- **Level:** These modules' music is louder on Paula than other modules are, so siday turns it down
  to their level.

### Differences and limits

- **Not played:** Grand Prix Circuit's three custom modules give DeliTracker nothing to call to play
  them. They are not played. (The game's music plays as Kris Hatlelid's; see CORE.)
- **Silence:** A few more play silence, or begin with a silent song, as they do in UADE. One of
  those, Lemmings' older custom, wants files from beside it (see the next item).
- **Files beside them:** Two modules load more of their music from files beside them, as their games
  did: Nebulus 2's loading music, and Lemmings' older custom. They say which files were not given.

## RJP — Richard Joseph's player

Richard Joseph's music for the Amiga's games was played with a replayer of his own and Andi
Smithers'. Its version is 1.7A, and Wanted Team's player of it says "(c) 1992-93 by Richard Joseph &
Andi Smithers". A module, `title.rjp`, begins "RJP1SMOD". It holds the songs, their sequences and
patterns, and the instruments and their envelopes. The sounds themselves are in a file of their own
beside it, `title.smp`, as the games loaded them.

UnExoticA's collection has 109 modules. They come from Cannon Fodder and its sequel, The Chaos
Engine and its sequel, Sensible World of Soccer and Sensible Golf, James Pond 2 and 3, Flight of the
Amazon Queen, Rome AD 92, Brutal Football, Diggers, Mr Blobby and others. There is also Jason Page's
Ruff 'n' Tumble, made with the same player. A module holds as many songs as a game wanted from it,
917 in all: tunes, jingles and sound effects together.

### How siday plays it

siday's player is Wanted Team's player for EaglePlayer, which UADE carries, read in its 68000 code.
It has the two fixes Wanted Team made to two modules as they load: Crazy Football's title and Cannon
Fodder 2's KILLER. siday matches UADE tick for tick on all 917 songs.

Worth knowing, about siday's choices and the player's own ways:

- **Timing:** The player runs fifty times a second, on the timer UADE runs it on. As the player
  does, a note's sound is turned on a tick after the note, and its loop given to the chip a tick
  after that.
- **Song end:** A song has come to its end when every voice it uses has gone past its sequence's
  end, as the player tells it. If a voice is left playing a loop at some volume, it goes on
  sounding, as on the Amiga, and the song is faded as one that goes on is. If nothing is left
  sounding, it stops.
- **First song:** When none is asked for, the first song played is the first that lasts a second or
  more. Many modules begin with empty songs, or with a moment's sound effect.
- **Samples:** siday looks for them as `title.smp` beside the module, then `set.smp` (James Pond 2's
  for the Amiga 1200 share one), then the one file ending `.smp` beside it. A module without them is
  not played.
- **Level:** Richard Joseph's music is quieter on Paula, the Amiga's sound chip, than other modules
  are, so siday turns it up to their level.

## DLN — Dave Lowe's later music

Dave Lowe, of Uncle Art, kept his earlier music for the Amiga as Amiga programs (`.dl`: his own code
with its music, 47 files in the collection). Wanted Team's player of them ("Dave Lowe") loads and
calls them, mending the code that writes a voice's volume.

His later music, of King's Quest VI, Beneath a Steel Sky's CD32 version and Super Street Fighter II,
is kept as its songs alone. These are `.dln` files, 41 in UnExoticA's collection, holding 128 songs
with their samples.

The later music is played by Wanted Team's player of it for EaglePlayer ("Dave Lowe New", which UADE
carries; "(c) 1993-95 Dave Lowe from Uncle Art", it says). That player holds the two players those
songs were made for, told apart by how a file begins. In the second, Super Street Fighter II's, each
song gives a tempo: after so many ticks, one is passed over.

### How siday plays it

siday's player is Wanted Team's, read in its 68000 code, with the fix they made to the data of one
of Beneath a Steel Sky's songs as it loads. siday matches UADE tick for tick on all 108 songs that
make a sound, and on the other twenty, which are silent.

Worth knowing, about siday's choices and the player's own ways:

- **Timing:** The player runs fifty times a second, on the timer UADE runs it on.
- **Song end:** A song has come to its end when the player's own test says so. A voice that takes a
  jump it has taken before is taken to have come round (King's Quest VI's has a drum that goes round
  for ever). A voice held on a note or a rest of 32,768 ticks or more (eleven minutes) has come to
  rest. A song whose voices have all come to rest has stopped, as the jingles and the silent songs
  do.
- **Long rests:** Some songs end with a long rest before they go round again, in four of King's
  Quest VI's of 160 seconds. It is played as it is written.
- **Level:** Dave Lowe's music is louder on Paula, the Amiga's sound chip, than other modules are,
  so siday turns it down to their level.

### The earlier programs

siday runs the earlier programs on its Amiga, under its host for DeliTracker's players (see CUST).
They are loaded and called as Wanted Team's player does. Of the 45 that are his, all but two match
UADE in every song. Those two, Frontier's and Midwinter II's, differ only in writes of a value the
chip already has, which change nothing heard.

Two others are older rips of the same music, Frontier's and Formula One Grand Prix's, of another
kind: the songs alone, for DARKNESS of Synergy's DeliTracker player of them ("Dave Lowe's Sound
System", 1997). That player holds Dave Lowe's own replay routine, of the same make as his later
music's, and siday plays them as it does, read in its 68000 code. They match UADE tick for tick in all
ten songs. They are the same music, note for note, as the later rips beside them, in another order.
Only Frontier's intro differs, fading in where the later rip waits six seconds, and so does the last
chord of Blue Danube, a second and a half shorter. His earlier music is louder than other modules
are, and siday turns it down to their level.

## XM — FastTracker 2

FastTracker 2 came out in 1994, written by Fredrik Huss and Magnus Högdahl of the group Triton. For
some years it was the tracker most PC music was made in. Its XM file took the module past the
Amiga's limits: up to 32 channels, samples of sixteen bits, and instruments that are more than a
sample. An instrument can have several samples across the keyboard, and envelopes for volume and for
panning.

### How siday plays it

siday plays an XM file as FastTracker 2 played it, and so too a MOD file with more channels than the
Amiga has. The replayer and the mixer are FastTracker 2.09's, by way of ft2play's port of them to C.
The mixer works in integers. It has FastTracker's interpolation between one sample point and the
next, and its volume ramping, both switched on as they were when the tracker was new. Each
instrument is panned where the module says.

FastTracker itself reads no more than 32 channels, and only an even number. Files from later
trackers have any number, and are played the same way.

FastTracker lets any letter be typed for a command. In a file of its own, a letter it has no command
for does nothing, as it did to FastTracker; it is often a mark for a demo to keep time by.

One of FastTracker's ways was its own and not the other trackers': its arpeggio counts a row's ticks
down. So at most speeds it plays the two notes after the first the other way round. It also goes up
from the note nearest to where a slide has taken the pitch.

A tune ends where it would play a row it has played before.

### Files from later trackers

Some things are done as those later trackers did them. A sample can be in stereo in a file of
theirs, its two sides one after the other. To FastTracker that is one long sample. siday plays the
two sides
together, the left side on the left and the right on the right, each as loud as the channel's pan
position makes that side, as OpenMPT plays them.

Such a file's own pre-amp, which ModPlug Tracker and OpenMPT keep at its end, makes it louder or
quieter, as it does in OpenMPT. It counts against the usual pre-amp of the file's mix levels, the
way it asks for its channels to be added up. The mix levels themselves turn a whole tracker's files
down together (see IT, below), and siday does not follow them. So the median file of each tracker is
as loud as the median file of FastTracker's own.

These files also have commands of ModPlug Tracker's, which siday plays as OpenMPT plays them:

- **Panbrello:** Y sweeps a channel from side to side, with X5 to choose its wave.
- **Filter:** Z and the command after it send a macro. That is how such a file sets a channel's
  filter, at once or a little at a time over a row. The filter is OpenMPT's two-pole filter, put
  into FastTracker's mixer between a sample and its volume. A macro for anything but the filter is
  left out, and siday says so.
- **Plug-ins:** Such a file is heard through its plug-ins, where they are OpenMPT's own, as an IT
  file of the same trackers is. A voice goes to its instrument's plug-in, or else its channel's, in
  FastTracker's integers. The plug-ins are given it as loud as OpenMPT gives it, in each of
  OpenMPT's mix levels. What comes back is limited where OpenMPT's integers end. So a plug-in that
  squashes or bends its sound, such as OpenMPT's distortion, comes out as loud beside the plain
  sound as libopenmpt has it, in each of the six mix levels.
- **Reverb:** X99 puts a channel in ModPlug's own reverb, and X98 takes it out, as in an IT file of
  theirs (see MPTM, below).

A sample that runs out while it is loud stops dead in FastTracker's mixer, which is heard as a
click. In ModPlug Tracker's and OpenMPT's, what it last put out dies away instead, by a 256th of
itself a frame, and so it does here in a file of theirs. It is a small thing, a few thousandths of a
second at each such end.

Such a file's voices are interpolated as OpenMPT interpolates them, where FastTracker draws a
straight line from one point to the next. siday uses the interpolation an instrument asks for, as in
an IT file of theirs (see IT, below), or else OpenMPT's own eight-point sinc. The straight line lets
through images of the sound above it (aliasing), which a sample played below its own rate makes a
lot of.

So these files were brighter than their composers heard them. A voice still goes through its sample
at exactly FastTracker's rate; only what is heard between the points is OpenMPT's.

That is for a file that gives itself away as another tracker's. It may say so. Or, where it says
FastTracker, as ModPlug Tracker's files do, siday knows it by a name padded with zero bytes instead
of spaces, or by what ModPlug Tracker writes after all that FastTracker reads.

MadTracker 2, Skale Tracker and ModPlug Tracker up to 1.16 counted the arpeggio up, from the note
the channel was given. So did OpenMPT in a file that it saved not to be played as FastTracker plays
it, and so did its versions before the first that had FastTracker's arpeggio. OpenMPT plays their
files so, and siday does too. OpenMPT has other ways for an XM file, and siday plays such trackers'
files without them; none was heard to change more than a handful of tunes.

ModPlug Tracker also added commands of its own under X. OpenMPT plays them in ModPlug Tracker's
files, and in OpenMPT's own files that were not saved to keep strictly to FastTracker's. So does
siday:

- **X9F** plays a sample backwards, round its loop if it has one and to its start if not. **X9E**
  plays it forwards again.
- **X91** puts a channel in surround: in the middle, with its right side inverted (not in mono,
  where that would leave nothing). It stays there until X90, or until the channel is panned
  somewhere, as OpenMPT has it. That is unless X9B has asked for channels in surround to be placed
  as on four speakers, which X9A takes back.
- **X6x** makes a row longer by so many ticks.
- **XAx** starts a note, and 9xx after it, so many times 64K into a long sample.
- **X5x** and **X98/X99**, as before.

The commands for notes left playing and for envelopes (X7x) are not played, and such a file says so.

FastTracker drops the lowest three bits of a sample's finetune, so its notes are as much as six
cents flat of what the file says. ModPlug Tracker did not. Nor does OpenMPT, in files from its
earlier versions or in later ones that ask for it. Nor does siday, in their files.

## MTM, DTM and AMF — MultiTracker, Digital Tracker and DSMI

Three kinds of module:

- **MTM:** MultiTracker was a tracker for the PC and the Gravis Ultrasound.
- **DTM:** Digital Tracker was one for the Atari Falcon.
- **AMF** is what DSMI, the engine of the Dual Module Player and of many games, made of any module
  before it played it.

### How siday plays it

An MTM, a DTM or an AMF file is not played as its own tracker played it, because siday has no
replayer of any of them. But all three are ProTracker's kind of module with more channels.
FastTracker 2 plays that already, for a MOD file of eight channels. So each has a loader that reads
it into the shape FastTracker holds a module in, and FastTracker's replayer and mixer play it.
FastTracker's slides, vibrato, arpeggio and panning are near to these trackers' own, but they are
not theirs.

The replayer does five things for such a file that it does for no XM or MOD file:

- **Channel panning.** A channel has a pan position, and stays where a command puts it. FastTracker
  gives a pan position to each sample instead.
- **Sample rates.** A sample plays at the rate it says it was recorded at, whatever the note and
  whatever slides it.
- **Speed and tempo in MTM files.** Setting the speed puts the tempo back to 125, and setting the
  tempo puts the speed back to 6. That was MultiTracker's way and no other player's. A file that
  sets both on one row was written for those other players, and is played their way.
- **Pattern loops.** A loop inside a pattern does not leave the next pattern starting part of the
  way down. That is a mistake of FastTracker's that its own files were written around, and these
  files were not.
- **Vibrato in DTM files** is a quarter as deep as the same number makes it in a MOD file. That is
  how OpenMPT plays these files, and not how libxmp does. It was settled by ear, on a tune whose
  composer had written the shallowest vibrato there is and still got a note that wavered out of
  tune.

Slides in a DTM file were heard both ways as well, and are left as they were: on every tick of a row
but the first. OpenMPT slides on the first tick too. A tune whose sweeps go up a fifth stays in key
this way, and went out of key that way.

A stereo sample in a DTM file is played in stereo, as in an XM file of a later tracker's. The pitch
of a note is FastTracker's, from the Amiga's table of periods. Each kind is as loud as XM files are.

### Differences and limits

What FastTracker cannot be told is left out:

- Digital Tracker 2.04 set how loud a channel was on each side. The pan position is kept, and the
  loudness is not.
- DSMI's surround sound is played in the middle.

Compared with libxmp and OpenMPT over a minute of every tune, none plays a wrong note, a wrong
sample or at a wrong speed.

## S3M — Scream Tracker 3

Scream Tracker 3 is Sami Tammilehto's, Psi of Future Crew. It came out in 1994, after the group had
used it for the music of its own demos. It was the first tracker many PC musicians had with more
than four channels and a card that could do them justice. It had sixteen channels of samples and,
beside them, for those who wanted it, the nine FM voices of the AdLib card.

### How siday plays it

An S3M file is played as Scream Tracker 3 played it, and that depended on the sound card:

- **Gravis Ultrasound (GUS):** the card did the mixing. The tracker told it, a tick at a time, what
  each voice was to play. The card played them smoothly, each at its own pan position, sliding from
  one volume to the next.
- **Sound Blaster Pro:** the tracker mixed for itself, into eight bits, with no smoothing. It mixed
  at 22 kHz in stereo, with eight channels hard to each side.

Both are here, by way of st3play's port of the tracker and its emulation of the cards. A file that
Scream Tracker saved says which card it was saved with, and is played on that one. Any other file is
played on the GUS.

One slip of st3play's, which Scream Tracker did not make, is not repeated: st3play loses the sign of
a number on very high notes, and plays them wrong.

### Files from later trackers

Scream Tracker's samples were eight bits and no longer than 64,000 bytes. Files from later trackers
have more:

- **Sixteen-bit and longer samples** are played as they stand.
- **Samples tuned higher than Scream Tracker had room to write down** are played at the pitch they
  say. They are not held to the highest pitch Scream Tracker could have given them.
- **Stereo samples** keep the right side after the left, and Scream Tracker would play the left
  alone. Here the two sides are played together. On a GUS, in a file that is in stereo, the left
  side is on the left and the right on the right, as the card's voices each have their own pan
  position. On a Sound Blaster, whose channels are each to one side, or in a file in mono, the two
  are mixed into one.

Such files also have three commands that Scream Tracker passes over and the trackers after it play,
in an S3M file as in any:

- **M** sets a channel's volume.
- **N** slides it.
- **W** slides the volume of the whole tune.

In a file that Scream Tracker did not save, those are played as OpenMPT plays them. In one that it
did save they do nothing, as they did to it and to whoever made the tune there.

A file that Scream Tracker did not save keeps time as its own tracker did, too. Scream Tracker's
timer on a GUS went by whole ticks a second. So a tempo of 128 (51.2 ticks a second) was played as
127.5 (51). The trackers after it went by the tempo itself, and a tune of 4 minutes at such a tempo
had drifted a second by its end. Such a file's T is Impulse Tracker's: below 20 hex it slides the
tempo, and T00 repeats the channel's last. Scream Tracker had neither.

On the GUS, whose voices each have their own pan position, three more commands of the later trackers
are played in such a file:

- **X** puts a channel at a pan position.
- **P** slides it.
- **Y** sweeps it from side to side.

The card has sixteen pan positions, and the channel is put at the nearest of them. The card's sides
are less far apart than OpenMPT's.

### The Z filter

In ModPlug Tracker and the trackers after it, Z sets a channel's filter. siday plays it as OpenMPT
plays it in an S3M file. An S3M file has no macros of its own, so Z goes by those ModPlug Tracker
began with: below 80 hex it sets the cutoff, and from there to 8F the resonance. The filter is
OpenMPT's, of two poles, on either card. On a channel of the AdLib card, the cutoff is, in OpenMPT,
how strongly the first operator bends the second, and so it is here.

OpenMPT keeps the command only for a file of a tracker that had it, by the mark each tracker leaves
in what it saves. In these trackers' files Z does nothing, as it did to them, and so it is here:

- Scream Tracker;
- Impulse Tracker before 2.14;
- those others that say they are Scream Tracker 3.20 and had no filter (Sound Club, PlayerPRO,
  Velvet Studio).

One old file, Crawling Despair, uses Z for something else again. Its text says it is for PixPlay, a
player that took Z00 to Z0F as pan positions. OpenMPT plays it so, finding a file from before Scream
Tracker 3.20 whose Z is only ever that. So does siday.

### Reverb

S99 puts a channel into ModPlug's own reverb (see MPTM). How it is played depends on the
card:

- **On the GUS,** each voice is made alone. So the voices of such a channel can be sent to the
  reverb and not to the card's own output, as OpenMPT sends them. The two are then brought to the
  player's rate together.
- **A Sound Blaster** adds its channels into eight bits as it goes. There a channel in the reverb is
  kept out of that sum. What it would have added is sent to the reverb instead, as loud as the card
  would have made it but whole.

In a file that Scream Tracker saved, S99 does nothing, as it did to it.

### More than sixteen channels

A later tracker can save channels of samples after the sixteenth with the numbers Scream Tracker
gives the AdLib card's voices. Scream Tracker plays no sample on those. OpenMPT takes such a number
only for the channel's pan position, and plays what is on it.

So in a file that Scream Tracker did not save, a channel numbered so that plays samples, and nothing
of the AdLib's, is a channel of samples here. There can be up to sixteen more, on the GUS.

The card is given a voice for each, which no GUS had, and goes on at the rate it has for the voices
the file asks for. A Sound Blaster mixes sixteen and no more; there, such a file says the rest are
not heard. In a file that Scream Tracker saved, those channels were not heard by whoever made it
either, and are not here.

### The AdLib card

Nine of Scream Tracker's channels were not samples at all but voices of an AdLib card, the FM
synthesiser most PCs had before they had anything better. There are S3M files that use them, most of
those with no samples at all.

Scream Tracker's driver for the card is ported with the rest of it. The card's chip is an emulation
of the Yamaha OPL3, a port of Nuked OPL3, which was worked out from the chip's own ROMs and
circuits. The OPL3 is the chip of the later Sound Blasters, and plays what was written for the
AdLib's own OPL2 as that did. It is here whole, with its drums, its four-operator voices and its
second set of registers, none of which Scream Tracker used.

Register writes reach the chip no faster than a PC could make them, two samples apart. So a note let
go and struck again in one tick is heard to be. The samples of a tune with FM in it are as loud as
in any other tune. st3play turns them down by a third at the card's first note, to leave room for
it.

### Settings

- `--s3m-card` asks for either card, the GUS or the Sound Blaster.

## STM and STX — Scream Tracker 2, and its Music Interface Kit

An STM file is from Scream Tracker 2, the same author's tracker of 1990. No sound card did any
mixing then. The tracker had four channels and 31 samples of eight bits. The program added the four
together itself, a sample at a time, for a Sound Blaster or a converter on the printer port.

### How siday plays it

An STM file is played by a port of st2play. Sergei Kolzun made st2play from the program itself, and
calls it very accurate. st2play is the whole of how Scream Tracker 2 made sound, since its replayer
and its mixing are one loop.

The four channels are added into eight bits, with no interpolation. A channel at its loudest has six
of those bits, and there is one channel of output. That is how an STM file sounded: rougher than
anything else here, and the same in both ears.

The tune is made at 23,863 samples a second, the highest rate Scream Tracker 2 could be set to mix
at. Then it is brought to the player's rate, as an S3M file's Sound Blaster is. The rate is part of
the tune, a little: a tick is a whole number of those samples.

### Three versions

st2play has the replayers of three versions of the program, 2.21, 2.24 and 2.3, and they are not
alike. Compared with 2.21, version 2.3:

- plays a fifth of a semitone higher and a fiftieth faster;
- has a vibrato half as deep;
- goes on with the last vibrato or the last slide to a note when it is given one with no value;
- plays an arpeggio of three notes, where 2.24's plays two and 2.21 has none.

A file does not say which of them it was made with. Every one says 2.21, which is the version of the
file's layout. It is 2.3 that is ported, the last, because that is what the files in the collection
ask for. A tune made with an earlier version is played by 2.3 all the same, as it was in its day by
anybody who had 2.3.

### Scream Tracker 2's own ways

Much of what Scream Tracker 2 does is its own, and is kept:

- A slide's value counts in tens of the units other trackers use.
- A slide to a note that is let go before it gets there is there at once.
- A place in the order list that a row asks for is gone to when the pattern ends, and not before.
- A tempo has two halves: the ticks to a row, and a number that makes each tick longer by an amount
  that depends on the first.
- A volume over 64, which a row can ask for, is silence.
- An arpeggio on a B reads past the end of the table of notes, and plays what it finds there.
  st2play's author wrote that down from the program's memory.

### Differences and limits

The port agrees with st2play to the sample on 62 of the 63 STM files in the collection. Three things
are done here that st2play does not do, each for what a file means:

- **Missing empty patterns.** Scream Tracker 2 seems not to have saved the empty patterns after a
  tune's last, since some files have such a pattern in their lists. Here it is played as a pattern
  with nothing in it, so that the notes before it ring on. st2play plays whatever its memory holds,
  and OpenMPT passes the place over.
- **The end of the list.** A number in the list that is neither a pattern's nor a mark of the end is
  taken for the end. Nothing after the first end of a list is played.
- **Loops past the end.** A sample that is to go round from past its own end goes on into what
  follows it in the file, the next sample. That is what OpenMPT's authors found Scream Tracker 2 to
  do. st2play brings the end in.

A sample with no volume of its own is not loaded, as in st2play, and its notes are silence. One file
named for the format is something else, and is refused. The files are as loud as XM files are.

### STX files

An STX file is a Scream Tracker 2 tune made ready for the Scream Tracker Music Interface Kit. Future
Crew gave out that library in the early 1990s, for putting their tracker's music into other people's
programs. The kit's papers call STX a beta of Scream Tracker 3's format, and it looks like one. It
has an S3M file's header and samples, and its way of packing a pattern a row at a time, with only
the channels that have something in them.

What is packed is an STM file's, though: four channels, Scream Tracker 2's commands under its
letters, nothing remembered from one command to the next, and a tempo in two halves. The kit came
with a converter, STM2STX, and its music was written in Scream Tracker 2. The kit's own replayer has
never been published.

OpenMPT and Schism Tracker play these files as the STM files they were, and so they are played here.
Each is read back into an STM file, and played by Scream Tracker 2's replayer like any other. libxmp
plays them with Scream Tracker 3's ways instead, under which a command with no value goes on with
the last one's, and the tempo has one half.

An STX file has room for what an STM file has not: more channels, more samples, longer ones and ones
of sixteen bits. The converter made none of those, and a file that has them and uses them says so. A
volume over 64, which Scream Tracker 2 would play as silence, is taken for 64, as OpenMPT takes it.

## DSM — the Digital Sound Interface Kit

The Digital Sound Interface Kit, DSIK, is Carlos Hasan's library for playing music and sound in
programs for DOS. It came with a converter, which made the modules of other trackers, S3M files
among them, into the one kind of file its player played. That is a DSM file, a RIFF file of the kind
"DSMF". It is made of chunks:

- **The song:** a name, how many of each thing there are, the speed and tempo, up to sixteen
  channels each with a pan position, and the list of patterns.
- **Each pattern,** in a chunk of its own: 64 rows, packed much as an S3M file packs them.
- **Each sample,** in a chunk of its own: of eight bits or sixteen, with a sign or without one, or
  kept as the differences from each byte to the one before. It has a rate of its own and a loop.

The commands are ProTracker's, under a MOD file's numbers. 8xx is a pan position from 00 to 80, and
A4 is surround. Another kind of file called DSM, Dynamic Studio's, which begins "DSm", is not read.

### How siday plays it

DSIK's player is not to be had. OpenMPT plays these files by the rules it plays an S3M file by. Fine
and extra-fine slides are within the commands, and one value is remembered for most of them
together. A slide to a note that names another sample goes on with the one that is sounding, and so
on.

Those rules are OpenMPT's rendering of Scream Tracker 3, whose own replayer is here. So it is that
replayer that plays these files, on a Gravis Ultrasound, whose voices each have their own pan
position. The file is read into an S3M file, each command under its S3M letter, and that is played.
8xx goes under the X of the trackers that came after Scream Tracker.

Most of the PC's other trackers' files are played here by Impulse Tracker's replayer. That would
play
these files as Impulse Tracker played an S3M file, with a memory of its own for each command, which
is not how OpenMPT plays them.

OpenMPT does three things otherwise for these files than for an S3M file, and the replayer is told
of them:

- A slide to a note that names another sample keeps the rate of the one sounding, as well as its
  sound. Scream Tracker takes up the other's rate.
- A slide on a channel whose sample has come to its end starts it again. Scream Tracker slides it in
  silence.
- A tempo is the tempo asked for. Scream Tracker's timer on the Ultrasound goes by whole ticks a
  second, so 136, which one of the files asks for, would be played as 135 is.

### Differences and limits

Some things are Scream Tracker's and not OpenMPT's, and are left so:

- Its loudest volume is 63, where OpenMPT's is 64.
- Its Ultrasound has sixteen pan positions, and a position is played at the nearest.
- It plays a sample that has no loop on into a little silence after its end.

Other limits:

- The song goes back to its top when it comes to its end, where a file can ask for another place.
  None of the files in the collection does, and a file that did would say so.
- A channel in surround is played in the middle, and the file says so.
- The file's master volume, which OpenMPT takes for how loud the whole is played, is left out. The
  files are made as loud as each other, as every kind of file here is.

All three files in the collection are played. Compared with libopenmpt tick by tick, every channel's
pitch, volume and pan position agree on 25,747 of 25,984 ticks. The files are made about as loud as
other modules are.

## MASI — Epic MegaGames' music, in PSM files

Epic MegaGames was the shareware publisher of Jill of the Jungle and Jazz Jackrabbit. It put the
music of its games for DOS into files of its own, named PSM, and played them with a music and sound
system of its own, known as MASI. MASI was Joshua Jensen's work: Jazz Jackrabbit (1994) credits him
with its sound system.

Robert A. Allen wrote much of the music it played:

- Epic Pinball's (1993), James Schmalz's game, with music by Allen and Jensen;
- Jazz Jackrabbit's;
- all of Extreme Pinball's (1995).

The musicians wrote their tunes in the trackers of the day, Scream Tracker among them. A converter
of Epic's made each into a PSM file for the games' player. OpenMPT and the ModdingWiki, which
reverse-engineered the format, call these ProTracker Studio modules, though they have nothing of
ProTracker's own.

### The two kinds of file

Silverball's files and the first Epic Pinball's are of an older kind, which begins "PSM" and then
FE. Epic Pinball's later ones, Jazz Jackrabbit's, Extreme Pinball's and others are of a newer kind,
which begins "PSM " (with a space).

The older kind is much like an S3M file. It has a header that says where the rest is, the list of
patterns, a pan position for each channel from 0 to 15, the samples' headers, and the patterns. Each
pattern is packed much as an S3M file packs its own.

The newer kind is made of chunks. A game's music is often one file of several songs, one for each
moment of the game: a main tune, an introduction, a fanfare for a bonus, the music of a lost ball.

Each song is a little program. It says which patterns it plays, at what speed and tempo, and each
channel's pan position or that the channel is in surround. It also says where the song goes back to
when it comes to its end. Then come the patterns, each with its own count of rows, and the samples,
each a chunk.

The game Sinaria's files, whose songs are dated 1994 in them, are a little otherwise. Their patterns
are named "PATT", their samples' headers are laid out differently, and their notes and slides are
counted as the older kind's are.

Both kinds have ProTracker's commands under numbers of their own. The samples are mostly of eight
bits, kept as the difference of each byte from the one before.

### How siday plays it

MASI's player is not to be had apart from the games. OpenMPT plays these files by the rules it plays
an S3M file by, exactly as it plays a DSM file (see the chapter on DSM). One value is remembered for
most commands together, fine and extra-fine slides are within the commands, and so on.

So here, as DSM files are, these files are read into an S3M file, each command under its S3M letter.
Then Scream Tracker 3's own replayer plays them on a Gravis Ultrasound, with the three things
OpenMPT does otherwise for such files than for an S3M file.

Each song of a newer file is a song of its own here, with the name the file gives it. It starts with
its own speed, tempo and pan positions, and at its end goes back to where it says, where Scream
Tracker would go back to the top of the list. As with any module, a song of less than a second (a
sound effect kept as a song, say) is not counted.

A channel in surround is played as OpenMPT plays it, and as the games did. It is as loud on each
side, with the right side upside down, so that it seems to come from all round. Heard in mono it is
in the middle, as it would otherwise be lost. A command that gives the channel a pan position takes
it out of surround.

Where a converted command means one thing to Scream Tracker and another to OpenMPT in these files,
OpenMPT's meaning is played:

- A note cut on the row's first tick (SC0) silences the note, where Scream Tracker passes it over.
- An S command of nothing is nothing, where Scream Tracker would repeat the last.

A newer file's pattern break always goes to the top of the next pattern, as MASI has it and OpenMPT
plays it.

### Differences and limits

Some things are Scream Tracker's and the Ultrasound's and not OpenMPT's, and are left so:

- **Volume:** the loudest volume is 63, where OpenMPT's is 64.
- **Panning:** the Ultrasound has sixteen pan positions, at which a side is turned down by its own
  steps, and a position is played at the nearest. So a channel put well to one side is heard nearer
  the middle than OpenMPT puts it.
- **Pitch:** the card holds a voice's pitch to a 512th of its own rate. So a sample is played a
  little flat, the lower its rate the more (a tenth of a semitone at 6 kHz), as it was on a real
  Ultrasound.
- **Vibrato** does not move on a row's first tick.
- **Sample ends:** a sample with no loop plays on into a little silence after its end.
- **Tempo:** a tempo is the tempo asked for. libopenmpt makes each tick a whole number of samples,
  which at 48 kHz is a little faster: Extreme Pinball's tempo of 135 is a tenth of a percent faster
  there.

Other differences:

- An older file's master volume, which OpenMPT takes for how loud the whole is, is left out, as
  every kind of file here is made as loud as the others.
- So is a channel's own volume, which a newer file can set, and the file says so. None of those in
  the collection sets it.
- A loop that goes back and forth, which the older kind can have, is played forwards, and the file
  says so.
- A start further into a sample than 64 KB is played from the nearest place below that, as OpenMPT
  plays it, and the file says so. None of the files in the collection asks for one.
- OpenMPT writes the pan positions of a later song's channels into its first pattern, where there is
  room; here the song starts with them.

All sixteen files in the collection are played, with 55 songs among them. Compared with libopenmpt
tick by tick, every song is at the same row on every tick, and 99.3% of ticks are alike. The files
are made about as loud as other modules are.

### Settings

Pro Sound Maker's files for the ZX Spectrum are also named PSM. A file is taken to be Epic's if it
begins as one of these does, and Pro Sound Maker's otherwise. So `--formats masi` and `--formats
psm` choose between them.

## IT — Impulse Tracker, and ModPlug Tracker after it

Impulse Tracker is Jeffrey Lim's, from 1995, and was added to until 1999. It looks like Scream
Tracker 3, on purpose, and does a great deal more. It has instruments in the sense FastTracker has
them, and beyond. It also has what no tracker before it had: a note that does not stop when the next
one starts. Years later its author published its source, which is how a replayer like this one can
be the tracker's own.

### How siday plays it

An IT file is played as Impulse Tracker 2 played it, by way of it2play's port of its replayer. That
brings:

- **64 channels,** each of which can have many notes sounding simultaneously, up to 256 voices in
  all. An instrument says what becomes of its note when the next one comes: cut, left to play on,
  released or faded.
- **Envelopes** for volume, panning and pitch.
- **A resonant low-pass filter,** worked by an envelope or by the Zxx effect.
- **Pitch slides worked out in whole numbers,** as Impulse Tracker did before its last version,
  which few people had.

The sound is not from one of Impulse Tracker's own drivers. Those were written for the sound cards
of the 1990s, and cannot play a stereo sample. It comes from the driver it2play adds to them, which:

- mixes in floating point;
- reads samples through an eight-point windowed sinc;
- ramps volumes so that notes do not click;
- gives the filter the wider range ModPlug Tracker gave it, where a file asks for that.

Compressed samples are unpacked. So are:

- samples that ModPlug Tracker packed in a way of its own, four bits a sample, which it2play leaves
  silent;
- samples kept as the difference from each point to the one before, or with their bytes the other
  way round, as OpenMPT reads them.

Impulse Tracker has room for 100 samples, 100 instruments and 200 patterns, and it2play refuses a
file with more. Later trackers wrote such files, and they are played: up to 253 samples, 254
instruments and 254 patterns. That is as many as the format's single bytes can number. Impulse
Tracker uses the numbers just past its hundredth sample to mean a note sent out by MIDI. For a file
with more samples, those meanings are moved to the top of the range.

### Differences from it2play

Four other things are done differently from it2play:

- **The filters start open,** as they do in Impulse Tracker's drivers. it2play leaves it to a line
  of the tracker's MIDI settings to open them. So in it2play, a file that brings settings of its own
  with that line blank is played with every filter shut, muffled from end to end.
- **A sample said to begin at the very end of the file** has no sound, where it2play gives up on the
  whole file. That is how ModPlug Tracker wrote an empty sample, in one file of twenty-five.
- **The "ramp up" wave** for a sample's own vibrato, which OpenMPT added and Impulse Tracker has not
  got, is played as that wave. it2play reads past the end of its three waves.
- **Sound from outside a sample,** which a few files lead it2play to read, is silence here.

### Files of other trackers

A file that Impulse Tracker made is played as Impulse Tracker played it. But some things are done as
the tracker that made the file did them, where that was not Impulse Tracker. Two of them are
commands:

- **S9F and S9E.** S9F plays a sample backwards, and S9E forwards again, in every tracker that came
  after Impulse Tracker. To Impulse Tracker they are nothing. They are played in a file that says
  another tracker made it.
- **The command after Z in the alphabet** is ModPlug Tracker's. It is a Z whose macro is sent a
  little at a time, so that a filter slides over the row to where Z would have put it at once. It is
  played in a file of ModPlug Tracker's or OpenMPT's.

The third is about instruments. An instrument can be given a MIDI channel, and Impulse Tracker then
sends its notes to a synthesiser and plays no sample for them. ModPlug Tracker and OpenMPT played
the sample all the same. Their composers often left a channel set, above all on the drums of a tune
brought in from a MIDI file. So in such a file, if it says one of those two made it, those
instruments' samples are played, as its composer heard them.

Such a file is also heard through its plug-ins, where they are OpenMPT's own. ModPlug Tracker could
send a channel or an instrument through the effects that came with Windows, which OpenMPT has since
built into itself, and some eight hundred IT files in the collection do. They are the same effects,
wired the same way, as for an MPTM file (see below).

A plug-in that is anybody else's is left out, and said to be. Older files, which name an
instrument's plug-in in a place of their own, are read too. An XM file of those trackers can have
plug-ins too, and is heard through them in the same way: see XM.

### ModPlug Tracker's filter

The fourth thing is the filter itself. ModPlug Tracker had a filter of its own before it had Impulse
Tracker's. It is the same kind of filter, but it rings half as much for the same resonance, and it
goes by other rules:

- A note starts with it only if its cutoff is below the top.
- A macro or an envelope that sets it puts it on.
- Once on, it stays on until the next note.

So a filter set wide open still takes the top off the sound, at five kilohertz. To Impulse Tracker,
a filter wide open is no filter at all.

OpenMPT kept that filter for the files that were made with it. It took up Impulse Tracker's in its
version 1.20, and only for a file that asks to be played as Impulse Tracker would play it. Even then
it uses its own curve if the file asks for ModPlug Tracker's wider range of cutoffs, which Impulse
Tracker's has not.

So a file is played here with the filter it was made with. Which that is, is told by the signs
OpenMPT goes by: who the file says made it, the version that last saved it, and the ways of playing
it lists.

With it come some smaller things of ModPlug Tracker's, each for a file that tracker or OpenMPT made:

- **Filters the other way up.** An instrument's filter can let the high through and not the low.
- **Random filters.** An instrument's filter can be moved at random from one note to the next, the
  cutoff or the resonance or both, by as much as its instrument says. An older file goes on adding a
  note's random move to whatever a command sets the filter to while the note lasts; a newer one does
  not.

Three things about envelopes are done ModPlug Tracker's way in a file that does not ask for Impulse
Tracker's:

- In a file from before OpenMPT 1.20, an envelope for pitch or for the filter goes round its loop a
  tick sooner.
- An envelope that is to carry on from the note before does not, after a note whose key was let go,
  if the row names the instrument.
- A slide to a note starts the envelopes again if the instrument has none for volume.

A sample that ends where it is loud would click, and both mixers let its last level die away
instead. ModPlug Tracker's mixer, which is still OpenMPT's, does it sixteen times more quickly than
Impulse Tracker's, and so it is here for these files. It changes most of them a little.

### Surround

A channel in surround is heard on both sides, with one of them upside down. Such a channel goes by
ModPlug Tracker's rules. To Impulse Tracker it is in the middle, and any pan position it is given
takes it out.

In ModPlug Tracker's way, which OpenMPT keeps for a file that does not ask for Impulse Tracker's,
only Xxx does that. The volume column, S8x, the instrument or the sample put the channel somewhere
in surround, and it is heard there. Envelopes and slides move it from there, as they move any
channel.

A file that asks for Impulse Tracker's ways has Impulse Tracker's, but for S9B. S9B lets a channel
be in surround and somewhere at once, as on four speakers, until S9A. S90 takes a channel out of
surround where it is. After S9D a note begins with no filter, unless its instrument has one of its
own, until a macro or an envelope sets it; S9C puts that back.

### Pitch as a period

A note's pitch is kept as ModPlug Tracker kept it. Impulse Tracker keeps it as the rate the sample
is played at, so many times a second. ModPlug Tracker kept it as a period, as the Amiga's trackers
did. That is a whole number that slides and vibratos move, and that the rate is worked out from. So
a high note's pitch is coarser, and moves in larger steps.

OpenMPT went over to rates in its version 1.24 for a song with linear slides, and in 1.30 for one
without. It keeps periods for a file of ModPlug Tracker's, or of an OpenMPT from before then, unless
the file asks for rates. So does siday, with OpenMPT's own arithmetic, as for an MPTM file (see
below).

The files of ModPlug Tracker 1.0, from before it wrote a version of its own, say Impulse Tracker
2.14 or 2.02 made them. They are known as OpenMPT knows them, and played in Impulse Tracker's ways,
as OpenMPT plays them, but for their pitches. Following OpenMPT, the files of an older Schism
Tracker that kept periods too have their pitches kept as periods, by the day its version says it was
made.

### Vibrato, panbrello and other ways of OpenMPT's

Vibrato, tremolo and a sample's own vibrato are OpenMPT's own in a file of ModPlug Tracker's or
OpenMPT's that does not ask for Impulse Tracker's ways, as they are in an MPTM file. They use
ProTracker's waves of 64 steps, and the vibrato's wave is begun a quarter of the way along at each
note.

Panbrello is OpenMPT's own in such a file too: ProTracker's wave again, at twice the depth. In
OpenMPT's own way, the note is back where it was once the panbrello's rows are over; Impulse Tracker
leaves it where the last tick put it. A random panbrello takes a new pan position every tick.

The pan position that a note's instrument or sample gives it is the channel's from then on, for the
notes after it that are given none. That is as ModPlug Tracker had it, and OpenMPT and Schism
Tracker for a time. Impulse Tracker puts the channel back where it was.

With that come the other ways of OpenMPT's own that an MPTM file was already played with:

- An instrument named with no note starts nothing, and a note that is playing goes over to its
  sample.
- SCx turns a note down to nothing and leaves it playing.
- Qxy and Ixy are counted as OpenMPT counts them.
- A slide to a note that would take another sample starts the note instead.

Two more of ModPlug Tracker's ways are followed in such a file:

- An instrument number beside a note-off leaves the note's volume as it is. Impulse Tracker gives
  the note its sample's own volume again.
- A ping-pong loop plays its last point twice as it turns. Impulse Tracker turns a point sooner, so
  a short loop sounds a little higher.

In a file of a tracker that had no filter, Zxx is nothing, as it was to them. Those trackers are
Impulse Tracker before 2.14 and ModPlug Tracker 1.0 before its sixth alpha.

### Files of an older OpenMPT

An older OpenMPT meant something else by four of a file's numbers. These are changed when such a
file is read, so that the file sounds as it did:

- **A sample's own vibrato** that says zero for how fast it comes in comes in at once, in a file
  from before 1.20. To Impulse Tracker zero is never, and such a sample would have no vibrato at
  all.
- **Random panning:** how far a note's pan position is moved at random is a quarter of what the
  number says, in a file from before 1.26.
- **Pitch and panning:** how far higher notes are sent to one side is a half or a quarter of what
  the number says, in a file from before 1.26.
- **Random volume:** the random move of a note's loudness is counted out of 64 and not out of 100,
  before 1.20.

### Interpolation

A voice of a file of ModPlug Tracker's or OpenMPT's is interpolated as OpenMPT interpolates it. A
sample is only so many points, and a voice that plays it at another rate than its own has to be
given a level between them. Each of Impulse Tracker's drivers has its own way of doing that.
it2play's, which is heard here, reads eight points through a windowed sinc.

OpenMPT lets the composer choose one of five ways, for each instrument:

- no interpolation at all, each point heard as it is until the next, which keeps the grit of a
  sample played below its own rate;
- a straight line from one point to the next;
- a curve through four;
- two sincs of eight.

The choice is kept in the file, and most of the instruments that make it ask for no interpolation.
Such an instrument is heard as its composer chose.

An instrument that does not say is interpolated as OpenMPT does one by itself, through its own sinc.
That sinc is a shade duller than it2play's. It is made duller still for a voice that goes through
its sample nearly a fifth faster than the sound is made, or more. That is so that what is too high
to be made at that rate does not fold back down into what is heard, as aliasing.

### Loudness

How loud a file of ModPlug Tracker's or OpenMPT's is follows OpenMPT only as far as that keeps it
about as loud as every other tune here, which comes first. A loud tune is to be loud whatever kind
of file it is, and a quiet one quiet. A file's own pre-amp, the composer's, is followed.

OpenMPT has also had several ways of adding a song's channels up, and a file says which it was made
for:

- **ModPlug Tracker's own,** the oldest, turns a song down by the number of channels it has, by a
  table. It leaves such files some 8 dB below the rest, and over the files in the collection, the
  fewer their channels the louder it leaves them beside the others. So that way is not followed. The
  turning down that the original replayer gives ModPlug Tracker's own files is taken out again.
- **The ways of OpenMPT 1.17** are followed, and measured so that they leave their files as loud as
  the rest. One of them is twice as loud as Impulse Tracker, and puts a channel that is to one side
  at no more than one in the middle.

### Files packed with MMCMP

Some IT files, and some S3M files, were packed whole by MMCMP, Emmanuel Giasson's Music Module
Compressor for DOS. It knew a module's samples from the rest of it, and packed each as the sound it
is. Such a file is unpacked before it is read, as Teemu Suutari's ancient unpacks it.

## GDM and PTM — BWSB and PolyTracker

GDM was the one format of BWSB, a sound system that DOS games were built with. Nobody composed in
it. A GDM file is an S3M, a MOD or some other tracker's module, written out again by BWSB's
converter, with up to four commands beside a note.

PTM was the format of PolyTracker, which set out to be a better Scream Tracker. It had 32 channels,
samples of sixteen bits, and loops that go back and forth.

### How siday plays it

A GDM file and a PTM file are played by Impulse Tracker's replayer too, which is not their own. As
with the three kinds of file that FastTracker's replayer plays for want of theirs, what is heard is
another tracker's reading of the tune. Neither BWSB's player nor PolyTracker's is ported, and there
is nothing here to say how either sounded to the sample.

What is done is what Impulse Tracker did with an S3M file. The file is read into Impulse Tracker's
own shape, with its commands given as the letters that do the same. Then it is played with "old
effects" on. Each channel is at the pan position the file gives it.

### Differences and limits

Some of what these files ask is not Impulse Tracker's to give:

- A PTM sample played backwards is handed to it as a sample of its own, written out backwards.
- PolyTracker's slides by semitones are played as smooth slides that get as far.
- Its volumes, which a Gravis Ultrasound did not space quite evenly, are spaced evenly.
- Sliding by semitones and retuning a sample in the middle of a tune (E3x and E5x in both) are left
  out.
- So is any command of a GDM note's four that neither the one command Impulse Tracker has room for
  nor its volume column can do.

Three things are changed on the way in, because Impulse Tracker alone would take them otherwise:

- An instrument named on a row with no note is given as the instrument's volume, where Impulse
  Tracker would have played the note again.
- In a tune that began as a MOD, a slide of zero does nothing, where Impulse Tracker's would go on
  with the last.
- In a tune that began in Scream Tracker, a command given zero goes on from the last number given
  to any command on its channel, as Scream Tracker's did. Impulse Tracker's would go on from the
  last of its own kind. One tune in the collection leans on that: a held note's vibrato goes on into
  a fade that takes the vibrato's number.

## ULT — UltraTracker

A ULT file is from UltraTracker, a tracker that Marc André Schallehn wrote for DOS and the Gravis
Ultrasound in the early nineties. A tune has:

- up to 32 channels, each at any of sixteen pan positions;
- samples of eight bits or sixteen;
- ProTracker's commands under ProTracker's numbers, two of them beside a note where ProTracker has
  one.

### How siday plays it

UltraTracker's replayer was never published. Nothing to be found says what its commands did beyond
their names, in FreeJack's description of the file. Every one of those commands is one that Impulse
Tracker has. So siday plays ULT files on Impulse Tracker's replayer, with "old effects" on, as it
does the GDM and PTM files above. OpenMPT and Schism Tracker put these files there too.

Four things do not go over as they stand:

- **Two commands to a note.** Impulse Tracker has room for one, beside its volume column. The second
  goes in that column when it is one the column can do: a volume, a pan position, a volume slide, or
  some pitch slides. Where the column can only do nearly what is asked, it does the nearest. A
  command for the whole tune, its speed or where it goes next, moves to a channel of the row that
  has room. What is left with nowhere to go is left out, and the file says so.
- **Slides to a note go on by themselves.** In UltraTracker a slide to a note carries on row after
  row, until it gets there or another note comes. The replayer does that for these files alone.
- **Letting a note go.** A sample loops for as long as its note is held, and UltraTracker can let a
  note go, so that the sample plays on to its end. That is Impulse Tracker's sustain loop and its
  note-off.
- **Volumes** are out of 255, where Impulse Tracker's are out of 64.

Where nothing says what UltraTracker did, siday makes a choice, mostly OpenMPT's:

- Two speed commands beside one note are a speed and a tempo, and both are kept. The same command
  twice is played once.
- A volume slide with nothing to slide by goes on with the last one.
- A volume slide by fifteen is played as one by fourteen, because Impulse Tracker's slide by fifteen
  starts a tick early.
- An instrument named with no note sets that instrument's volume, as in the files above, where
  OpenMPT changes the sample under the note that is playing.
- Sometimes two commands stand beside such an instrument, and the volume column is wanted for one of
  them. Then the replayer is told to set the volume itself. It does not start the note again, as
  Impulse Tracker would if the note were over. Three files do this all through, to move a sound from
  side to side while it dies away.

### Differences and limits

Three things are not played, and a file that asks for one says so:

- a note played without its sample's loop;
- the command that sets how deep vibratos go from then on;
- a note that is to start further into its sample than Impulse Tracker's command can reach. It
  starts as far in as that reaches.

In a file from before UltraTracker 1.4 the volumes were not evenly spaced. siday plays them as if
they were, as everybody plays them.

All 126 files in the collection are played, and their pitch and volume match libopenmpt's on 729,705
of 769,384 ticks. The files are made as loud as XM files are, by measurement.

## MDL — Digitrakker

An MDL file is from Digitrakker, which Prodatron wrote for DOS in the middle of the nineties. Its
files came in three kinds, from its version 2 to its version 3. A tune has:

- up to 32 channels, each at any of 128 pan positions;
- instruments like FastTracker 2's: a sample for each range of notes, with envelopes for volume,
  panning and pitch, a fade, and a vibrato of the sample's own;
- envelopes that belong not to the instrument but to the tune: 64 of each kind, which the
  instruments name and a command can change between;
- samples that can be kept packed, each byte stored as its difference from the one before, in as few
  bits as it needs;
- two commands to a note, in two columns. The first is for its pitch (slides, vibrato, arpeggio),
  the second for its volume (slides, tremolo, tremor, striking the note again), and the rest go in
  either.

### How siday plays it

Digitrakker's replayer was never published. OpenMPT plays these files on its own replayer, as it
plays an IT file, and has been taught what Digitrakker does differently. Every command of
Digitrakker's has its like among Impulse Tracker's. Its instruments are Impulse Tracker's with less
in them. So siday plays MDL files on Impulse Tracker's replayer, as it does the ULT and GDM files
above, and reads each file as OpenMPT reads it.

What OpenMPT does differently is given to the replayer, for these files alone:

- **Pitch is a period,** as on the Amiga, but one that a sample's rate does not change. So a slide
  moves every sample's notes by the same amount. The periods are Scream Tracker's, cut to whole
  numbers. A slide, a vibrato, an arpeggio and a pitch envelope each move or multiply the whole
  number, as OpenMPT does.
- **Vibrato and tremolo** go as ProTracker's do, on a wave of 64 steps that does not move on during
  a row's first tick.
- **A note cut short (ECx)** is turned down to nothing and plays on, so that a volume brings it
  back. One tune uses this as a gate. EC0 cuts at once, and ED0 holds nothing up.
- **Letting a key go:** the note fades, whatever its volume envelope does. The end of that envelope
  neither fades the note nor ends it. Fades are finer than Impulse Tracker's.
- **A pitch envelope** goes six semitones either way at the most, where Impulse Tracker's goes
  sixteen.
- **A sample's own vibrato** comes in over so many ticks, as OpenMPT has it.
- **EFx,** which starts a note further into its sample, counts in bytes. In a sample of sixteen bits
  that is half as many samples. It also moves a note that is already playing.
- **An instrument named with no note** keeps the volume of the sample that was playing. One named
  beside a key let go gives the volume of its sample for the channel's last note. A sample may have
  no volume of its own, and then it leaves the channel's as it was.
- **A slide to a note with no note beside it** goes on with the last slide, but only until it gets
  there.

### Two commands to a note

What does not go over as it stands is the two commands. Impulse Tracker has room for one, plus its
volume column. The second goes in the volume column when it is one the column can do and the note
has no volume. Otherwise OpenMPT keeps the one that matters more and leaves the other out. siday
leaves less out:

- **Panning:** a pan position, or a fine move of it, that has no room is kept beside the cell. The
  replayer puts the channel there when it reads the row.
- **Commands for the whole tune** move to a channel of the row that has room, as for ULT files.
- **Far starts:** OpenMPT puts the part of EFx beyond what Impulse Tracker's Oxx reaches in the
  volume column, where the note's volume would be. So in OpenMPT a note started far into its sample
  is played at the loudest, whatever it asks. siday keeps that part beside the cell too, and the
  note keeps its volume.
- **Slide or vibrato beside a volume slide:** a slide to a note or a vibrato that only goes on,
  beside a volume slide, becomes Impulse Tracker's Lxy or Kxy.

What is left with nowhere to go is left out, and the file says so.

### Volume slides and tempo

Digitrakker's volume slides are its own. They go by 256ths of the whole volume a tick, four times as
fine as Impulse Tracker's, and as fast as 223 of them. A slide that Impulse Tracker's can do is
played as that. The replayer does the others as Digitrakker does them. It keeps the part of the
volume finer than Impulse Tracker's 64ths for as long as nothing else sets it. One composer swells
notes in from nothing with such fine slides, which OpenMPT leaves silent or swells four times too
fast.

A tempo below 32, slower than Impulse Tracker goes, is a tune's way of stopping. A tick at a tempo
of 1 is two and a half seconds. With the speed of 255 that goes beside it, a row is ten minutes. So
the song ends there, after the row. OpenMPT reads it as a tempo slide and plays on very slowly.

### Differences and limits

Two commands are not played, and a file that asks for either says so: E8x, which changes how a
sample loops, and E5x, which tunes a sample afresh. 9xx changes a note's envelope to another of the
tune's. Here it turns on the instrument's own instead, as OpenMPT has it, and the file says that
too.

Where nothing says what Digitrakker did, the choice is OpenMPT's, but in one thing. A note that
names an instrument the file does not have plays nothing, and leaves the note before it as it was.
OpenMPT plays it on the sample that was playing, at the new note's pitch.

All 148 files in the collection are played, and 82 of them match libopenmpt's pitch and volume on
every tick. The files are made as loud as XM files are, by measurement.

## J2B — Jazz Jackrabbit 2 and the Galaxy Sound System

A J2B file is a piece of the music of Jazz Jackrabbit 2, Epic MegaGames' platform game of 1998. The
game played its music with the Galaxy Sound System, Carlo Vogelsang's sound engine. Galaxy's modules
were not written in a tracker of its own. They were written in the trackers of the day, and turned
into Galaxy's format by a converter, mod2j2b.

That format is a RIFF file, as a Windows sound file is. The song, each pattern and each instrument
(with its samples inside it) are in parts of their own, much as an IT file has them. It came in two
kinds, an older one marked "AMFF" and a newer one marked "AM ".

The game keeps each file packed with zlib, Jean-loup Gailly's and Mark Adler's library of Phil
Katz's DEFLATE. In front is a header that begins "MUSE". It gives the file's length, the length the
music unpacks to, and a checksum of what is packed.

### How siday plays it

So a J2B file is unpacked first. siday has DEFLATE in Swift of its own, because it uses no library
of the system it runs on. A file is refused unless the lengths in its header and both checksums are
right.

Galaxy's replayer has never been published. OpenMPT reads these files into the shape of an IT file.
It plays them as it plays an IT file, with all of Impulse Tracker's ways it knows. siday plays them
the same way: on Impulse Tracker's replayer, read as OpenMPT reads them and keeping time as OpenMPT
does.

The commands are ProTracker's and FastTracker's. Each has its like among Impulse Tracker's but two:
FastTracker's Kxx, which lets go of a note's key after so many ticks, and Lxx, which moves along an
envelope. A file with either would say they are left out, and none of the game's files has them.

A volume of 127 in the newer kind of file becomes one of Impulse Tracker's 64. A pan position
becomes one of its 64 too, the nearest one in a file that asks for an odd position out of 128. The
instruments are Impulse Tracker's: a sample for each note, envelopes for volume, pitch and panning,
a fade and a vibrato of the sample's own. The game's files have one sample to an instrument, and no
envelopes, fades or vibratos.

The one thing OpenMPT does differently from Impulse Tracker that these files are heard to need is
the vibrato. Their vibratos are played with Impulse Tracker's "old effects". On a vibrato's first
tick, these bend the note by the wave where it is, and only then move along it.

In OpenMPT, a note struck on a channel takes the vibrato back to the start of its wave, so the next
vibrato starts unbent. In Impulse Tracker the bend of that first tick is wherever the last vibrato
left off. The replayer does as OpenMPT does for these files, and for no others.

All 24 files in the collection are played, with nothing left out, and they match libopenmpt on every
tick. The files are made as loud as other modules are, which is a little quieter than libopenmpt
plays
them.

## DMF — X-Tracker

A DMF file ("Delusion Digital Music File") is from X-Tracker, a tracker for DOS by D-Lusion. The
first description of the format its makers gave out, partly in German, is dated Christmas 1993. The
format went through seven versions while the tracker was in its beta, and the eighth is the finished
tracker's. A later XTracker 32 wrote a tenth.

Of the 32 files in the collection, six are of the fifth version, one of the sixth and the rest of
the eighth. Their headers date them from 1994 to 1996. Some are by D-Lusion's own members, and two
say they were made from other trackers' files.

A tune has:

- up to 32 channels, and above them a track of its own for the tempo;
- samples of eight bits or sixteen, kept packed if their maker wished (451 of the 601 in the
  collection are), with a loop that holds only while a note's key is down;
- three commands to a note, in three columns. One is for its sample: stopping it, letting its loop
  go, starting it again, putting it off, starting it further in, playing it backwards. One is for
  its pitch: slides, vibrato, arpeggio, tuning, a cut. And one is for its volume: slides, tremolo,
  tremor, the pan position.

X-Tracker's timings are its own:

- a delay or a cut is in 256ths of a row;
- a vibrato's speed is in rows to the wave;
- slides are in 256ths;
- the tempo is in quarters of a row a second, or in beats a minute by the rows to a beat that each
  pattern says it has.

Patterns can be longer than Impulse Tracker's: up to 512 rows, its makers wrote.

### How siday plays it

X-Tracker's replayer was never published. OpenMPT reads these files into the shape of an IT file and
plays them on its replayer as it plays one. So here, as for the MDL files above, Impulse Tracker's
replayer plays them, read as OpenMPT reads them. What OpenMPT plays differently for them is told to
the replayer.

OpenMPT's reading has to settle a good deal, and siday follows how it does to the letter:

- **A pattern for each place.** X-Tracker's timings depend on how fast the tune is going. So each
  place in the order list is given a pattern of its own, made at the speed the tune has reached
  there.
- **Tempo.** It becomes the nearest speed and tempo of Impulse Tracker's, with as many ticks to a
  row as can be, so that arpeggios and tremors keep their shape. The tempo's track goes to a channel
  of its own, the first.
- **Slides, delays, cuts and vibratos** become Impulse Tracker's, worked out at that speed, and cut
  short as OpenMPT cuts them.
- **Scratch.** A slide to a note that the command names (X-Tracker's "scratch") gets there at once.
- **No instrument.** A note without an instrument is slid to at once, and not struck again.
- **Three commands.** The sample's is kept first. Of the others, what the volume column can take
  goes there, and the one that matters more has the command.

What is left with nowhere to go is left out, and the file says so.

The replayer is also told, for these files alone:

- **Two commands Impulse Tracker has not,** which OpenMPT keeps. One gives a note's volume by the
  command, where the volume column has something else. The other tunes a note by up to a semitone
  either way; a note struck on an instrument takes that away again.
- **The volume column** has pitch slides up to 63, where Impulse Tracker's stop at nine. It can also
  play a sample backwards and forwards, as S9F and S9E do.
- **A vibrato** plays where its wave is on a row's first tick, and moves on only after. Every note
  struck starts its wave again.
- **A tremolo** only ever turns a note down, by a share of its volume. It moves on along its wave
  after each tick but the first, so the first two ticks are alike.
- **A note cut short** is turned down to nothing as well. So the next note on a sample with no
  volume of its own (and many have none) is silent until it is given one.
- **A tick** lasts a whole number of frames, and what is over is cut off, as in OpenMPT's way of
  keeping time.

### Differences and limits

siday does two things differently from OpenMPT:

- **Very high notes.** OpenMPT's notes go an octave and two thirds higher than Impulse Tracker's,
  and one file plays 74 of them. siday plays each an octave down, on a copy of its sample that plays
  an octave up, which is the same sound.
- **Scratched notes keep their loop.** X-Tracker's scratch turns every note it is on into a slide to
  a note on a row that names the note's instrument. siday keeps the sample's loop there.

OpenMPT lets the loop go on such a row, so the sample plays to its end and stops, and the note comes
back a row or two later. But it does so only because the files are not IT files to it at that point
of its replayer. The same rows in an IT file, which is what its reading makes of them, keep the
loop. One file's scratched bass line goes silent for a row at a time in OpenMPT, and plays on here.
One other file has a note like it.

All 32 files are played, and their pitch, volume and panning match libopenmpt's on 927,707 of
938,569 ticks. The files are made as loud as IT files are, by measurement.

## PLM — Disorder Tracker 2

A PLM file is from Disorder Tracker 2, a tracker for DOS. Its song is not a list of patterns played
one after another, but one long stretch of rows. Its patterns are laid on it like cards on a table.
Each lies at the row and the first channel the list says, as long and as wide as it is, over any
other it is laid across. A tune has:

- up to 32 channels, each at one of sixteen pan positions;
- samples of eight bits or sixteen, each with a rate of its own, a loop, and a pan position of its
  own if it likes;
- commands numbered by the tracker itself. They are Scream Tracker's under other numbers, with one
  of its own: a start into a sample by so many 256ths of its length.

### How siday plays it

Disorder Tracker's replayer was never published. OpenMPT plays these files by Impulse Tracker's
rules, with "old effects", and has been taught a few things the tracker does differently. So siday
plays them on Impulse Tracker's replayer, as for the other trackers' files above, and reads each
file as OpenMPT reads it:

- The long stretch of rows is cut into patterns of 64 rows, one after another in the list.
- A jump to where an item of the list begins, or to where its own pattern ends, becomes a jump to
  the pattern that falls there and a break to the row. For that, the patterns have one channel more
  than the file, of breaks alone.
- A start into a sample with no note beside it is a start into the channel's last note in the same
  item of the list, struck again.

The replayer is told, for these files alone and as OpenMPT plays them:

- **A slide to a note** remembers its speed together with the slides up and down, as Impulse
  Tracker's does without "compatible Gxx". And yet one that names another sample goes on with the
  sample the channel last played. It plays that one from then on, even where its note has ended.
- **A slide to a note from F0 up** is a fine one, by the rest, made once at the row's start.
- **A sample's pan position** is its notes', and does not become the channel's from then on.
- **A start into a sample** with no note moves the note that is playing. A start by 256ths of the
  sample is by 256ths of it up to its loop's end.
- **After a slide up or down,** a slide to a note with none of its own goes on the same way, as far
  as a slide can.

### Differences and limits

That last is the one place where OpenMPT is not followed. OpenMPT means a slide up to leave the next
slide to a note going up, and one down going down, and says so. But it reckons these files' pitches
as rates, and the ends it sets that slide going to are periods, so its own slide goes the other way.
siday's goes the way OpenMPT means it to. None of the files in the collection has such a slide.

An item of the list may start in a pattern no earlier item has reached, while a later one is further
on. siday lays it on the song, where OpenMPT's loader passes over it. No file in the collection has
one of those either.

A volume over 64, which some files have, is 64, as OpenMPT has it. The file's greatest volume for
slides and its amplification are not looked at, by OpenMPT or here. A song longer than Impulse
Tracker's replayer has room for would lose its end, and say so.

All four files in the collection are played, and their pitch, volume and panning match libopenmpt's
on 34,745 of 34,761 ticks. The files are made about as loud as other modules are, by measurement.

## MPTM — OpenMPT

An MPTM file is another matter, because the tracker that writes it is alive and plays its own files.
OpenMPT descends from ModPlug Tracker, which wrote IT files. When it wanted more than an IT file can
say, it kept the IT file and wrote the rest after it. So an MPTM file is an IT file, and Impulse
Tracker's replayer plays it.

### How siday plays it

What is written after the IT file is read as OpenMPT reads it. The replayer has been given as much
of it as it can honestly be given, each thing in a way that an IT file never reaches:

- **Keeping time.** It keeps time in OpenMPT's three ways. One is Impulse Tracker's own. In another
  the tempo is ticks in a second. In the "modern" one the tempo is beats in a minute, and a beat is
  so many rows, whatever the speed. The rows of a beat are swung longer and shorter if the song or
  the pattern says so. A tempo can be a fraction, or above 255.
- **Size.** A pattern can have 1024 rows, and the order list can be longer than 256. A file can have
  several order lists, which are its songs.
- **Commands.** A command's value can go on into the rows below it. A note can be delayed and cut by
  one command, started at a place its sample names, and played backwards.
- **Envelopes** can have more than 25 points, and a point to go to when the key is let go.
- **Filter.** It can let the high through instead of the low, and can be moved at random from note
  to note. It is OpenMPT's own filter unless the file asks for Impulse Tracker's (see the IT chapter
  above, where the same is told of an IT file).
- **Instruments tied to a tempo.** Such an instrument is played as much higher or lower as the song
  is faster or slower than that tempo.
- **Mixing.** A file can ask for OpenMPT's own way of adding its channels up. It is twice as loud as
  Impulse Tracker's, and puts a channel panned to one side at no more than one in the middle.

OpenMPT has three more things that Impulse Tracker never had: FM, plug-ins and tunings.

### FM instruments

Since 2018 an instrument of OpenMPT's can be a patch for the AdLib's FM chip in place of a sample.
One file in seven in the collection has such instruments. They are played, on the same chip that
plays the AdLib's own music here.

The replayer plays an FM note as it plays any other, on a voice of its own whose sample has no sound
in it. So all that can be done to a note is done to this one. After each tick the chip is told what
OpenMPT would have told it: which of its eighteen voices the note has, the patch, and from then on a
pitch, a level and a side.

OpenMPT's own chip is another emulator of the same chip, so the sound is not its sound to the
sample. A few things are played OpenMPT's way for these files, for samples as much as for the chip:

- **A sample's own vibrato,** which OpenMPT reads a step before Impulse Tracker does, and rounds
  differently.
- **A vibrato,** which OpenMPT starts from the top of its wave with every note struck, and Impulse
  Tracker only with a note on its own row.
- **OpenMPT's finetune command,** which bends a channel's notes by up to as many semitones as the
  instrument says.

The chip is as loud against the samples as OpenMPT makes it.

### Plug-ins

Half the MPTM files in the collection use plug-ins. A plug-in is somebody's program, and none can be
run here. But OpenMPT has a few of its own built in, which it plays on any machine. Four files in
five that use plug-ins use only those:

- an echo, two reverbs, a chorus, two flangers, a compressor, a distortion, an equaliser and a
  gargle, all modelled on the effects that came with Windows;
- the echoes of two Amiga trackers, DigiBooster and Symphonie.

siday has them all, each carried over from OpenMPT's own. The one built-in it does not have is
OpenMPT's LFO. It makes no sound of its own, and is there to move another plug-in's settings: in the
files in the collection, somebody else's plug-in every time.

They are wired as the file wires them:

- A voice goes to the plug-in of its instrument, or failing that of its channel.
- What a plug-in makes goes to the listener, or on to another plug-in.
- A plug-in can be put on the whole sound.
- The file says how much of what a plug-in was given is heard beside what it makes, how the two are
  put together, and how loud.

A tune can change a plug-in's settings as it plays, by a kind of note that is for nothing else or by
a macro, and siday does that. A change slid over a row is made a little at each of its ticks.

A plug-in that is not OpenMPT's own is left out, as OpenMPT leaves out one it cannot find: what was
sent to it is heard as it is. An instrument that is nothing but such a plug-in is not heard. A file
in which half or more of the notes are for such instruments is refused.

### ModPlug Tracker's reverb

ModPlug Tracker's mixer had a reverb of its own, which is not a plug-in, and OpenMPT keeps it. S99
puts a channel's notes in it, and S98 takes them out. siday has it, carried over from OpenMPT's.

It is played in an MPTM file, and in an IT file of ModPlug Tracker's or OpenMPT's. Impulse Tracker
has no S99, and in a file it saved the command is nothing. It is also played in their XM files and,
on the Gravis Ultrasound, in their S3M files.

OpenMPT can also put every channel in the reverb, by a setting of its player's. That is the
listener's to choose, not the file's, and siday does not do it.

### Tunings

An instrument can be tuned to a scale of its own:

- a temperament: twelve steps to the octave that are not quite equal;
- a scale with more or fewer steps than twelve (nineteen, twenty-two, twenty-four);
- a scale with no octave in it at all (eleven steps to an octave and a fifth).

Such a scale gives each of its notes a ratio to middle C, and has so many "fine steps" between one
note and the next.

OpenMPT plays a note of a tuned instrument in a way of its own, which has nothing to do with how it
plays any other. The pitch is not a rate that slides move. It is worked out afresh from the note,
and from how many fine steps it has been taken from there:

- a slide up or down goes so many fine steps a tick;
- a slide to a note goes so many a row;
- an arpeggio goes by the scale's own notes;
- the pitch envelope goes by fine steps;
- a vibrato moves the pitch by up to a fortieth either way.

siday does this as OpenMPT does, and works out the scale's pitches in OpenMPT's own arithmetic.

### Interpolation

How a voice is interpolated is OpenMPT's choice too, as for an IT file of OpenMPT's own (see the IT
chapter above). It is an instrument's own choice of the five ways. Failing that, it is the song's,
for an MPTM file can choose one for the whole song. Or else it is OpenMPT's sinc.

Of the 700 files in the collection, 201 choose for the song, and 108 of them choose no smoothing at
all. Played through OpenMPT's sinc, those would be much duller than their composers heard them.

### OpenMPT's own ways of playing

There is a difference of another kind, which no list of features covers. OpenMPT plays these files
in its own way, and not Impulse Tracker's, wherever the two differ. The file says which way it wants
each of some hundred and forty small matters played. siday follows these:

- **Tempo and where the tune goes.** A handful of the matters, where they decide the tempo or where
  a tune goes next.
- **Vibrato and tremolo.** The one that chooses between Impulse Tracker's vibratos and tremolos and
  OpenMPT's own. A file in four asks for OpenMPT's. They are on ProTracker's wave, begun a quarter
  of the way along and the other way about. A sample's own vibrato comes in by a sweep, and moves by
  a share between two of the slide tables' steps.
- **Where a file asks for Impulse Tracker's vibratos,** OpenMPT's ways with a sample's own vibrato
  and with a vibrato's start are still OpenMPT's.
- **Pitch as a period.** The one that keeps a note's pitch as a period, a whole number, and not as a
  rate in hertz. That is how older versions of OpenMPT played a song, and OpenMPT still plays a file
  made then that way: one file in ten. A high note's period is a small number, so its pitch is a
  little out. A slide or a vibrato moves it in steps of a whole period, which can be several cents.
- **Pitch in hertz.** A song that keeps its pitches in hertz, as the other nine in ten do, has its
  slides, vibratos and arpeggios by OpenMPT's own tables and rounding. They are not quite Impulse
  Tracker's. Two of Impulse Tracker's steps are further out, one by nearly a fifth of a semitone,
  and its replayer cuts each step short where OpenMPT rounds it.
- **An instrument named on a row with no note.** Impulse Tracker starts the note again with it.
  OpenMPT, unless the file asks for that, starts nothing. A note that is playing goes over to the
  new sample from where it was, as a ProTracker tune swaps its samples. Four files in five ask for
  OpenMPT's way, and in ten of them it is heard.
- **SCx, the cut.** In OpenMPT's own way (a file in four) it turns the note down to nothing and
  leaves it playing, so that a volume on a later row brings it back.
- **Retrigger and tremor.** In OpenMPT's own way (four files in five) they count the channel's ticks
  from its last note, across rows. A retrigger strikes a note again even once its sample has ended.
- **"Compatible Gxx".** With it, a slide to a note of another instrument's sample takes that sample,
  and starts the note.

For the rest this is Impulse Tracker's replayer, and the file gets Impulse Tracker's answer.

### Differences and limits

Of the 700 files in the collection, 699 are played. One is refused for keeping its samples in other
files. A file that is played with something left out says what, a sentence for each kind of thing.

Where the tune is on every tick, and how long each tick lasts, is the same as in libopenmpt in 692
files.

## MO3 — Un4seen's packed modules

An MO3 file is a module made smaller: an IT, XM, S3M, MOD or MTM, packed by Un4seen, the makers of
the BASS sound library, which plays them. Its patterns are packed
without loss. Its samples may be packed without loss too, or kept as MP3 or Ogg Vorbis, which leave
out what the ear does not hear and keep a module much smaller (see OGG). The collection's 149 MO3 files
were made from 64 IT files, 63 XM files, 21 MODs and one S3M.

### How siday plays it

An MO3 file is unpacked into the module it was made from, written again in that module's own format,
with its samples decoded. That module is then played as any module of its kind is, by the same
replayer: an IT by Impulse Tracker's, an XM by FastTracker 2's, and so on. Where an MO3 says which
tracker made the module, the module is played as that tracker played it, as it would be from its own
file. The format's name beside the tune says MO3, and the detail says what it was made from.

The unpacking is libopenmpt's, and its samples come out the same as libopenmpt decodes them, to the
bit. A sample kept as MP3 or Ogg Vorbis is heard as it was kept, not as it was before: what the
packing left out is not there to be heard.

### Differences and limits

- **The tracker's own marks:** an MO3 file does not keep everything of the module's own file, such as
  a MOD's four letters or an IT's edit history. None of it changes what is heard.
- **A MOD's samples** are of eight bits in mono. One that an MO3 keeps in sixteen bits or in stereo is
  played as a MOD's sample is, and is marked so.
- **Plug-ins and MIDI:** a module's plug-ins and instruments for a MIDI synthesiser are played, or
  left out and marked, as they are in that kind of module.

## MT2 — MadTracker 2

MadTracker was a tracker for Windows by Yannick Delwiche, from the late nineties into the 2000s. It
was much used for the trance and the dance music of its day. It had:

- up to 64 tracks;
- instruments with envelopes for volume, panning, pitch and a resonant filter, which do what Impulse
  Tracker's do;
- samples of eight bits or sixteen, and in stereo, which can be tied to the beat;
- beside a note, FastTracker's commands and Impulse Tracker's both, and a few of its own;
- eight tracks of drums, laid out as a drum machine's are;
- on each track, effects of its own, VST plug-ins, and envelopes drawn over a pattern for any
  setting ("automation").

Its player has never been published, and nor has its format. OpenMPT reads the files, with a loader
by Olivier Lapicque from ModPlug Tracker's days. It is the only other player that does: nothing else
is to be found, libxmp and Schism Tracker included. Nor is there anything of MadTracker's own about
the format beyond the names that OpenMPT's loader gives.

### How siday plays it

OpenMPT reads one of these files into the shape of an IT file, instruments, envelopes, filters and
all. It plays it as it plays an IT file, but for some twenty places where its player asks whether
the file is an XM or an MT2, and goes FastTracker's way for both.

So siday plays it as OpenMPT plays it, on Impulse Tracker's replayer. It keeps time in OpenMPT's
ways, as for an MPTM file. A tick is as long as MadTracker's samples to a tick make it, at a tempo
that is a fraction. Or it is Impulse Tracker's way, for a file that sets its tempo as Impulse
Tracker does.

The replayer is taught those of OpenMPT's ways for these files that the files in the collection were
found to need, each in a way no other file reaches:

- **Slides of volume, global volume or panning** go by their first half where both halves are set,
  as FastTracker's do. So there is no fine slide but FastTracker's own. A pan slide goes right by
  its first half and left by its second, as FastTracker's does.
- **A pitch slide and a vibrato** round to the nearest hertz, where Impulse Tracker's cut to the one
  below. A vibrato does not move on during a row's first tick.
- **A sample's own vibrato** comes in over so many ticks, as FastTracker's does, from the top of a
  wave that stays above the note.
- **Letting a key go** silences a note with no volume envelope, and the note goes on, silent. Any
  other note fades as soon as its key is let go, if its instrument fades. It fades as finely as
  OpenMPT has it. An envelope that has run out holds its last level.
- **An instrument named without a note** starts the note's envelopes again. It is for the last note
  the channel had that was a note, and not a note-off. Beside a note-off, its sample's volume is
  that of the sample the instrument plays the last note on.
- **A sample that ends** dies away as quickly as OpenMPT lets it.

### Commands and drums

The commands become Impulse Tracker's under the letters that do the same. A FastTracker command goes
by its meaning, and an Impulse Tracker command is itself. MadTracker's own go by what OpenMPT makes
of them: pitch slides every tick, vibrato, volume, tempo, a pan position or surround, the filter's
cutoff, playing backwards, a track's volume.

Impulse Tracker has room for one command and a volume column. MadTracker has a third place, for a
note's pan position. What OpenMPT cannot place, it leaves out, and so does siday. Each file says so.

A slide in the volume column can go by fifteen, and Impulse Tracker's goes to nine. Where the
command is free the slide becomes the command, and otherwise it is nine.

The drums are eight more channels, each a sample struck at C-5 as loud as its pattern says. A
pattern that the list plays with more than one drum pattern is made once for each.

A file can say it has 256 patterns or samples, which are more than a byte of Impulse Tracker's can
number. Only the patterns the list plays are kept. A sample beyond the numbers takes the number of
one that the file has not got, and nothing plays.

### Differences and limits

What OpenMPT leaves out is left out here, and the file says so:

- the tracks' own effects, which 95 of the 106 files in the collection have on some track;
- the automation, in 57;
- VST plug-ins, in one, whose only plug-in is an instrument that its patterns never play.

An instrument that is a plug-in or a MIDI device plays nothing. A file is refused, as an MPTM file
is, if half or more of its notes are for such instruments, or for samples kept in files of their
own. None in the collection is.

A command that OpenMPT does not know is left out and reported, in ten files. Most are MadTracker's
own commands that nothing describes. So is FastTracker's command that sets where an envelope is, in
two files; OpenMPT plays it, but Impulse Tracker's replayer has not got it. And a sample that is to
be played without smoothing between its points is played smoothed; two files ask for that.

All 106 files in the collection are played, and are at the same place as libopenmpt on every tick.
Played as loud as OpenMPT plays them, these files would be quieter than XM files, so siday makes
them
as loud as XM files are.

## SYMMOD — Symphonie and Symphonie Pro

Symphonie is Patrick Meng's tracker for the Amiga, and Symphonie Pro its later, larger form. Songs
made with it were being put on Aminet from 1994: Marco Ege's "Breathless" came that September. A
sixteen-bit DSP module for its version 2.11c followed in 1995. The songs of 1996 to 1998 ask for its
versions 2.3, 2.4, 3.0 and 3.2.

Its version 2.4 was sold. A version of it held to eight tracks came on the twelfth of the Aminet
CDs, which told of its fourteen-bit playing. Symphonie did not play its notes on the Amiga's four
voices, but mixed them itself. Symphonie Pro has 256 channels, a sixteen-bit DSP and samples of
sixteen bits, and was sold for 120 marks. Its source went to Aminet some years later, and,
completed, to GitHub by 2016, as amiga-news.de reported that January.

Its modules are of their own kind. A song is sequences of places in its tracks. Each place is a
stretch of a track, played at its own speed and transposition and so many times over. The tracks are
all of one length.

The instruments are made from their samples as the song is loaded, by what Symphonie does to them
first. A sample can be:

- played backwards or upside down;
- filtered high or low;
- put through a resonant filter whose cutoff moves over the sample;
- faded;
- made as loud as it can be, and then louder;
- squashed over a knee;
- given a loop that goes round so many times before it plays on.

An instrument can also be "virtual", mixed from other instruments' samples at other notes, together
or one after another. Or it can be a "transwave", blended from one sample's loop into another's. A
stereo sample is two instruments, played on two channels together. The samples are kept in whatever
kind of sound file they came in, IFF, WAV, AIFF or Symphonie's own, packed or not.

The 35 files in the collection are by five composers, MoSeZ's twenty-five among them.

### How siday plays it

No player of Symphonie's own is to hand. OpenMPT reads these files, with a loader by Devin Acker and
the OpenMPT developers, made after Patrick Meng's own player in Java and Symphonie's Amiga source.
It reads them into a module of its own kind, with Impulse Tracker's ways of playing but for one: a
note is struck again even once its sample has ended.

siday plays them that way, as it plays an MPTM file (see MPTM). That is, on Impulse Tracker's
replayer, with OpenMPT's own pitch tables, its sinc, and its echo for Symphonie's, which 34 of the
35 files use.

Every sample is made as OpenMPT makes it, through its readers of those kinds of sound file, its
filters and its squashing. The virtual instruments are made through a copy of its mixer, with its
straight lines between points. Every track's events become the commands OpenMPT makes of them.

Symphonie's slides of volume and of pitch are finer than a tick's, and are made as it mixes. OpenMPT
keeps up with them row by row, and gives them as the nearest of Impulse Tracker's slides of a
channel's volume and of pitch. They are those here. Its echo and filter are set by Zxx macros that
OpenMPT makes for the song.

OpenMPT gives these files a few things that no file of its own has. The replayer has been taught
them, for these files alone:

- **Stopping and going on.** A channel's sample can be stopped where it is and let go on from there,
  which 31 of the 35 files do. What it last put out dies away rather than stopping with a click. The
  sound is ramped in from silence when it goes on, as OpenMPT's mixer has it.
- **Starting into a sample.** A note can start so many 256ths of the way into its sample. Beside a
  slide to it, the playing sound jumps there and slides on.
- **A slide to a note in no time.**
- **Vibrato and tremolo that go on by themselves** from row to row, under whatever else a row says,
  until one of no depth or a note stops them.
- **A macro that turns the filter about,** to let the high through and not the low.

What is left of the voices that end on their way to the echo dies away as quickly as OpenMPT lets
it.

OpenMPT also has an LFO of Symphonie's among its plug-ins, which moves other plug-ins' settings. Its
loader of these files never asks for it, so it is not here.

### Differences and limits

What OpenMPT leaves out is left out here too, and a file that has it says so:

- the DSP's delay;
- the stereo detune and phase of Symphonie Pro;
- the "emphasis" command, which fades a sample as it plays;
- the commands that add to a note's pitch and volume;
- filters of the kinds OpenMPT has not got, which it plays as no filter.

A module whose samples are kept in files of their own is not played.

A stereo sample is split as OpenMPT splits it. So the first of its two instruments, which plays on
the left, has the file's right side. With no Symphonie to compare with, whether Symphonie did the
same cannot be told, and it is as OpenMPT has it.

The notes are ramped in and out a little more softly than OpenMPT's, as for every file this replayer
plays.

All 35 files in the collection are played, and their pitch and volume match libopenmpt's on 307,271
of 307,308 ticks. The files are made about as loud as other modules, by measurement, which is 2.3 dB
louder than OpenMPT plays them.

## IMF — Imago Orpheus

Imago Orpheus was a tracker for DOS by Lutz Roeder, of the nineties. Much of its music was made for
games, and it came with a sample editor of its own, Imago Wave. Its modules have:

- **Channels:** up to 32, each panned to any of 256 positions.
- **Instruments:** a sample for each range of notes, with a fade, and envelopes of up to sixteen
  points for volume, for panning and for a resonant filter.
- **Samples:** of eight bits or sixteen, which loop forwards or back and forth.
- **Commands:** two to a note, from a list of its own. It has most of Scream Tracker's and
  FastTracker's commands, and some more. There are slides of a note by semitones, a key let go
  after so many ticks, and chorus and reverb. And there is a filter that sets and slides its cutoff
  and its resonance, as the sound cards of the day that had one did.

Its player has never been published. OpenMPT reads these files, and so do libxmp and MikMod.
OpenMPT's loader was first Storlek's, for Schism Tracker. siday follows OpenMPT's reading and
playing.

### How siday plays it

OpenMPT reads one of these files into the shape of an IT file, and plays it by Impulse Tracker's
rules. The exception is where its player asks whether a file is an IT file, which this is not. There
it does what it does for other kinds of file.

siday plays it the same way. It uses its Impulse Tracker replayer, keeping time as OpenMPT does (as
for an MPTM file), and told where OpenMPT's player goes another way for these files:

- **Vibrato and tremolo:** they play their wave where it is on a row's first tick, and move on only
  on the ticks after. A note starts a vibrato's wave again.
- **Slides with both halves set:** a slide of volume or of panning with both halves of its value set
  goes by the second half, down or to the right. Impulse Tracker's does nothing.
- **S00, T00, SC0 and SD0:** S00 and T00 are nothing, and not the last S or T again. SC0 cuts a note
  at once, and SD0 does not hold it up.
- **Global volume:** a global volume above the top is the top.
- **Fades:** a fade is as fine as OpenMPT keeps it, so the slowest fades are not cut to a whole step
  or to nothing.
- **An instrument named without a note:** it plays the channel's last note that the channel's
  instrument had a sample for. That is not always the last note the pattern gave. On a channel that
  has played nothing, it plays nothing.
- **A slide to a note after a key is let go:** it brings the note back. The note stops fading, and
  beside an instrument its key is held again.
- **The filter:** its 128 cutoffs are as OpenMPT has them for these files. They go from 125 hertz up
  by six octaves to 8,000, as Creative's EMU8000 reckons them, and are not spaced as Impulse
  Tracker's are.

The commands become Impulse Tracker's, under the letters that do the same, as OpenMPT makes them.
Two commands to a note are placed as OpenMPT places them. One goes into the volume column if either
can go there. Otherwise the one that matters more, by OpenMPT's reckoning, is kept, and the other is
left out, and the file says so. Two of the twelve files in the collection have such notes.

Channels and patterns:

- **Channels switched off:** a channel that the file switches off is silent, and its commands for
  the
  whole tune are left out.
- **Channels silenced:** a channel that is silenced is silent, and plays on.
- **One odd file:** in one file in the collection, every channel but the first is silenced. OpenMPT
  takes it for a file saved wrongly, as no other is known to be so, and it is played with them all.
- **Missing patterns:** a pattern that the list names and the file has not got ends the song, as it
  does to OpenMPT.

Envelopes are made to sound as Imago Orpheus's did:

- **Envelope ends:** an envelope that neither loops nor holds holds at its last point. Impulse
  Tracker's envelope would end the note there, and Imago Orpheus's does not.
- **Holds:** a hold after the loop is left out, as one that comes too late to matter.
- **Loops:** a loop is a tick shorter. In Impulse Tracker's, a loop takes in the tick of its last
  point, and in Imago Orpheus's it does not.

### Differences and limits

These are not played, as OpenMPT does not play them:

- the chorus and the reverb (Yxx, Zxx and each channel's own);
- a slide of the filter's cutoff (Nxy's first half);
- the finer sample offset (Pxx);
- XFx, which changes how a sample loops;
- X1x, which sets the filter.

Nor are these, which OpenMPT plays and Impulse Tracker's replayer has not got: note slides (Gxy and
Hxy), a key let go after so many ticks (Qxx), and a finetune (Fxx). None of these last three is in a
file in the collection.

Glissando (X3x) is left out too. OpenMPT makes it S2x, which is Scream Tracker's finetune and would
put the channel out of tune, and Impulse Tracker has no glissando. A file says which of all these it
has.

All twelve files in the collection are played. Compared with libopenmpt, every channel's pitch and
volume match on 115,793 of 116,165 ticks. Played as loud as OpenMPT plays them, these files are
quieter than other kinds of module, so siday makes them louder, to sit level with them. Each file's
own mixing volume and master volume are kept.

## AMS — Velvet Studio and Extreme's Tracker

Extreme's Tracker was a tracker for DOS by the group Extreme. The group became Velvet Development,
and made Velvet Studio after it, also for DOS. Both kept their modules in files called AMS. These
are of two kinds, which share only the way their patterns are packed.

Extreme's Tracker's files begin "Extreme". They have samples and no instruments, up to 32 channels,
and ProTracker's commands and some more.

Velvet Studio's files begin "AMShdr". They have:

- **Channels:** 32.
- **Instruments:** a sample for each note, with envelopes for volume, panning and pitch (a vibrato
  drawn by hand), and a fade.
- **Shadows:** instruments that play another's samples with settings of their own.
- **Samples:** of eight bits or sixteen, which loop forwards, back and forth or backwards, packed if
  their maker wished.
- **Tempo:** a tempo that is a fraction.
- **Commands:** as many to a note as a cell has room for, ProTracker's and more of its own.

Velvet Studio's source was made public in 2013. OpenMPT reads both kinds, with a loader of its own,
and siday follows its reading and playing. All eight files in the collection are Velvet Studio's.

### How siday plays it

OpenMPT reads both kinds into the shape of an IT file, with "old effects" and "compatible Gxx" on.
It plays them by Impulse Tracker's rules, except where its player asks whether a file is an IT file,
which these are not. There it does as it does for other kinds of file.

That is as for Imago Orpheus's modules (see IMF, above), and these files share their ways:

- slides with both halves of their value;
- S00, T00, SC0 and SD0;
- fades as fine as OpenMPT's;
- an instrument named alone, for the last note it had a sample for;
- and a slide to a note beside an instrument, that brings back a note let go.

OpenMPT's player also has three ways for these files alone, and siday follows them too:

- **Pitch envelopes:** an envelope for pitch has 255 levels about a middle of 128. OpenMPT takes
  that
  as up to 32 sixteenths of a semitone either way, two semitones. An instrument's "vibrato
  amplification" scales it.
- **Letting a key go:** the command that lets a key go after so many ticks lets it go at once, on
  the
  row's first tick, as OpenMPT has it. The file says it has such commands.
- **Backwards samples:** a sample that plays backwards starts at the end of its loop, and goes round
  it backwards.

As OpenMPT plays them, the volume column's vibrato is as deep as the command's with "old effects".
Impulse Tracker's replayer has it half as deep. It also does not leave its bend in a slide to a note
beside it.

The commands become Impulse Tracker's, under the letters that do the same, as OpenMPT makes them. A
note's commands are put into its cell one after another, as OpenMPT puts them. Where two cannot be
joined, the one that matters more by OpenMPT's reckoning is kept. The other goes to the volume
column
if that is free and can take it, and is otherwise left out, as OpenMPT leaves it out. Four of the
eight files have such commands, and each file says how many.

A shadow's sample is its source instrument's sound, with the shadow's own rate, loop and volume. The
channels are panned as the Amiga's are, left, right, right and left, as OpenMPT pans them. A pattern
the list names and the file has not got ends the song.

### Differences and limits

These are not played, as OpenMPT does not play them: an envelope's speed, a command's fraction of a
tempo, and breaking a sample's loop (E80). Nor are these, which OpenMPT plays and Impulse Tracker's
replayer has not got:

- **Backwards from an offset:** a sample played backwards from a place in it (an offset beside
  "backwards").
- **Glissando** (E3x).
- **Scream Tracker's finetune** (E5x), which OpenMPT makes of ProTracker's, and which would put a
  sample out of tune.

None of these is in a file in the collection.

An Extreme's Tracker file's highest note, C-10, is beyond Impulse Tracker's notes. It is played a
semitone lower, and the file says so. No Extreme's Tracker file is in the collection, so these were
checked only with files made for the purpose.

One more way of OpenMPT's is not followed. In OpenMPT, a channel left playing backwards by a command
goes on so into its next note. Of a sample that does not loop, that note ends before it is heard. In
one file a few notes are lost so.

All eight files in the collection are played. Compared with libopenmpt, every channel's pitch and
volume match on 96,590 of 96,745 ticks. Played as loud as OpenMPT plays them, these files are
quieter than other kinds of module, so siday makes them louder, to sit level with them.

## 669 — Composer 669 and UNIS 669

A 669 file is a module from Composer 669, which Tran of Renaissance wrote for the PC in 1992. Or it
is from UNIS 669, which came after and added a little. It has eight channels, samples of eight bits,
patterns that each have a speed and a last row of their own, and a handful of commands.

Composer 669 is unlike the trackers that came from the Amiga in one thing, and it is why these files
have a player to themselves. Those trackers count a note's pitch as a period, and slide it by adding
to that, so a slide is a wider step the higher the note. Composer 669 counts in samples a second,
and its slides add to that:

- **Slides:** 80 samples a second on every tick for each one of the command's value, and 40 for a
  slide to a note. So a slide is widest on the lowest notes. Turned into another tracker's commands,
  it would be wrong on nearly all of them.
- **Vibrato:** it is not one, either. Every other tick the note is played 668 samples a second
  higher
  for each one of the value, which is a trill.
- **Commands carry on:** a command, once given, goes on until the channel has another command or
  another note.

### How siday plays it

Neither program's replayer has ever been published, and nothing in siday's player is a port. It is
written from the descriptions that came with the two programs, and from what OpenMPT and libxmp make
of such a file. The numbers above are OpenMPT's, and libxmp has the same ones.

It plays through a mixer of its own, since there is no card's sound to be faithful to. Composer 669
mixed for a Sound Blaster at 22 kHz, and UNIS 669 played through a Gravis Ultrasound. siday's mixer
is neither: it puts a curve through each four samples, at the output's rate, and lets nothing click.

In three things OpenMPT and libxmp disagree, or OpenMPT disagrees with the program's own manual, and
a choice was made:

- **The trill:** the manual says a command goes on until the next. OpenMPT stops the trill at the
  end
  of its row. In siday, as in libxmp, it goes on.
- **Slide to a note:** it begins on its first tick in siday, as in libxmp, and as the other slides
  do
  in both. In OpenMPT it begins a tick later.
- **A pattern's own speed:** it is the pattern's speed from its first row. OpenMPT writes the speed
  into the pattern as a command, so it has to put it a row late if every channel of the first row
  has a command already.

Two more are matters of taste:

- **Panning:** Composer 669 had its channels all the way to the left and to the right, turn and turn
  about. That is all a Sound Blaster Pro could do, and it is hard on the ears in headphones. siday
  brings them in to five eighths of the way, as OpenMPT has them.
- **Tick length:** a tick is a seventy-eighth of two and a half seconds, which OpenMPT and libxmp
  both
  agree on. libopenmpt drops the part of a sample that this comes to at its output's rate, and so
  runs faster by a third of a thousandth.

Of 167 files in the collection that are named for the format, three are not 669 files at all, and
are refused. The other 164 are played. Compared with libopenmpt, every channel's pitch and volume
match on 894,484 of 901,749 ticks. siday plays these files as loud as XM files.

### UNIS 669's commands

UNIS 669's two commands are played, in files that say they are its own:

- One moves a channel a little to the left or the right on every row.
- The other strikes a note again and again through its row. OpenMPT takes this to mean every so many
  ticks, and so does siday.

UNIS 669 also has a tempo faster than the fastest, which nothing says the speed of. A file that asks
for it is left at the tempo it had, and says so. Two of the files have commands that neither program
is said to have had. They are left out, and those files say so too.

## C67 — Composer 670

A C67 file is from Composer 670, which is Composer 669 with an AdLib card beside it. It has four
channels of samples and nine of the card's FM voices, 32 samples and 32 patches for the chip. CDFM,
the player that went with it, had another kind of file, the 670, which its converter turns back into
this one. A C67 is what the composer itself kept.

It is the plainest module there is. It has no commands at all. A pattern is a list of notes, each
with an instrument and a volume, of volumes alone, and of how many rows to wait before the next
thing. A tune has a speed that nothing changes.

Its volumes are sixteen, and the least of them is not silence, for a sample or for the chip. It
counted the chip's volumes evenly, which the chip itself does not, so each has to be looked up.

There is nothing in that which Impulse Tracker's replayer has not got, so siday plays these files
with it. The FM chip beside it is played as OpenMPT plays it, as for an MPTM file. OpenMPT is the
only other player of them. The pitches, the tempo of 143 to the minute, and how loud the chip is
against the samples are as it has them.

All 34 files in the collection are played. Compared with libopenmpt, siday is at the same row on
every tick, and alike on 212,060 of 216,154 ticks. The files are as loud as XM files are, by
measure.

## FAR — Farandole Composer

A FAR file is from Farandole Composer, which Megan Potter of Digital Infinity wrote for the PC and
the Gravis Ultrasound in 1994. It played on that card and nothing else. It has sixteen channels,
each
at one of sixteen pan positions, 64 samples of eight bits or sixteen, and patterns as long as they
like, up to 256 rows. Its file was the composer's own working file, and keeps what the composer had
open as well as the tune.

### How it keeps time

It is like no other tracker in how it keeps time. A tune has a tempo from 0 to 15, which is how many
thirty-seconds of a second a row lasts. It also has a fine tempo that commands add to and take from.

From the two, the program worked out how many ticks a second there were to be. It set the PC's
timer to that, four ticks to a row. Where that is slower than the timer's sixteen bits can count, it
halved the tick and gave the row more of them. But it did not give as many more as would keep the
row the length it was. And it took the timer to count a third of a percent faster than it does, so
every tune is that much slower than it says. siday keeps all of that.

The fine tempo is the part other players leave out. OpenMPT reads the two commands for it as
nothing, and so does what was made from ModPlug's code, VLC among them. A tune that sets one is then
heard at its plain tempo. For a tune that raises it by six on its first row, that is nearly a fifth
too slow.

### Its slides and other ways

- **Slides:** they are its own too. They are counted in the steps of the Ultrasound's frequency
  register, so many samples a second and not so much of a period, as in a 669 file.
- **Slide to a note:** it is asked for once, with the number of rows it is to take, and goes on by
  itself until it is there. A slide to a volume does the same.
- **Vibrato:** how deep it goes is one setting for all sixteen channels.
- **Samples and volumes:** a sample's number counts only beside a note, and a note with no volume
  beside it is silent.

### How siday plays it

The program's replayer was never published, so a FAR file has a small player written for it, as a
669 file has. It is written from the description of the file that came with the program, and from
libxmp, whose authors compared their player with the program itself and wrote down what they found.

Two things are libxmp's and not OpenMPT's. A pattern that the list names and the file has nothing of
is 64 rows of nothing. And the tempo is the program's, where OpenMPT plays every file at one.

Compared with libxmp on every tick of the 37 files in the collection, the two are never at different
rows, and 32 files are alike on every tick. The files are as loud as XM files are, by measure.

## CMF — Creative's music files

A CMF file is a tune for the FM chip alone. It holds its instruments, each the handful of numbers
the
chip wants for one, and the music as MIDI. It was Creative's format. What played it was SBFMDRV, the
driver on the disk that came with a Sound Blaster.

That driver is what siday plays it with, by way of fmdrv's port of it to C. It is a small and
particular MIDI player:

- **Voices:** nine, or six and the chip's five drums when the tune asks for them.
- **Key speed:** a key's speed is worked into the instrument's own level.
- **Controllers:** four of its own, one of them to move a channel's pitch by fractions of a
  semitone.
- **Pitch bend:** none, as MIDI has it; it passes over it.

What it did oddly is done oddly here too, since the tunes were written to how it sounded. The tune's
clock is the PC's timer, and the timer and the chip ran off the one crystal. So a tick is a whole
number of twenty-fourths of one of the chip's samples, and the two are kept in step exactly.

siday matches fmdrv playing on Nuked OPL3 to the sample, on all 932 files in the collection, from
end to end.

## ROL — AdLib's Visual Composer

A ROL file is a piano roll from AdLib's Visual Composer, the program that came with the AdLib card.
It has nine voices, or six and the drums. Each is a list of notes and, beside it, the times at which
its instrument, its volume and its pitch change.

### How siday plays it

It is played by AdLib's own sound driver, as AdPlug has it from the code AdLib gave programmers.

A ROL file holds no sounds. It names its instruments, in eight letters at most, and the sounds were
in a bank file beside it. That was `STANDARD.BNK`, which came with the program and which people
added
to and passed on, or a bank of the tune's own. So siday looks for an instrument in three places, and
the first to have it wins:

1. a bank with the tune's name beside it (`TUNE.BNK` for `TUNE.ROL`);
2. `STANDARD.BNK` beside it;
3. the bank built into the player.

The built-in bank is what lets a ROL file be played by itself. A browser has the banks it has been
given, found as the command line finds them beside the tune, and the built-in bank for the rest.

The built-in bank has 9,683 instruments:

- AdLib's own 145;
- some 1,200 more, from a dozen enlarged banks that travelled with collections of ROL files;
- and the rest from the bank of IMPlay, a later player of the same kind of music, for the sake of
  the names.

Banks do not always agree about a name. Where they differ, AdLib's bank has it, and after that the
sound that most banks give it.

Of 1,509 ROL files tried, 1,479 find every instrument. The other 30 are left with one, two or three
that no bank in the collection has, and those are silent. The tune's detail says how many.

siday matches AdPlug's ROL player on Nuked OPL3, given the same bank, to the sample on every one of
those files.

A beat is played as sixty ticks at most, however many the file gives it, as AdLib's driver had it.
Tunes with more were written to that.

### How CMF and ROL files sound

A CMF file and a ROL file are heard as the card put them out. They are in one channel, through the
filter on the card's board that kept its output centred. They are brought from the chip's rate to
the player's through a windowed sinc.

## FMT — FM Tracker

An FMT file is a song from FM Tracker, a small tracker for the AdLib card by Davey W Taylor. It has
eight voices, each with one instrument that it keeps for the whole song. Its patterns hold nothing
but notes and the places where notes stop.

Neither the tracker nor any account of its files by the man who wrote it has turned up. What there
is, is OpenMPT's loader for them, by someone who wrote songs in the tracker. siday's player goes by
that, and by what OpenMPT then does with the song. It reads a file as OpenMPT reads it.

- **Pitch:** it gives each note to the chip as the numbers OpenMPT gives it. That puts middle C at
  257 Hz, a third of a semitone under concert pitch. It leaves the very highest notes as much as a
  sixth of a semitone out, as OpenMPT's sums are in whole numbers.
- **Stopping a note:** it stops a note as OpenMPT stops one in these files, by giving the voice a
  pitch of nothing. So the note is cut off where another tracker's would die away.
- **Clock:** the clock is the PC's timer left alone, 18.2 ticks a second, kept in step with the chip
  as a CMF file's is. Each place in the song has a delay of one to eight ticks to the row.
- **The delay comes first:** the tracker waited out the delay before it played a row, not after. So
  the last row of every pattern goes at the next pattern's speed, and songs were written to that.

How the tracker itself sounded is not known beyond this. For the four songs in the collection, and
for files made to try every note, every register the player sets, and the tick it sets it on, is
what OpenMPT sets.

It is heard as CMF and ROL files are, and turned down, by measure, to be as loud as they are.

## VGM — what was written to the chip, and when

A VGM file (Video Game Music) holds no tune and no player. It is a recording of what a machine wrote
to its sound chips while the music played: every write in order, with the waits between them counted
in 44,100ths of a second. To play one is to write the same to the same chip at the same moments.

The format grew to cover dozens of chips, of game consoles, arcade boards and computers. The PC's
music was recorded from the games as they ran. VGZ is the same file packed by gzip, which is how
they
are mostly kept, and siday now unpacks a gzip file of any kind before it reads it.

### The OPL chips

siday plays the PC's FM music, on the OPL3 that plays the other music made for the AdLib and Sound
Blaster cards:

- **The OPL** (YM3526), with its one wave.
- **The OPL2** (YM3812), the AdLib's.
- **The OPL3** (YMF262), the Sound Blaster Pro 2's and 16's, with its eighteen channels and its two
  sides.

Two of a chip are played too. Two OPL2s that a file marks as a Sound Blaster Pro's, Creative's first
card in stereo, are put each on its own side, as that card had them. That is harsh in headphones, so
siday brings them most of the way together, as it does an Amiga's sides (see Settings, below).

A file asks for its own volume, and may ask for one chip to be louder. Both are heard.

### The AY-3-8910 and the PC speaker

The AY-3-8910 is General Instrument's chip of 1978, and the ZX Spectrum 128's and the Atari ST's (as
Yamaha's YM2149). siday plays it on the chip that plays their music.

The files for it in the collection are PC speaker music. The speaker had no sound chip, only a
square
wave from the PC's timer, and the format has no chip for it. So the music was recorded as the first
channel of an AY-3-8910, a square wave at one volume.

- **Which chip:** a file says which of the chips like it is meant. The YM2149's and those after it
  are heard through the YM2149's volumes, and a YM2149 with its clock halved at half the pitch.
- **Panning:** its three channels are all in the middle, as libvgm has them, unless the file asks
  for
  a ZX Spectrum's sides.
- **With an FM chip:** it can be in a file with an FM chip, and is in two in the collection, where
  the game beeps on the speaker as it starts.
- **Level:** California Games II's files ask to be three times as loud as the others, and are.

siday's chip parts a little from libvgm's where a tune's notes are deep, as in Skate or Die!'s
Downhill Race. There siday's AY chip takes out what is steady over a 47th of a second, as it does
for
every AY tune, and so that bass is a little softer.

### The Sound Blaster's samples

A Sound Blaster played samples too, through its DAC, eight bits at a time, and the format has no
Sound Blaster. So a game's samples are recorded as written to the DAC that the Sega Mega Drive's
YM2612 has beside its FM voices. They are in the format's streams. The samples are kept in blocks of
data, and a command sets one going: so many bytes a second, from a block or for so many bytes,
forwards or back, once or round again.

siday plays that as a DAC on its own, each byte heard until the next, through the same filter as the
FM chip on the card. The 34 files in the collection, of Jim Power, 4D Boxing and 4D Sports Tennis,
never start one of the YM2612's FM voices. A file that does is refused.

siday has the DAC as loud beside the FM chip as libvgm has it. These files ask to be louder than
most, and are.

### The SN76489

The SN76489, Texas Instruments' chip of three square waves and a noise, was the sound of IBM's PCjr
of 1984 and of the Tandy 1000 that followed it. siday plays it on a Swift port of MAME's emulation
of
it, which is the one libvgm plays it on, band-limited in the same way as the AY chip.

The chips made like it differ in their noise, and a file says which it was made for. Two of the
files
in the collection play samples on it. They hold a channel still and change its volume thousands of
times a second, from blocks packed four bits to a sample.

The 18 files in the collection are of King's Quest II, Skate or Die!, 688 Attack Sub and Planet X3.
Compared with libvgm, they have the same notes and noises.

King's Quest II's files ask to be much quieter than libvgm plays the chip, and others to be louder.
siday sets the chip's level so that the median file is as loud as the rest.

### The SAA1099

Philips' SAA1099 has six square waves, each at its own volume on each side, two noises and two
envelopes. It was the SAM Coupé's sound. Two of them were Creative's first card, the Creative Music
System of 1987, sold again as the Game Blaster.

siday plays it on a Swift port of SAASound, Dave Hooper's emulation of it (with Simon Owen). That is
the SimCoupé emulator's, and was revised from 2018 on others' study of the chip itself. Two things
are not as SAASound has them:

- **Channels swing about zero:** each channel swings either side of zero, as libvgm has them, and
  not from zero up as the chip's own outputs do. Otherwise every note started or stopped would move
  what is steady, and the card's filter would let that through as a thump.
- **Offsets:** an offset written to an oscillator on its own is taken up at the end of its half of a
  wave, and not held for a half more.

It is as loud as the rest. Its music puts most voices on one side or the other (nine of every ten
volumes written to it are for one side alone). So its sides are brought together as the Sound
Blaster Pro's are, by the same setting.

### Differences and limits

A file for any other chip is refused, with that chip's name. Of the 5,710 files in the collection,
from the OPL Archive and from PC games, all 5,710 play. One is silent: a third of a second that sets
the chip up and plays nothing.

For the OPL chips, siday matches the original Nuked OPL3 to the sample, given the same writes at the
same moments, on 99 files of every kind, the Sound Blaster Pro's pairs among them.

VGM files are louder than the other music for the chip, many of them because the file asks for more.
siday turns them down, by measure, to be as loud as that music. The PC speaker's files, on one
channel of the AY chip, are turned up more than an AY tune is, since only one of its three channels
plays.

### Settings

A Sound Blaster Pro's two OPL2s, and the SAA1099's sides, are brought most of the way together. A
fifth of the difference between the sides is kept, unless the listener asks for more, with
`--sb-pro-separation` or the setting in the browser. 100 is the card's own.

## OGG, MP3 and WAV — recordings

Some music is not a tune for a chip or a module at all, but a recording of it. The Amiga CD32 and
CDTV games played their music from the CD as audio tracks, and collections keep those tracks small:
UnExoticA keeps the tracks of 77 CDs this way, most of them CD32 games, as Ogg Vorbis files and a few
as MP3 or MP2. MO3 files, too, may keep their samples as MP3 or Ogg Vorbis (see MO3).

- **WAV** is Microsoft's and IBM's file of sound from 1991, the samples as they are, or a little
  smaller in one of the ways the telephone and the PC's sound cards kept them.
- **MP3** is MPEG-1 Audio Layer III, from 1993. It keeps a recording small by leaving out what the
  ear does not hear. MP2 and MP1 files are the same standard's two simpler layers.
- **Ogg Vorbis** does the same as MP3, more freely: the Xiph.Org Foundation made it free of patents,
  and its version 1.0 came out in 2002.

### How siday plays it

A recording is decoded and played as it is. The decoders are ports of stb_vorbis and minimp3, and
decode to the bit what those decode. A WAV file's samples may be whole numbers of 8 to 32 bits,
floating point, A-law or μ-law, or IMA's or Microsoft's ADPCM.

- **Rate:** each recording is brought to the player's 48 kHz through a windowed sinc. A CD's sound is
  kept unchanged up to 20 kHz, and nothing comes back mirrored as aliasing.
- **Voices:** a recording has two voices, its left and its right, or one if it is in mono. The lights
  and scopes follow them, either side can be muted, and heard in mono the two are heard together.
  A voice has no pitch to show, but the picture to listen by sees the notes it can hear struck: sudden
  rises in how loud it is.
- **Length:** a recording plays from its first sample to its last, as long as the file says. An MP3
  file's encoder put silence before and after the music, and where it says how much, as LAME's files
  do, that is taken off.
- **Name:** the title and artist are the file's own tags: Vorbis comments, ID3, or a WAV file's INFO.

### Differences and limits

- **Loudness:** recordings are turned down by 6.2 dB, to be as loud as every other format. That is
  where the median of the collection's Ogg Vorbis tracks comes to the formats' own level.
- **Past full scale:** a decoded sample is never let go beyond full scale. A recording kept small may
  go a little past it where it is loud, and a broken packet far past it. The seventh track of Dangerous
  Streets on the CD32 begins with one, to a thousand times full scale, which is heard as a click.
- **Channels:** a recording of more than two channels is not played.

## AYL — Ay_Emul's playlists

Ay_Emul, Sergey Bulba's player for Windows, keeps its playlists as text. An AYL file begins with a
line that says what it is, "ZX Spectrum Sound Chip Emulator Play List File", and the version of the
format, from 1.0 to 1.6.

After it come the tunes, one to a line, each by its path from the folder the list is in, as Windows
writes a path. A tune may be followed by what Ay_Emul knew about it, between a line that is `<` and
a
line that is `>`:

- its name and author;
- its length and where it repeats;
- the chip and clock to play it on;
- where a module begins inside a larger file;
- and a comment.

The oldest lists open with such a block before any tune, which is the program's settings on the day
the list was saved.

The format matters because of what is kept in it. Tr_Songs is a large collection of the Spectrum's
tracker music. It holds each tune once, under its author. Everything else it knows, it holds as
lists: which tunes were in which demo, game, magazine or album, what was entered at each party,
and people's lists of favourites. The comments are where a party's results are written, and where a
few authors say in their own words what a tune was for.

### How siday plays it

siday reads the tunes and the comments, and nothing else:

- **Names and lengths:** a tune's name and length are read from the tune's own file.
- **Modules for two chips:** such a module is found without being told where its second half
  begins.
- **Chip settings:** they are not followed. They are in about fifty entries of the collection: a
  clock or a kind of chip that the tune's author meant.
- **Text:** it is taken as Unicode if it is well formed as that, and otherwise as the Cyrillic of
  Windows. That is what the older lists with Russian in them are in.

Finding the tunes is the part that differs between the two players:

- **On the command line,** a path is followed from the list's folder. The lists were made on
  Windows,
  to which capitals and small letters in a name are one, and a full stop at the end of a folder's
  name is nothing. So a step of the path that is not there as written is looked for as Windows
  would.
- **In a browser,** a page has no disk to look through, only the files it has been handed and the
  path each came by. The page does not know where the list itself was among them. So there a tune is
  found by the end of its path: the file of the same name with the most folders above it named as
  the
  list names them.

It was checked on the 10,031 lists of that collection. Every one of the 42,804 tunes they name is
found, and all are played but five, which are in a format that is not played (FLS).

## M3U — the plainest playlists

M3U, "MP3 URL", was made at Fraunhofer, the institute where MP3 itself was made, for WinPlay3, its
player for Windows, by 1996. A list is the paths of its tunes, one to a line, from the folder the
list is in or from the top of the disk, and nothing more.

Players since have added lines that begin with `#`: `#EXTM3U` at the top, and `#EXTINF` before a
tune
with its length and the name to show for it. A plain `.m3u` is in the characters of the computer it
was written on, a Windows code page more often than not. M3U8 is the same list in Unicode, which is
what Apple's streaming of video over the web was later built on.

The lists that matter here come with the VGM packs of vgmrips.net. A pack is a game's music:

- a folder of its tunes, numbered;
- a text file of who wrote them and who made the pack;
- a picture from the game;
- and an M3U of the tunes in the order they come in the game, for a player to follow.

Each of the 239 folders of the collection's PC packs has one, 261 in all, and some have several. The
Lemmings packs have one for the series and one for each game. The songs that AdLib sold for its card
have one for each of its albums and juke boxes, thirteen in all.

### How siday plays it

siday reads one as it reads an AYL: the tunes, in order, and nothing else.

- **Lines passed over:** a line that begins with `#` is passed over, `#EXTINF` with the rest, since
  a
  tune's name and length are read from its own file. So is a line that is an address on the
  internet.
- **Text:** it is taken as Unicode if it is well formed as that, and otherwise as the characters of
  the Windows of the West. That is what the two lists of the packs that are not in Unicode are in.
- **Finding tunes:** its tunes are found as an AYL's are, on the command line and in a browser. A
  folder that has lists in it is played by the same rules.

### Names in the PC's own characters

One thing more is done for these lists. Three of the 4,672 tunes the packs' lists name are not there
as the list writes them. The Secret of Monkey Island's list says "Mêlée Island", and the file is
called "Mˆl‚e Island". Two of King's Quest II's have the same trouble.

The names were written in the PC's own characters, in which ê and é are 0x88 and 0x82. They were
read
later as those of Windows, in which the same numbers are ˆ and ‚.

Sometimes no file has a tune's name, even as Windows would compare it. Then siday looks for the one
file in its folder whose name is the same, with every character that is not plain ASCII set aside. A
letter that an accent is written after is set aside along with the accent. That file is taken to be
the tune. Where two files could be it, neither is.

It was checked on all the packs' lists. Every tune they name is found, all 4,369 tunes of the packs
are played once, and each list's tunes are played together and in its order. Six of the lists have
an order other than that of the tunes' names.
