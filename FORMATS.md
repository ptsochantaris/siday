# siday's formats

What siday does with each of the formats it plays: where the format came from, what its player
here is made from, how that was checked and against what, and where the references disagree, which
way was taken and why. siday's web player shows a format's part of this when the format's name
beside a tune is pressed, and on the command line `siday --about FORMAT` prints it (or `i` while
a tune of it plays). What the player is made of as a whole is in the README's
[How it is built](README.md#how-it-is-built).

## PT3 and the other AY trackers, VTX and AY files — the ZX Spectrum and the Amstrad CPC

The AY-3-8910 is a sound chip that General Instrument made from 1978: three voices of square wave,
one source of noise for the three to share, and one envelope, shared too. It is the sound of the ZX
Spectrum 128, the Amstrad CPC and the MSX, and, as Yamaha's YM2149, of the Atari ST. Music for it
is a matter of what is written to its fourteen registers, fifty times a second, and the files
played here are three ways of keeping that.

The first is a tracker's module: the notes, with the ornaments and the "samples" (lists of
volumes and tones, a tick at a time) that the tracker's own player turns into register writes.
The trackers are the Spectrum's, and most are from Russia and its neighbours, where the Spectrum
and the machines copied from it were the home computer for years after the rest of the world had
put it away: Sound Tracker (STC) and Sound Tracker Pro (STP), Pro Tracker 1, 2 and 3 (PT1, PT2,
PT3), ASC Sound Master (ASC), SQ-Tracker (SQT), Pro Sound Creator (PSC), Fast Tracker (FTC), Pro
Sound Maker (PSM), Global Tracker (GTR), and Fuxoft's AY Language (FXM), which is a program more
than a module. Pro Tracker 3 is the one most of the music is in, and
music is still written in it. TurboSound is two of the chips in one Spectrum, and a tune for it is
two modules played together. Each tracker's player here is Sergey Bulba's, from Ay_Emul, the
program this music has been kept and listened to with on the PC for twenty years and more.

The second is a recording: a VTX file is what a tune wrote to the registers, tick after tick,
packed. The third is not music at all but the part of a game that played its music: an AY file is
Z80 code, lifted out of a game or a demo with the memory it needs, and it is run here on a Z80 as
it ran on the machine. That is also the one way to keep beeper music, which is older than the
chip: the first Spectrum had a loudspeaker that its processor could push out or pull back and
nothing more, and its music is the processor doing that at the right moments, hundreds or
thousands of times a second, and nothing else while it did.

Where a reference player and Ay_Emul's source disagreed, the source was followed. Three deliberate
departures from Ay_Emul are marked in the code: old-format PSC modules start with version-correct sample
and ornament tables; an AY file only counts as Amstrad CPC once it writes a register through the CPC's
ports; and the AY player stub is placed after the file's memory blocks rather than before.

Tracker players keep the field names and control flow of the Pascal they came from, so the two can be
read side by side. Tracker modules are loaded into a 64 KB wrap-around memory and all file parsing is
bounds-checked, so a corrupt file plays wrongly or is skipped but does not crash the player.

## YM — recordings of two machines' chips

The YM file is Arnaud Carré's, made for his player ST-Sound: what an Atari ST's tune wrote to the
chip, recorded from an emulator fifty times a second and packed. Later kinds of the file (YM5, YM6)
say besides which of the ST's timer effects were running, since no list of registers can hold
those; and the name came to be used for plain recordings of the same chip in other machines.

A YM file is played one of two ways. One recorded on an Atari ST goes to the ST's chip and timers
(`STYMRenderer`): that is every YM2 and YM3, which are the ST's by definition, and a YM5 or YM6 that
gives the ST's clock of 2 MHz or uses the effects. Any other is a plain recording of an AY or YM chip
on some other machine and is played like a VTX, with the stereo choices that go with that. Asking for
a chip, a clock or a frame rate by name (`--chip`, `--clock`, `--frame-rate`) gets the plain recording
whatever the file is.

Many YM files were passed round with the first two bytes of their archive's header, its size and
checksum, written over with "xx", and its packed size too; the rest of that header is whole and
says enough to unpack them, and they are played (twenty to hand). And a file whose registers lie
one after another, with the end of the last two missing (those make no sound, and hold the timings
of the effects), is played with that end read as nothing, and says so.

## SNDH — the Atari ST and STE

The Atari ST of 1985 had the chip too, Yamaha's make of it, and no other sound. Its musicians got
more from it than three square waves, by writing to it far more often than fifty times a second,
from the interrupts of the ST's timers: a voice's volume switched fast enough to be a wave of its
own, which they called a SID voice for the Commodore's chip; samples played as a stream of
volumes, which were their drums; and the envelope started again and again in step with a note,
which makes a buzz no register setting gives. The STE of 1989 added two channels of real samples.
An SNDH file is such a tune as it was: the 68000 code that played it, lifted out of its game or
demo, with a header in front that names it and says how its songs are started and how often it is
to be called. The SNDH archive has kept the ST's music that way, some thousands of tunes.

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

The STE's blitter is there too, the chip that copies blocks of memory for pictures, because a demo or
two moves its sound about with it. Older SNDH files may be named `.snd`, as they were before the
format had its name. The titles in SNDH and YM files are read in the ST's own characters, which are
much the PC's, with Hebrew and more accented letters where the PC drew lines.

## SID — the Commodore 64

A SID file is named for the chip, the Sound Interface Device, the 6581 that Bob Yannes designed for
the Commodore 64 in 1981. It has three voices, each of which can be a triangle, a sawtooth, a pulse
of any width or noise, with an envelope of its own; a voice can be locked to its neighbour's pitch
or multiplied by it; and any of them can be sent through one filter, which is analogue, and was
never quite the same in two chips. Nothing else in a home computer sounded like it. The 8580 that
took its place in later machines is cleaner, has a filter of another character, and is quieter at
one thing the 6581 did by accident: a click on every change of the volume, which programmers
turned into a fourth voice that played samples.

Like an AY file or an SNDH file, a SID file is neither a recording nor a score but the program:
the 6502 code that played the tune in a game or a demo, lifted out, with a header that says where
it goes in memory, what to call to start each of its songs, and what to call fifty times a second
after that. The format began with PlaySID, a player for the Amiga, in 1990. The High Voltage SID
Collection, which has gathered the Commodore's music since 1996, kept it and added a second kind,
RSID, for the tunes that will only run with a real Commodore 64 around them: their own
interrupts, the timers of its two CIA chips, the raster of its video chip.

So there is a 6510 here, the Commodore's 6502, written for this project and checked on every
opcode and every cycle of the bus; as much of the machine around it as tunes ask for, with a
start-up state and a driver for PSID files that are libsidplayfp's; and the chip. The chip is
reSIDfp, the emulation in libsidplayfp, which works out the filter and the mixing of the
waveforms as the circuits they were. reSID 1.0, Dag Lem's, which reSIDfp descends from, is here
as well (`--sid-engine resid`): it is lighter, and its 6581 filter is drier. Both are ports,
checked bit for bit against the C++ on the same streams of register writes, and what the tune's
code writes to the chip was checked against what libsidplayfp has it write. A tune is played on
the chip it asks for unless `--sid-model` says otherwise, and `--sid-filter-curve` moves the
6581's filter between its bright chips and its dark ones.

A SID file does not say how long its songs are. The collection keeps a list of the lengths, found
by people who listened, and the list of its release 85 is built in; a newer `Songlengths.md5`
can be given to be asked first.

## MOD — ProTracker and the Amiga

The module began on the Amiga in 1987, with Karsten Obarski's Ultimate Soundtracker: four tracks,
one for each voice of the Amiga's sound chip, patterns of 64 rows, and fifteen samples, all in one
file, the instruments with the tune, which is what made it a module. Others took it up and
carried it on, with 31 samples and more commands, NoiseTracker and then ProTracker among them, and
ProTracker's file became the one every later tracker's descends from.

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

Amiga users packed what they kept, to get more of it onto a disk, and modules with the rest, whole,
by packers of files that knew nothing of what they packed. Two of those are met with among modules,
and a file packed by either is unpacked before it is read, whatever kind of module is inside it.
Nico François's PowerPacker was the one most used. The other is XPK, a set of packers that any
program could call on, by Urban Dominik Müller and others, each packer a library of its own with four
letters for a name; modules are found packed by three of them: SQSH, which was made for sampled
sound, NUKE, and DUKE, which is NUKE with each byte first turned into its difference from the one
before. The unpacking follows Teemu Suutari's ancient, a library that unpacks most of the packers the
Amiga had, and agrees with it to the byte on every packed module to hand: 28 packed by PowerPacker
and 8 by XPK. One of the eight unpacks to a module packed again by The Player 4.1, a packer made for
modules that reshapes them as it packs, and that one is not played.

## MED — MED and OctaMED

MED was Teijo Kinnunen's tracker for the Amiga, from 1989, and a rival to the Soundtracker family
with ideas of its own: several songs in a file, sounds made from short waves and a list of
instructions as well as samples, and notes for a MIDI synthesiser. OctaMED, soon after, played
eight tracks on the Amiga's four voices, and OctaMED Soundstudio, in the middle of the 1990s, mixed
any number.

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

Before it saved modules, MED saved songs, and the last kind of those, MED4, is what MED 2.10 to
3.00 saved: a file that begins "MED" and a 4. It says what an MMD0 module says, packed tight. Of
each instrument only the few words that are not as they would be by default are written, after a
mask of which instruments there are; and of each block only the lines and tracks that have
something on them, a nibble at a time, a note or a command in twelve bits that are the first or
the last twelve of the three bytes an MMD0 module gives a note. The samples are as an MMD0
module's are. So a MED4 file is read into the MMD0 module MED would have saved of it, and played
as that is. A song of MED 2 is taken, as libxmp takes it, not to keep how many ticks a line
lasts, and is given five where it asks for the trackers' sliding and six where it does not; none
of the files to hand is of MED 2, to show whether that is so. Left out: a
synthetic or hybrid sound, which MED4 keeps in a shape of its own; the hold and decay of notes,
in a part of the file no description lays out; and a song whose instruments are in files of
their own, which a page in a browser could not open. A file that uses the first two says so.

OctaMED's players do not read MED4 files, so the check is in three parts, on the three files to
hand, all three of MED 3.00. libxmp reads each of them as it reads the MMD0 module that a separate
script makes of it, note for note and command for command. That module, played by OctaMED's
player in the emulated Amiga, and the MED4 file played here, give the sound chip the same periods,
volumes and samples on every tick, the whole of each tune; and the file is played here as the
module is, to the sample. Where libxmp plays the file differently, it slips: it rounds where an
instrument's repeat begins down to a whole 256 bytes (the name it copies runs over into the
number). And it would read the two bits beside a note that an MMD0 module gives to the
instrument's number as part of the note; here they are the instrument's, as in a module, though
none of these files has an instrument past the fifteenth to show which is right.

## SFX and OKT — SoundFX and Oktalyzer

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

## AHX

AHX is by Martin Wodok and Manfred Linzner, Dexter and Pink of the group Abyss, from the middle of
the 1990s, and was made so that a tune for a small intro could be a few kilobytes: it sets out to
sound like the Commodore 64's chip, on an Amiga, with no samples at all.

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

## HVL — HivelyTracker

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

## DBM — DigiBooster Pro and DigiBooster 3

DigiBooster Pro is by Tomasz and Waldemar Piasta, from Poland, and was the tracker of the Amiga
that left the Amiga's sound chip behind. It played through AHI, the Amiga's way of driving sound
cards, and so it could have as many tracks as a tune wanted, samples of sixteen bits, and two
commands beside every note; and it gave an instrument envelopes of volume and of panning, each with
two places to hold at, and gave every track an echo of its own. Its DBM file is made of chunks, as
an Amiga's IFF files are, and can hold more than one song, each a list of patterns of its own. The
files to hand were saved by its versions 2.12 to 2.21, from the second half of the 1990s.
DigiBooster 3 came after it, by Grzegorz Kraszewski with APC&TCP, and in 2014 its makers published
their replayer, libdigibooster3, under the BSD licence, and said that it plays DigiBooster Pro's
modules too, being mostly the same in what it does. That replayer is what is here, ported whole
and in its own whole numbers: there is nothing else to play these files by that DigiBooster's
makers wrote, and nothing written down of what DigiBooster Pro itself did beyond the names of its
commands.

It plays like no other tracker, which is why it has a player of its own and is not read into
another's. Everything that slides is kept in units of the speed, so that a slide can move by less
than a step a tick: a volume is so many sixty-fourths times the ticks to a row, a pitch so many
eighths of a semitone times the same, and a "fine" slide adds its one step a row a little at every
tick, where other trackers add it at once. The slides move on every tick of a row, the first among
them, and once more on the next row's first. A pitch goes by a table of the eighths of a semitone
and, between those, a table for each speed of the parts of one; a slide of pitch is so many eighths
of a semitone, at any pitch, and not so much of an Amiga period. A track is put between the
speakers both by how loud it is on each side and by being heard a little later on one than on the
other, up to a third of a millisecond. Its echo comes after its instrument and before its volume,
so it follows the volume down and goes on when the note is done. Each sample is brought to the
output's rate between each two of its samples, from a buffer that is filled a thousand samples
ahead; a sample that does not go round is let go when that buffer reaches its end, which is a
little before the sample's own end.

Set beside libdigibooster3 itself, built from its sources, `siday --raw file.raw tune.dbm` writes
what the replayer writes to a file through the example program that comes with it, sixteen bits a
side, and the two are the same to the sample: on every one of the 187 songs found in the 175 files
to hand that it plays, to their ends or for ten minutes. That includes the example program's own
oddities: it asks for 100,000 frames at a time, and whether a track whose sample has ended goes on is
settled once for each part that is asked for; and a song that stops itself on a tick that fills one
of those to its end is not stopped, and plays one row more. What is heard is the replayer's but for
four things, which `--raw` leaves out:

- An echo starts as the file sets it. The replayer reads the file's settings for it and keeps them,
  but starts every echo as DigiBooster 3 does by default and goes by the file's settings only once a
  command changes one. With the file's settings, 59 of the 87 files with an echo come nearer to
  libopenmpt, which sets its echo as the file does, and 3 go further.
- DigiBooster Pro's command to let the key go so many ticks into a row, which the replayer passes
  over, lets it go, as letting go of the key on a row does at once.
- The replayer divides the sum of the tracks by how many there are, so that it can never be too
  loud, and a file of 24 tracks is then a sixth as loud as a file of four. DigiBooster Pro made up for
  the number of tracks itself, and OpenMPT and libxmp play these files about as loud whatever the
  number. So every file is divided by eight, however many tracks it has, and the rest is set by
  measure, so that the files are as loud as XM files are.
- A song that comes to the end of its list goes round to its top, as DigiBooster does, where the
  replayer's example program stops; a song found part of the way down a list stops there.

Three of DigiBooster Pro's commands are not in the replayer: setting how far into an envelope a
note is, sliding where a sample starts, and setting the tempo in beats a minute. What each did is not
written down closely enough to do it, so they are left out here too, and a file that has them says
so: 20 of the 180, most of them by one composer. Two commands for the Amiga's own filter are passed over, as the replayer passes
them over. The replayer turns away five files of the 180 that are played here: two with a sample
whose loop runs one sample past its end, which is brought back to it, as OpenMPT does; one with
something else put after the module; and one cut short, which says so. The fifth is packed with XPK,
and is unpacked first, as a MOD file is (see MOD).

Beside libopenmpt and libxmp, on every tick of the first five minutes of every file, the three are at
the same row of the song, on every tick, for all but four files and the very end of a song. Three of
those four set the start of a loop beside a change of speed on one note, and OpenMPT, which has room
for one command and a volume beside a note, loses the start of the loop; libxmp keeps it. In the
fourth a note sets the speed twice, and the replayer takes the second, as OpenMPT does, and libxmp
the first. What is heard is another matter. The other two play DigiBooster's slides
and vibratos as ProTracker's, on the ticks after a row's first and in periods, with one echo for the
whole tune or none, and so they are nearer each other than either is to DigiBooster's replayer: over
the first minute of each file the spectrum agrees with libopenmpt to 0.955 for the middle file and
with libxmp to 0.967, where the two agree with each other to 0.968, and the loudness over time to
0.939 and 0.935, where they agree to 0.971.

## XM — FastTracker 2

FastTracker 2 came out in 1994, written by Fredrik Huss and Magnus Högdahl of the group Triton, and
was for some years the tracker most PC music was made in. Its XM file took the module past the
Amiga's limits: up to 32 channels, samples of sixteen bits, and instruments that are more than a
sample, with several samples across the keyboard and envelopes for volume and for place.

An XM file, and a MOD file of more channels than the Amiga has, is played as FastTracker 2 played
it: the replayer and the mixer are FastTracker 2.09's, by way of ft2play's port of them to C. The mixer
works in whole numbers, with FastTracker's interpolation between one sample and the next and its
ramping of volumes, both switched on as they were when the tracker was new, and it places each
instrument between the speakers where the module says. FastTracker itself reads no more than 32
channels and only an even number; files from later trackers have any number, and are played the same
way. One thing is done as those later trackers did it. A sample can be in stereo in a file of theirs,
its two sides one after the other, and to FastTracker that is one long sample: here the two sides are
played together, the left side on the left and the right on the right, each as loud as the channel's
place between them makes that side, as OpenMPT plays them. Such a file's own pre-amp, which ModPlug
Tracker and OpenMPT keep at its end, makes it louder or quieter, as it does in OpenMPT, against
the usual one of the way it asks its channels to be added up by; the ways themselves, which turn a
whole tracker's files down together (see IT, below), are not followed, so that the middle file of
each is as loud as the middle one of FastTracker's own. And they have
commands of ModPlug Tracker's, which are played as OpenMPT plays them: Y, to sweep a channel from
side to side, with X5 to choose its wave; and Z and the command after it, which send a macro, and
that is how such a file sets a channel's filter, at once or a little at a time over a row. The
filter is OpenMPT's, of two poles, put into FastTracker's mixer between a sample and its volume,
and a macro that is for anything but the filter is left out and said to be. And such a file is
heard through its plug-ins, where they are OpenMPT's own, as an IT file of the same trackers is: a
voice goes to its instrument's plug-in, or else its channel's, in FastTracker's whole numbers, and
the plug-ins are given it at the level OpenMPT plays an XM file. Set beside libopenmpt, the 107
files to hand that send something through a plug-in agree in spectrum to 0.993 for the middle
one, where without the plug-ins it was 0.982. X99 puts a channel in ModPlug's own reverb, and X98
takes it out, as in an IT file of theirs (see MPTM, below); of the 16 such files to hand, how alike
their two sides are to libopenmpt's went from 0.31 to 0.97 for the middle one. That is for a file
that gives itself away as another tracker's: by saying so, or,
where it says FastTracker as ModPlug Tracker's files do, by a name padded with nothing instead of
spaces or by what ModPlug Tracker writes after all that FastTracker reads. FastTracker lets any
letter be typed for a command, and in a file of its own a letter it has no command for is
nothing, as it was to FastTracker: often a mark for a demo to keep time by. A tune ends where it
would play a row it has played before. `siday --raw file.raw tune.xm` writes
what ft2play writes to a file, stereo samples as it has them, and the two agree to the sample.

## MTM, DTM and AMF — MultiTracker, Digital Tracker and DSMI

An MTM, a DTM or an AMF file is not played as its own tracker played it. MultiTracker was a tracker
for the PC and the Gravis Ultrasound, Digital Tracker one for the Atari Falcon, and AMF is what
DSMI, the engine of the Dual Module Player and of many games, made of any module before it played
it. This player has no replayer of any of them. But all three are ProTracker's kind of module
with more channels, and FastTracker 2 plays that already, for a MOD file of eight channels. So each has a loader that reads it into the shape FastTracker holds a
module in, and FastTracker's replayer and mixer play it: with its slides, its vibrato, its arpeggio
and its way of placing a sound between the speakers, which are near to these trackers' own and are
not theirs. The replayer does five things for such a file that it does for no XM or MOD file. A
channel has a place between the speakers and stays where a command puts it, where FastTracker gives
a place to each sample. A sample plays at the rate it says it was recorded at, whatever the note
and whatever slides it. Setting the speed in an MTM file puts the tempo back to 125, and setting
the tempo puts the speed back to 6, which was MultiTracker's way and no other player's; a file that
sets both on one row was written for those other players, and is played their way. A loop
inside a pattern does not leave the next pattern starting part of the way down, a mistake of
FastTracker's that its own files were written around and these were not. And a vibrato in a DTM
file is a quarter as deep as the same number makes it in a MOD file: that is how OpenMPT plays
these files and not how libxmp does, and it was settled by ear, on a tune whose composer had
written the shallowest vibrato there is and still got a note that wavered out of tune. (Slides
in a DTM file were heard both ways as well and are left as they were, on every tick of a row but
the first: OpenMPT slides on the first too, and a tune whose sweeps go up a fifth and stay in key
this way went out of key that way.) What FastTracker cannot be
told is left out: Digital Tracker 2.04 set how loud a channel was on each side, of which the place
between the speakers is kept and the loudness is not; DSMI's surround sound is the middle. A stereo
sample in a DTM file is played in stereo, as in an XM file of a later tracker's.

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

## S3M — Scream Tracker 3

Scream Tracker 3 is Sami Tammilehto's, Psi of Future Crew, and came out in 1994, after the group
had used it for the music of its own demos. It was the first tracker many PC musicians had with
more than four channels and a card that could do them justice: sixteen channels of samples, and
beside them, for those who wanted it, the nine FM voices of the AdLib card.

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
played together, on a Gravis Ultrasound in a file that is in stereo the left side on the left and
the right on the right, as the card's voices each have a place between the speakers; on a Sound
Blaster, whose channels are each to one side, or in a file in mono, they are mixed into one. And they have
three commands that Scream Tracker passes over and the trackers after it play, in an S3M file as
in any: M, which sets a channel's volume, N, which slides it, and W, which slides the volume of the
whole tune. Those are played, as OpenMPT plays them, in a file that Scream Tracker did not save; in
one that it did save they are nothing, as they were to it and to whoever made the tune there. So
are three more, on the Gravis Ultrasound, whose voices each have a place: X, which puts a channel
somewhere between the speakers, P, which slides it, and Y, which sweeps it from side to side. The
card has sixteen places, and the channel is put at the nearest of them; the card's sides are less
far apart than OpenMPT's, and of 159 such files to hand set beside libopenmpt, how alike the two
sides are rose in 70 and fell in 14 (from 0.54 to 0.71 for the middle one). Two
more of theirs are not played on Scream Tracker's cards, and such a file says so: Z, which sets a
filter that neither card has, and S99, which puts a channel in ModPlug's own reverb (played in an
IT, MPTM or XM file of those trackers; ten S3M files to hand ask for it).
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

## STM and STX — Scream Tracker 2, and its Music Interface Kit

An STM file is from Scream Tracker 2, the same author's tracker of 1990, from when no sound card
did any mixing: four channels, 31 samples of eight bits, and the program adding the four
together itself, a sample at a time, for a Sound Blaster or a converter on the printer port. It is
played by a port of st2play, which Sergei Kolzun made from the program itself and calls very
accurate, and which is the whole of how Scream Tracker 2 made sound, since its replayer and its
mixing are one loop. The four channels are added into eight bits with nothing between one sample of
a sound and the next, a channel at its loudest has six of those bits, and there is one channel of
output: that is how an STM file sounded, rougher than anything else here, and it is the same in
both ears. It is made at 23,863 samples a second, the highest rate Scream Tracker 2 could be set to
mix at, and brought to the player's rate as an S3M file's Sound Blaster is. The rate is part of the
tune, a little: a tick is a whole number of those samples.

st2play has the replayers of three versions of the program, 2.21, 2.24 and 2.3, and they are not
alike. Set beside the first, 2.3 plays a fifth of a semitone higher and a fiftieth faster, its
vibrato is half as deep, it goes on with the last vibrato or the last slide to a note when it is
given one with no value, and its arpeggio plays three notes, where 2.24's plays two and 2.21 has
none. A file does not say which of them it was made with: every one says 2.21, which is the
version of the file's layout. It is 2.3 that is ported, the last, because that is what the files to
hand ask for. Eight have arpeggios, and in five of them those are chords of three notes, written as
a MOD's are; four carry a vibrato on with no value; and eleven have samples at 8,192 a second, which
is 2.3's number for its C, where the earlier versions' was 8,448. A tune made with an earlier version is played by
2.3 all the same, as it was in its day by anybody who had 2.3.

Much of what Scream Tracker 2 does is its own, and is kept. A slide's value counts in tens of the
units other trackers use. A slide to a note that is let go before it gets there is there at once.
A place in the list that a row asks for is gone to when the pattern ends, and not before. A tempo
has two halves, the ticks to a row and a number that makes each tick longer by an amount that
depends on the first. A volume over 64, which a row can ask for, is silence. An arpeggio on a B
reads past the end of the table of notes, and plays what it finds there, which st2play's author
wrote down from the program's memory.

The port agrees with st2play to the sample, over half an hour of each of the 63 STM files to hand,
on 62 of them, with st2play given empty patterns where a file has none. That is one of three
things done here that st2play does not do, each for what a file means. Scream Tracker 2 seems
not to have saved the empty patterns after a tune's last, for eleven of these files have such a
pattern in their lists: it is played as a pattern with nothing in it, so that the notes before it
ring on, where st2play plays whatever its memory holds and OpenMPT passes the place over. A number
in the list that is neither a pattern's nor a mark of the end is taken for the end, and nothing
after the first end of a list is played: one file has such a number, and it is the one that
differs. And a sample that is to go round from past its own end goes on into what follows it in the
file, the next sample, which is what OpenMPT's authors found Scream Tracker 2 to do: there are 21
such samples, most of them over by one byte. st2play brings the end in, and `siday --raw file.raw tune.stm`, which writes what
st2play makes, a sample for each of its own, does so too. A sample with no volume of its own is
not loaded, as in st2play, and its notes are silence. One file named for the format is something
else, and is refused. The files are as loud as XM files are, by measure: the middle one of each is
the same.

An STX file is a Scream Tracker 2 tune made ready for the Scream Tracker Music Interface Kit, the
library Future Crew gave out in the early 1990s for putting their tracker's music into other
people's programs. The kit's papers call it a beta of Scream Tracker 3's format, and it looks like
one: an S3M file's header and samples, and its way of packing a pattern a row at a time with only
the channels that have something in them. What is packed is an STM file's, though, for the kit
came with a converter, STM2STX, and its music was written in Scream Tracker 2: four channels,
Scream Tracker 2's commands under its letters, nothing remembered from one command to the next,
and a tempo in two halves. The kit's own replayer has never been published. OpenMPT and Schism
Tracker play these files as the STM files they were, and so they are played here: read back into
one, and played by Scream Tracker 2's replayer like any other. (libxmp plays them with Scream
Tracker 3's ways instead, under which a command with no value goes on with the last one's, and
the tempo has one half.)

So the check is of the reading. The two files to hand, one of each of the converter's two
versions, agree to the sample with st2play, for an hour of each, when st2play is given the STM
file that a separate script makes of them. And OpenMPT plays that STM file as it plays the STX
file itself: every voice at the same pitch and volume on every tick. An STX file has room for
what an STM has not, more channels, more samples, longer ones and ones of sixteen bits; the
converter made none of those, and a file that has them and uses them says so. A volume over 64,
which Scream Tracker 2 would play as silence, is taken for 64, as OpenMPT takes it.

## IT — Impulse Tracker, and ModPlug Tracker after it

Impulse Tracker is Jeffrey Lim's, from 1995, and was added to until 1999. It looks like Scream
Tracker 3, on purpose, and does a great deal more: instruments in the sense FastTracker has them
and beyond, and what no tracker before it had, a note that does not stop when the next one
starts. Years later its author published its source, which is how a replayer like this one can be
the tracker's own.

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
of those trackers can have plug-ins too, and is heard through them in the same way: see XM.)

The fourth is the filter itself. ModPlug Tracker had a filter of its own before it had Impulse
Tracker's. It is the same kind of filter, but it rings half as much for the same resonance, and it
goes by other rules. A note starts with it only if its cutoff is below the top; a macro or an
envelope that sets it puts it on; and once on, it stays on until the next note. So a filter set
wide open still takes the top off the sound, at five kilohertz, where to Impulse Tracker a filter
wide open is no filter at all. OpenMPT kept that filter for the files that were made with it. It
took up Impulse Tracker's in its version 1.20, and only for a file that asks to be played as
Impulse Tracker would play it; and it uses its own curve even then if the file asks for ModPlug
Tracker's wider range of cutoffs, which Impulse Tracker's has not. So a file is played here with
the filter it was made with. Which that is is told by the signs OpenMPT goes by (who the file says
made it, the version that last saved it, and the ways of playing it lists), and of the 21,189 IT
and MPTM files to hand that are read at all, there is not one where the two choose differently.
That filter is heard in 1,236 of the IT files and 215 of the MPTM files.

With it come some smaller things of ModPlug Tracker's, each for a file that tracker or OpenMPT
made. An instrument's filter can be the other way up, letting the high through and not the low,
and it can be moved at random from one note to the next, the cutoff or the resonance or both, by
as much as its instrument says. (An older file goes on adding a note's random move to whatever a
command sets the filter to while the note lasts; a newer one does not.) And three things about
envelopes are done ModPlug Tracker's way in a file that does not ask for Impulse Tracker's: in a
file from before OpenMPT 1.20, an envelope for pitch or for the filter goes round its loop a tick
sooner; an envelope that is to carry on from the note before does not, after a note whose key was
let go, if the row names the instrument; and a slide to a note starts the envelopes again if the
instrument has none for volume. (OpenMPT stops making the first of those changes at the first
instrument that has anything random in it, in a file from before its version 1.17.02.50, and
leaves the instruments after it as they are. So does this.) And a sample that ends where it is
loud would click, and both mixers let its last level die away instead; ModPlug Tracker's mixer,
which is OpenMPT's still, sixteen times more quickly than Impulse Tracker's, and so it is here for
these files. It changes most of them a little, and of four hundred it brings fifteen audibly
nearer libopenmpt, and none further.

And an older OpenMPT meant something else by four of a file's numbers, which it changes when it
reads such a file, so that the file sounds as it did. A sample's own vibrato that says nought for
how fast it comes in comes in at once, in a file from before 1.20: to Impulse Tracker nought is
never, and such a sample would have no vibrato at all. How far a note's place between the speakers
is moved at random is a quarter of what the number says, and how far higher notes are sent to one
side a half or a quarter, in a file from before 1.26; and the random move of a note's loudness is
counted out of 64 and not out of 100, before 1.20. Of 300 such IT files set beside libopenmpt, 37
were nearer to it in where their sound sits between the speakers and 6 further, which with
anything random is as near as two playings of one file come.

How loud such a file is follows OpenMPT only as far as that keeps it about as loud as every other
tune here, which comes first: a loud tune is to be loud whatever kind of file it is, and a quiet one
quiet. A file's own pre-amp, the composer's, is followed. OpenMPT has also had several ways of
adding a song's channels up, and a file says which it was made for. The oldest, ModPlug Tracker's
own, turns a song down by the number of channels it has, by a table, and leaves such files some
8 dB below the rest; and over the files to hand, the fewer their channels the louder it leaves them
beside the others. So that way is not followed, and the turning down that the player this one is
ported from gives ModPlug Tracker's own files is taken out again. The ways of OpenMPT 1.17, of
which one is twice as loud as Impulse Tracker and puts a channel that is to one side at no more
than one in the middle, are followed, and measured so they leave their files as loud as the rest.
Measured over three hundred ModPlug Tracker and OpenMPT files and three hundred others, the middle
file of every way is now within about a decibel of the middle IT file, and of the middle XM file.

All of that was checked by setting every sounding channel's filter beside libopenmpt's on every
tick of a file's first minute: whether it is on, and the three numbers it is worked by. Of the 215
MPTM files, 186 have nothing random about their filters, and in 179 of those the two are the same
on every tick, give or take one step of 512 in an envelope, which the two round differently. Of
300 of the IT files taken at random, 295 have nothing random; the two players go through the same
rows tick for tick in 291 of them, and in 279 of those the filters are the same on every tick. What
is left is mostly envelopes that carry on, or do not, about a slide to a note. What is heard was set beside libopenmpt
before and after: of the 300 IT files 139 are nearer and 9 further, and of the 215 MPTM files 86
and 5; the spectrum of the middle IT file agrees to 0.981 where it was 0.975, and that of the
middle MPTM file to 0.994 where it was 0.991. A file with a filter moved at random cannot be set
beside anything, since no two playings of it are alike.

A file Impulse Tracker
made is played as Impulse Tracker played it, and `--raw`
writes every file so, to set beside it2play. The filter is the one place where the web
player and the Mac's do not agree to the last bit: each asks its own maths library for a power of two.

Some IT files, and some S3M files, were packed whole by MMCMP, Emmanuel Giasson's Music Module
Compressor for DOS, which knew a module's samples from the rest of it and packed each as the sound it
is. Such a file is unpacked before it is read, as Teemu Suutari's ancient unpacks it, and agrees with
it to the byte: the four IT files to hand then play as it2play plays them, and the four S3M files as
st3play does, to the sample.

## GDM and PTM — BWSB and PolyTracker

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
command Impulse Tracker has room for nor its volume column can do. And three things are changed on the
way in, because Impulse Tracker alone would take them otherwise: an instrument named on a row with
no note is given as the instrument's volume, where Impulse Tracker would have played the note again;
in a tune that began as a MOD a slide of nought does nothing, where Impulse Tracker's would go on
with the last; and in a tune that began in Scream Tracker a command given nought goes on from the
last number given to any command on its channel, as Scream Tracker's did, where Impulse Tracker's
would go on from the last of its own kind. (One tune to hand leans on that: a held note's vibrato
goes on into a fade that takes the vibrato's number.)

## ULT — UltraTracker

A ULT file is UltraTracker's, a tracker that Marc André Schallehn wrote for DOS and the Gravis
Ultrasound in the early nineties: up to 32 channels, each at any of sixteen places between the
speakers, samples of eight bits or sixteen, and ProTracker's commands under ProTracker's numbers,
two of them beside a note where ProTracker has one. Its replayer was never published, and nothing
is to be found that says what its commands did beyond their names, in FreeJack's description of
the file. So there were two ways to play one: a small player written for it, as 669 files have, or
Impulse Tracker's replayer, as for the two kinds above. A player written for it would have had
nothing of UltraTracker's to be made after, and would have been ProTracker's commands written out
once more; and every one of those commands is one Impulse Tracker has. So it is Impulse Tracker's
replayer, with "old effects" on, which is where OpenMPT and Schism Tracker put these files too.

Four things do not go over as they stand. A note has two commands, and Impulse Tracker has room for
one beside its volume column: the second goes in that column when it is one the column can do (a
volume, a place between the speakers, a slide of volume, some slides of pitch, and where the column
can only do nearly what is asked, it does the nearest), and a command for the whole tune, its speed
or where it goes next, moves to a channel of the row that has room. What is left with nowhere to
go is left out, and the file says so: that is 31 notes, in five of the files to hand. A slide to a
note goes on by itself in UltraTracker, row after row, until it gets there or another note comes,
and the replayer has been given that for these files alone. A sample goes round for as long as its note
is held, and UltraTracker can let a note go, so that the sample plays on to its end: that is
Impulse Tracker's sustain loop and its note-off. And volumes are of 255, where Impulse Tracker's
are of 64.

Where nothing says what UltraTracker did, a choice was made, mostly OpenMPT's. Two speed commands
beside one note are a speed and a tempo, and both are kept; the same command twice is played once.
A slide of volume with nothing to slide by goes on with the last. A slide of volume by fifteen is
one by fourteen, because Impulse Tracker's slide by fifteen starts a tick early. An instrument named
with no note is that instrument's volume, as in the files above, where OpenMPT changes the sample
under the note that is playing; and here, where two commands stand beside it and the volume column
is wanted for one of them, the replayer is told to make that of it itself, and not to start the
note again as Impulse Tracker would if the note were over. Three files do this all through, to
move a sound from side to side while it dies away. Three things are not played, and a file that asks for one says so:
a note played without its sample's loop, the command that sets how deep vibratos are to go from
then on, and a note that is to start further into its sample than Impulse Tracker's command can
reach, which starts as far in as that reaches. And in a file of before UltraTracker 1.4 the volumes
were not evenly spaced, and are played here as if they were, as everybody plays them.

All 126 files to hand are played. Every channel's pitch and volume was set beside libopenmpt's on
every tick of each, to its end or for two minutes: of 769,384 ticks they are alike on 729,705, 54
files are alike on every tick and 42 more on all but one in fifty. The rest come down to three
things, and to the choices above. OpenMPT plays these files on its own replayer, whose vibrato and tremolo are not shaped as
Impulse Tracker's are. Its ticks drop the part of a sample that theirs come to, as for 669 files, so
that a tune at any tempo but 125 drifts. And it loses a speed or a tempo that shares a note with
another command in the first channel: the two files it is furthest from here are the two it plays
at 125 beats a minute where they ask for another tempo. What is heard was set beside it too, for
the first minute of each: the spectrum and the loudness over time agree to 0.999 for the middle
file, and to 0.945 and 0.859 for the file a tenth of the way up from the worst. The files are made
as loud as XM files are, by measure.

## MDL — Digitrakker

An MDL file is from Digitrakker, which Prodatron wrote for DOS in the middle of the
nineties; its files came in three kinds, from its version 2 to its version 3. A tune has up to 32
channels, each at any of 128 places between the speakers, and instruments as FastTracker 2's are:
a sample for each range of notes, with envelopes for the volume, the place and the pitch, a fade,
and a vibrato of the sample's own. The envelopes are not the instrument's but the tune's, 64 of
each kind, which the instruments name and a command can change between. The samples can be kept
packed, each byte as its difference from the one before in as few bits as it needs. And a note has
two commands, in two columns: the first for its pitch (slides, vibrato, arpeggio) and the second
for its volume (slides, tremolo, tremor, striking the note again), and the rest in either.

Digitrakker's replayer was never published. OpenMPT plays these files on its own replayer, as it
plays an IT file, and has been taught what Digitrakker does otherwise; libxmp plays them as it
plays an XM file, and has been taught less. So there were two ways to play one here: a small player
written for it, which would have had nothing of Digitrakker's to be made after, or Impulse Tracker's
replayer, as for the ULT and GDM files above, with what OpenMPT does otherwise given to it. Every
command of Digitrakker's has its like among Impulse Tracker's, and its instruments are Impulse
Tracker's with less in them, so it is the second, and the file is read as OpenMPT reads it. The
replayer is told, for these files alone:

- that a note's pitch is a period, as on the Amiga, but one that a sample's rate does not change: a
  slide moves every sample's notes by as much. The periods are Scream Tracker's, cut to whole
  numbers, and a slide, a vibrato, an arpeggio and an envelope of pitch each move or multiply the
  whole number, as OpenMPT does;
- that vibrato and tremolo go as ProTracker's do, on a wave of 64 steps that does not move on on a
  row's first tick;
- that a note cut short (ECx) is turned down to nothing and plays on, so that a volume brings it
  back, which one tune uses as a gate; that EC0 cuts at once, and ED0 holds nothing up;
- that a note whose key is let go fades, whatever its volume envelope does, and that the end of
  that envelope neither fades the note nor ends it; and that fades are finer than Impulse Tracker's;
- that an envelope of pitch goes six semitones either way at the most, where Impulse Tracker's goes
  sixteen;
- that the vibrato a sample has of its own comes in over so many ticks, as OpenMPT has it;
- that EFx, which starts a note further into its sample, counts in bytes, which in a sample of
  sixteen bits are half as many samples, and moves a note that is already playing;
- that an instrument named with no note keeps the volume of the sample that was playing, and one
  named beside a key let go gives the volume of its sample for the channel's last note; and that a
  sample may have no volume of its own, and leave the channel's as it was;
- and that a slide to a note with no note beside it goes on with the last slide only until it gets
  there.

What does not go over as it stands is the two commands. Impulse Tracker has room for one, and its
volume column: the second goes there when it is one the column can do and the note has no volume,
and otherwise OpenMPT keeps the one that matters more and leaves the other out. Here less is left
out. A place between the speakers, or a fine move of it, that has no room is kept beside the cell,
and the replayer puts the channel there when it reads the row; a command for the whole tune moves to
a channel of the row that has room, as for ULT files. OpenMPT puts the part of EFx beyond what
Impulse Tracker's Oxx reaches in the volume column, where the note's volume would be, so that a note
started far into its sample is played at the loudest whatever it asks: here that part is kept beside
the cell too, and the note has its volume. And a slide to a note or a vibrato that only goes on,
beside a slide of volume, is Impulse Tracker's Lxy or Kxy. What is left with nowhere to go is left
out, and the file says so: that is 291 notes, in five of the files to hand, nearly all of them in
one, which strikes a note again while its volume slides on.

The slides of volume are Digitrakker's own: by 256ths of the whole a tick, four times as fine as
Impulse Tracker's, and as fast as 223 of them. OpenMPT takes a quarter of each, to the nearest of
Impulse Tracker's below and no more than fifteen, so that its slides of less than a quarter become
slides that go on with whatever slide the channel had before; and one composer swells notes in from
nothing that way, which OpenMPT then leaves silent or swells four times too fast. libxmp's reading
of the same commands is Digitrakker's, by 255ths. Here a slide that Impulse Tracker's can do is
that, and the replayer does the others as Digitrakker does them, keeping the part of the volume
finer than Impulse Tracker's 64ths for as long as nothing else sets it. A tempo below 32, slower
than Impulse Tracker goes, is a tune's way of stopping: a tick of a tempo of 1 is two and a half
seconds, and with the speed of 255 that goes beside it a row is ten minutes. All seven files to
hand that set one set it on the last place of their list, so the song ends there, after the row,
where OpenMPT reads it as a slide of tempo and plays on very slowly. Two commands are not played,
and a file that asks for either says so: E8x, which changes how a sample loops, and E5x, which tunes
a sample afresh; and 9xx, which changes a note's envelope to another of the tune's, turns on the
instrument's own, as OpenMPT has it, and the file says that too.

Where nothing says what Digitrakker did, the choice is OpenMPT's, but in one thing. A note that
names an instrument the file does not have plays nothing, and leaves the note before it as it was;
OpenMPT plays it on the sample that was playing, at the new note's pitch. Eleven files have such
notes. (libxmp's notes on how trackers differ have a column for Digitrakker 3.2, found by trying it,
but for MOD files and not its own: there a note on an instrument that is not there cuts the note,
and a note with no instrument has its instrument's volume again. The second is not how these tunes
are written. One sets a quiet volume on a note's first row and repeats the note bare on the rows
after, which as it would have it would be loud from the second.)

All 148 files to hand are played. Every sample is as libopenmpt reads it, packed or not, to the last
byte of its sound and its loop. Every channel's pitch and volume was set beside libopenmpt's on every
tick of each, to its end or for fifteen minutes. Read as OpenMPT reads them, before the choices above
that are not OpenMPT's were made, they were alike on 1,917,068 ticks of 1,919,629: 98 files on every
tick, and all but three of the rest on all but one in fifty. What was left is where a sample ends a
tick sooner in one than in the other, at a note so short that it ends on the very tick the next row
starts, and the eleven files with notes on instruments they have not got. As they are played here,
82 files are alike on every tick, and the rest differ where the choices above make them. What is heard was set beside libopenmpt too, for the first
minute of each: the spectrum agrees to 0.992 for the middle file and the loudness over time to
0.974, and to 0.907 and 0.737 for the file a tenth of the way up from the worst. The files are made
as loud as XM files are, by measure.

## J2B — Jazz Jackrabbit 2 and the Galaxy Sound System

A J2B file is a piece of the music of Jazz Jackrabbit 2, Epic MegaGames' platform game of 1998. The
game played its music with the Galaxy Sound System, Carlo Vogelsang's sound engine, whose modules
were not written in a tracker of its own: they were written in the trackers of the day and turned
into Galaxy's format by a converter, mod2j2b. That format is a RIFF file, as a Windows sound file is,
with the song, each pattern and each instrument (with its samples inside it) in parts of their
own, much as an IT file has them. It came in two kinds, an older one marked "AMFF" and a newer one
marked "AM  ". The game keeps each file packed with zlib, Jean-loup Gailly's and Mark Adler's
library of Phil Katz's DEFLATE, behind a header that begins "MUSE" and gives the file's length, the
length the music unpacks to, and a checksum of what is packed.

So a J2B file is unpacked first. DEFLATE is here in Swift of its own (`Packers/Inflate.swift`), made
after the decompressor in Teemu Suutari's ancient and the two RFCs that describe DEFLATE and zlib's
stream, for siday uses no library of the system it runs on. A file is refused unless its header
gives its own length rightly, the checksum of what is packed is right, what is packed unpacks to
exactly the length the header says, and zlib's own checksum of what it unpacked to (Mark Adler's)
is right. The unpacking was set beside the system's own zlib on all 24 files to hand and on 5,760
streams made with zlib at every level and in every way it packs (stored, in the codes DEFLATE fixes
and in a block's own codes, with flushes between blocks, from 0 bytes to a megabyte): every one
came out byte for byte the same. On some 21,000 damaged copies of those streams, flipped in a few
bits or cut short, it refused just those that zlib refuses, and where both took one it made the
same bytes.

Galaxy's replayer has never been published. OpenMPT reads these files into the shape of an IT file
and plays them as it plays an IT file, with all of Impulse Tracker's ways it knows; and so they are
played here, by Impulse Tracker's replayer, read as OpenMPT reads them and keeping time as OpenMPT
does. The commands are ProTracker's and FastTracker's, each of which has its like among Impulse
Tracker's but two (FastTracker's Kxx, which lets go of a note's key after so many ticks, and Lxx,
which moves along an envelope): a file with either would say they are left out, and none of the
game's has. A volume of 127 in the newer kind of file is one of Impulse Tracker's 64, and a place
between the speakers one of its 64, which in a file that asks for an odd place of 128 is the
nearest. The instruments are Impulse Tracker's: a sample for each note, envelopes for the volume, the
pitch and the place, a fade and a vibrato of the sample's own; the game's files have one sample to
an instrument, and no envelopes, fades or vibratos.

The one thing OpenMPT does otherwise than Impulse Tracker that these files are heard to need is
the vibrato. Their vibratos are played with Impulse Tracker's "old effects", which on a vibrato's
first tick bend the note by the wave where it is and only then move along it. A note struck on a
channel takes the vibrato back to the start of its wave in OpenMPT, and so the next vibrato starts
unbent; in Impulse Tracker the bend of that first tick is whatever the last vibrato left off at.
The replayer is told to do as OpenMPT does for these files (`IT2Module.playsAsGalaxy`), and for no
others.

All 24 files to hand are played, none with anything left out. Every sample is as libopenmpt reads
it, to the last byte of its sound, its loop, its volume and its rate. Every channel's pitch and
volume was set beside libopenmpt's on every tick of each, to the end of its song: all 145,348 ticks
are alike, the rows coming in the same order and lasting as long; on 98.5% of a voice's ticks the
rate is the same to the hertz (and on 99.97% within one, which is the rounding of the two dumps),
the volume on 99.99%, and the place between the speakers on 98.2%, the rest being one file's
voices in surround, which the two players mark differently. The songs last as long as libopenmpt
says they do, to the second. What is heard was set beside libopenmpt for the first minute of each:
the spectrum agrees to 1.000 for the middle file and 0.999 for the worst, and so does the loudness
over time. The files are made as loud as other modules are, by measure (the middle one at −24.7 dB),
which is 1.5 dB quieter than libopenmpt plays them.

## DMF — X-Tracker

A DMF file ("Delusion Digital Music File") is from X-Tracker, a tracker for DOS by D-Lusion; the
first description of the format its makers gave out, partly in German, is dated Christmas 1993. The
format went through seven versions while the tracker was in its beta, and the eighth is the finished
tracker's (a later XTracker 32 wrote a tenth). Of the 32 files to hand, six are of the fifth
version, one of the sixth and the rest of the eighth, and their headers date them from 1994 to 1996;
some are by D-Lusion's own members, and two say they were made from other trackers' files. A tune
has up to 32 channels and above them a track of its own for the tempo; samples of eight bits or
sixteen, kept packed if their maker wished (451 of the 601 here are), with a loop that holds only
while a note's key is down; and three commands to a note, in three columns: one for its sample
(stopping it, letting its loop go, starting it again, putting it off, starting it further in,
playing it backwards), one for its pitch (slides, vibrato, arpeggio, tuning, a cut) and one for its
volume (slides, tremolo, tremor, the place between the speakers). X-Tracker's timings are its own: a
delay or a cut is in 256ths of a row, a vibrato's speed in rows to the wave, slides in 256ths, and
the tempo in quarters of a row a second, or in beats a minute by the rows to a beat that each
pattern says it has. Patterns can be longer than Impulse Tracker's: up to 512 rows, its makers
wrote.

X-Tracker's replayer was never published. OpenMPT reads these files into the shape of an IT file and
plays them on its replayer as it plays one, and libxmp's reader of them is no longer built; so here,
as for the MDL files above, Impulse Tracker's replayer plays them, read as OpenMPT reads them, with
what OpenMPT plays otherwise for them told to the replayer. OpenMPT's reading has to settle a good
deal, and how it does is followed to the letter. X-Tracker's timings depend on how fast the tune is
going, so each place in the list of patterns is given a pattern of its own, made at the speed the
tune has reached there. The tempo is made into the speed and tempo of Impulse Tracker's that come
nearest, with as many ticks to a row as can be, so that arpeggios and tremors keep their shape; the
tempo's track goes to a channel of its own, the first. Slides, delays, cuts and vibratos become
Impulse Tracker's, worked out at that speed (and cut short as OpenMPT cuts them); a slide to a note
that the command names (X-Tracker's "scratch") gets there at once; a note without an instrument is
slid to at once and not struck again; and of the three commands, the sample's is kept first, and of
the others what the volume column can take goes there and the one that matters more has the command.
What is left with nowhere to go is left out, and the file says so: 358 notes, in twelve of the
files. The replayer is told, for these files alone:

- of two commands Impulse Tracker has not, which OpenMPT keeps: a note's volume given by the
  command, where the volume column has something else (504 notes in seven files), and a note tuned
  by up to a semitone either way, which a note struck on an instrument takes away again (one file
  tunes 720);
- that the volume column's slides of pitch go up to 63 where Impulse Tracker's stop at nine, and
  that it can play a sample backwards and forwards, as S9F and S9E do;
- that a vibrato plays where its wave is on a row's first tick and moves on only after, and that
  every note struck starts its wave again;
- that a tremolo only ever turns a note down, by a share of its volume, and moves on along its wave
  after each tick but the first, so that the first two are alike;
- that a note cut short is turned down to nothing as well, so that the next note on a sample with no
  volume of its own (and many have none) is silent until it is given one;
- and that a tick lasts a whole number of frames, what is over cut off, as in OpenMPT's way of
  keeping time.

Two things are done otherwise than OpenMPT does them. OpenMPT's notes go an octave and two thirds
higher than Impulse Tracker's, and one file plays 74 of them: each is played an octave down on a
copy of its sample that plays an octave up, which is the same sound. And a slide to a note on a row
that names the note's instrument, which X-Tracker's scratch makes of every note it is on, keeps the
sample's loop. OpenMPT lets the loop go there, so that the sample plays to its end and stops, and
the note comes back a row or two later; but it does so only because the files are not IT files to it
at that point of its replayer, and the same rows in an IT file, which is what its reading makes of
them, keep the loop. One file's scratched bass line goes silent for a row at a time in OpenMPT, and
plays on here; one other file has a note like it.

All 32 files are played. Every sample is as libopenmpt reads it, packed or not, to the last byte of
its sound and its loop, and every pattern for every place in the list is the same, command for
command, as OpenMPT's reading of it. Every channel's pitch, volume and place was set beside
libopenmpt's on every tick of each file, to its end or for fifteen minutes: they are alike on
927,707 ticks of 938,569, and 22 files on every one. Of the rest, 5,728 are in the two files of the
loop kept above; most of the others are long slides of pitch, which here move a whole number of
samples a second each tick, as Impulse Tracker's do, where OpenMPT's keep finer steps, so that after
a long slide to a low note the two are a few cents apart; and a few dozen are a sample that ends a
tick sooner in one than the other. What is heard was set beside libopenmpt too, over the whole of
each file: the loudness over time agrees to 0.999 for the middle file and 0.992 for the worst, the
spectrum to 0.999 and 0.994, and left and right to 0.999. The files are made as loud as IT files
are, by measure.

## MPTM — OpenMPT

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
when its key is let go. A filter can let the high through instead of the low, and can be moved at
random from note to note; and it is OpenMPT's own filter unless the file asks for Impulse
Tracker's (see above, where the same is told of an IT file). An instrument can be tied to a tempo,
and is then played as much higher or lower as the song is faster or slower than that. And a file can ask
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
such file. Of the notes sounding in libopenmpt 99.98% are sounding here with the same patch; their
pitch is the same number in 91% of ticks, within two of the chip's steps in 99.2% and within two
hundredths in 99.8%; the level of the operator that is heard is within one step of 63 in 99.6%.
Much of what once differed was not the chip's doing but the replayer's, and has been made
OpenMPT's way for these files, for samples as much as for the chip: a sample's own vibrato, which
OpenMPT reads a step before Impulse Tracker does and rounds otherwise; a vibrato, which OpenMPT
starts from the top of its wave with every note struck, and Impulse Tracker only with a note on its
own row; and OpenMPT's finetune command, which bends a channel's notes by up to so many semitones
as the instrument says. What is left is mostly a step of rounding, and a note given another of the
chip's voices than OpenMPT gives it. The chip is as loud against the samples as OpenMPT makes it.

Half the MPTM files to hand use plug-ins. A plug-in is somebody's program, and none can be run
here; but OpenMPT has a few of its own built in, which it plays on any machine, and four files in
five that use plug-ins use only those: an echo, two reverbs, a chorus, two flangers, a compressor,
a distortion, an equaliser and a gargle, all made after the effects that came with Windows, and the
echoes of two Amiga trackers, DigiBooster and Symphonie. Those are here, each carried over from
OpenMPT's own. All but the last were set beside it: given
the same sound and the same settings (every setting that the files to hand keep among them), each
gives what OpenMPT's class gives, to the last bit, when that is built to round as Swift does. (The
one built-in that is not here is its LFO, which makes no sound of its own and is there to move
another plug-in's settings: in the files to hand, somebody else's plug-in every time.) They
are wired as the file wires them. A voice goes to the plug-in of its instrument, or failing that of
its channel; what a plug-in makes goes to the listener or on to another plug-in; a plug-in can be
put on the whole sound; and how much of what it was given is heard beside what it makes, how the
two are put together and how loud, are the file's to say. A tune can change a plug-in's settings as
it plays, by a kind of note that is for nothing else or by a macro, and that is done; a change slid
over a row is made a little at each of its ticks. A plug-in that is not OpenMPT's own is left out as
OpenMPT leaves out one it cannot find: what was sent to it is heard as it is. An instrument that is
nothing but such a plug-in is not heard, and a file whose notes are, half or more, for such
instruments is refused.

ModPlug Tracker's mixer had a reverb of its own, which is not a plug-in, and which OpenMPT keeps:
S99 puts a channel's notes in it and S98 takes them out. It is here, carried over from OpenMPT's,
and set beside it as the plug-ins were: given the same sound, in every one of its twenty-nine
rooms and at four rates, it gives what OpenMPT's gives to the last bit. It is played in an MPTM
file, and in an IT file of ModPlug Tracker's or OpenMPT's (Impulse Tracker has no S99, and in a file
it saved the command is nothing). Of the 196 such files to hand, the sound of 78 comes nearer to
libopenmpt's by its spectrum and 2 go further, and their two sides come nearer in 109 and go
further in 9. (OpenMPT can also put every channel in the reverb, by a setting of its player's;
that is the listener's to choose, not the file's, and is not done here.)

And an instrument can be tuned to a scale of its own: a temperament, twelve steps to the octave
that are not quite equal, or a scale with more or fewer steps than twelve (nineteen, twenty-two,
twenty-four), or with no octave in it at all (eleven steps to an octave and a fifth). Such a scale
gives each of its notes a ratio to middle C, and has so many "fine steps" between a note and the
next. OpenMPT plays a note of a tuned instrument in a way of its own, which has nothing to do with
how it plays any other: the pitch is not a rate that slides move, but is worked out afresh from the
note and how many fine steps it has been taken from there. A slide up or down goes so many fine
steps a tick, a slide to a note so many a row, an arpeggio goes by the scale's own notes, the pitch
envelope by fine steps, and a vibrato moves the pitch by up to a fortieth either way. That is done
here as OpenMPT does it, with the scale's pitches worked out in OpenMPT's own arithmetic, and set
beside libopenmpt tick by tick: in the nine files to hand with tuned instruments, the notes of
those instruments are within a cent of it on 99.95% of their ticks or more, and the rest is one
tick, where a song comes round to its start. Of 700 files, 699 are played; one is refused for
keeping its samples in other files. And a file that is played with something left out says what,
a sentence for each kind of thing.

There is a difference of another kind, which no list of features covers. OpenMPT plays these files
in its own way and not in Impulse Tracker's wherever the two differ, and the file says which of
some hundred and forty small matters it wants played which way. A handful of those are followed
here, where they decide the tempo or where a tune goes next, and the one that chooses between
Impulse Tracker's vibratos and tremolos and OpenMPT's own (a file in four asks for OpenMPT's: on
ProTracker's wave, begun a quarter of the way along and the other way about, with a sample's own
vibrato that comes in by a sweep and moves by a share between two of the slide tables' steps); and
OpenMPT's ways with a sample's own vibrato and a vibrato's start where the file asks for Impulse
Tracker's are OpenMPT's too. So is the one that keeps a note's pitch as a period, a whole number,
and not as a rate in hertz, which is how OpenMPT played a song before its version 1.24 (or before
1.30 for a song without linear slides), and still plays a file made then: one file in ten. A high
note's period is a small number, so its pitch is a little out, and a slide or a vibrato moves it in
steps of a whole period, which can be several cents. Set beside libopenmpt tick by tick, the pitch
of those 73 files is within a cent of it on 99.7% of their ticks, where it was 45%. And so is
the one for an instrument named on a row with no note. Impulse Tracker starts the note again with
it; OpenMPT, unless the file asks for that, starts nothing, and a note that is playing goes over to
the new sample from where it was, as a ProTracker tune swaps its samples. Four files in five ask
for OpenMPT's way, and in ten of them it is heard. And so is the one for SCx, the cut, which in
OpenMPT's own way (a file in four) turns the note down to nothing and leaves it playing, so that a
volume on a later row brings it back. And so are those for a retrigger and a tremor, which in
OpenMPT's own way (four files in five) count the channel's ticks from its last note, across rows,
and a retrigger strikes a note again even once its sample has ended. And with "compatible Gxx",
a slide to a note of another instrument's sample takes that sample, and starts the note. For the rest this is Impulse Tracker's replayer, and the file gets
Impulse Tracker's answer. What that comes to was measured against
libopenmpt, OpenMPT's own player as a library. What is read from each of 625 files is the same
as what libopenmpt reads, but for a fade and a place between the speakers that the extras give
more finely than an IT file's instrument can hold. Where the tune is on every tick, and how many
frames the tick lasts, is the same for ten minutes or to the song's end in every one of them, and
in the 67 with FM that have been played since: 692 files in all. (One was out for a long time: a
tune made as a puzzle, with a pattern in which every row jumps to the row before it and loops
within loops on the rows it comes back to. A row played again was taken for the tune coming
round, and the tune ended fifty seconds early. Now a row played while a loop is counting down is
the same row again only if the counts are the same too, which is how OpenMPT tells a tune's end.)
What is heard was set beside libopenmpt as it plays, plug-ins and all, by the same two
measures as above, for the first minute of each file. For the files with no plug-ins the spectrum
agrees to 0.997 for the middle file and 0.976 for the file a tenth of the way up from the worst;
for those whose plug-ins are all OpenMPT's own, to 0.994 and 0.959, where without the plug-ins it
was 0.972 and 0.894; and for those with a plug-in that is left out, which libopenmpt leaves out
too, to 0.997 and 0.979. The files with FM come to 0.984 and 0.957. The rest of the difference is
a pitch that OpenMPT rounds where Impulse Tracker does not, and whatever an instrument does at
random.

## MT2 — MadTracker 2

MadTracker was a tracker for Windows by Yannick Delwiche, from the late nineties into the 2000s, much
used for the trance and the dance music of its day: up to 64 tracks; instruments
with envelopes for volume, place, pitch and a resonant filter, which do what Impulse Tracker's do;
samples of eight bits or sixteen and in stereo, which can be tied to the beat; beside a note,
FastTracker's commands and Impulse Tracker's both, and a few of its own; eight tracks of drums laid
out as a drum machine's are; and on each track effects of its own, VST plug-ins, and envelopes drawn
over a pattern for any setting ("automation"). Its player has never been published, and nor has its
format. OpenMPT reads the files (the loader is Olivier Lapicque's, from ModPlug Tracker's days), and is
the only other player that does: nothing else is to be found, libxmp and Schism Tracker included, and
nothing of MadTracker's own about the format beyond the names that OpenMPT's loader gives.

OpenMPT reads one of these files into the shape of an IT file, instruments, envelopes, filters and
all, and plays it as it plays an IT file, but for some twenty places where its player asks whether the
file is an XM or an MT2 and goes FastTracker's way for both. So it is played here as OpenMPT plays it:
by Impulse Tracker's replayer, keeping time in OpenMPT's ways (as for an MPTM file: a tick as long as
MadTracker's samples to a tick make it, at a tempo that is a fraction, or Impulse Tracker's way for a
file that sets its tempo as Impulse Tracker does), and taught those of OpenMPT's ways for these files
that the files to hand were found to need, each in a way no other file reaches. A slide of volume,
of the whole tune's volume or of place goes by its first half where both are set, as FastTracker's
does, so that there is no fine slide but FastTracker's own; and a slide of place goes right by its
first half and left by its second, as FastTracker's. A slide of pitch and a vibrato round to the
nearest hertz where Impulse Tracker's cut to the one below, and a vibrato does not move on during a
row's first tick. A sample's own vibrato comes in over so many ticks, as FastTracker's does, from the
top of a wave that stays above the note. A key let go of a note with no envelope for its volume
silences it, and the note goes on, silent; any other note fades as soon as its key is let go, if its
instrument fades, and fades as finely as OpenMPT has it; and an envelope that has run out holds its
last level. An instrument named without a note starts the note's envelopes again; it is for the
last note the channel had that was a note, and not a note-off; and beside a note-off, its sample's
volume is that of the sample the instrument plays the last note on. And a sample that ends dies
away as quickly as OpenMPT lets it.

The commands become Impulse Tracker's under the letters that do the same: a FastTracker command by
its meaning, an Impulse Tracker command as itself, and MadTracker's own by what OpenMPT makes of them
(slides of pitch every tick, vibrato, volume, tempo, a place between the speakers or surround, the
filter's cutoff, playing backwards, a track's volume). Impulse Tracker has room for one command and a
volume column; MadTracker has a third place for where a note goes between the speakers, and puts
what OpenMPT cannot place nowhere, and so here too: in 15 of the files 2,552 such are left out, as
OpenMPT leaves them out, and each file says so. A slide in the volume column can go by fifteen, and
Impulse Tracker's goes to nine: where the command is free it is the command, and otherwise nine.
The drums are eight more channels, each a sample struck at C-5 as loud as its pattern says, and a
pattern that the list plays with more than one drum pattern is made once for each. A file can say it
has 256 patterns or samples, which are more than a byte of Impulse Tracker's can number; only the
patterns the list plays are kept, and a sample beyond the numbers takes the number of one that the file
has not got and nothing plays.

What OpenMPT leaves out is left out here, and said: the tracks' own effects, which 95 of the 106 files
to hand have on some track; the automation, in 57; and VST plug-ins, in one, whose only plug-in is
an instrument that its patterns never play. An instrument that is a plug-in or a MIDI device plays
nothing, and a file whose notes are, half or more, for such instruments or for samples kept in files
of their own is refused, as for an MPTM file; none of those to hand is. A command that OpenMPT does
not know is left out and said to be, in ten files, most of them MadTracker's own that nothing
describes; and so is FastTracker's command that sets where an envelope is, which OpenMPT plays and
Impulse Tracker's replayer has not got, in two. And a sample that is to be played without smoothing between its points is played
smoothed, which two files ask for.

All 106 files to hand are played. Set beside libopenmpt, the two are at the same place on every tick,
with every tick as many frames long, for ten minutes or to the song's end, in every one of them. Every
channel's pitch and volume on every tick of the first two minutes: of 826,682 ticks they are alike on
816,966, 53 files are alike on every tick and 43 more on all but one in fifty. Most of what is left is
the reference's own way of looking, which loses a voice for a tick at the turn of a loop; in the rest,
in two files a slide to a note starts from where libopenmpt has put the pitch back, for a reason not
found in its code.
What is heard was set beside it too, for the first minute of each: the spectrum agrees to 1.000 for the
middle file and 0.999 for the file a tenth of the way up from the worst, the loudness over time to
1.000 and 0.996, and left and right to 0.999 and 0.992. The furthest is a file that stacks fifty voices
of the same short wave a hair apart in pitch: which of their overtones cancel at any moment depends on
how their phases have drifted, and comes out otherwise. Played as loud as OpenMPT plays them, the
middle file is 4 dB quieter than the middle XM file, and the files are made as loud as XM files are.

## 669 — Composer 669 and UNIS 669

A 669 file is a module from Composer 669, which Tran of Renaissance wrote for the PC in 1992, or
from UNIS 669, which came after and added a little. It has eight channels, samples of eight bits,
patterns that each have a speed and a last row of their own, and a handful of commands. Neither
program's replayer has ever been published, and nothing here is a port. The player is written
from the descriptions that came with the two programs and from what OpenMPT and libxmp make of
such a file, and it plays through a mixer of this player's own, since there is no card's sound to
be faithful to: Composer 669 mixed for a Sound Blaster at 22 kHz, UNIS 669 played through a Gravis
Ultrasound, and the mixer here is neither (it puts a curve through each four samples, at the
output's rate, and lets nothing click).

Composer 669 is unlike the trackers that came from the Amiga in one thing, and it is why these
files have a player to themselves. Those trackers count a note's pitch as a period and slide it
by adding to that, so that a slide is a wider step the higher the note. Composer 669 counts in
samples a second, and its slides add to that: 80 a second on every tick for each one of the
command's value, and 40 for a slide to a note. So a slide is widest on the lowest notes, and
turned into another tracker's commands it would be wrong on nearly all of them. Its vibrato is not
one, either: every other tick the note is played 668 samples a second higher for each one of the
value, which is a trill. And a command, once given, goes on until the channel has another command
or another note.

The numbers are OpenMPT's, whose authors set their player beside Composer 669 itself running in
an emulator, and libxmp has the same ones. In three things the two disagree, or OpenMPT disagrees
with the program's own manual, and a choice was made. The manual says a command goes on until the
next; OpenMPT stops the trill at the end of its row, and here, as in libxmp, it goes on. A slide
to a note begins on its first tick here, as in libxmp and as the other slides do in both; in
OpenMPT it begins a tick later. And a pattern's own speed is its speed from its first row, where
OpenMPT, which writes the speed into the pattern as a command, has to put it a row late if every
channel of the first row has a command already. Two more are matters of taste. Composer 669 had
its channels all the way to the left and to the right, turn and turn about, which is all a Sound
Blaster Pro could do and is hard on the ears in headphones: they are brought in to five eighths
of the way, as OpenMPT has them. And a tick is a seventy-eighth of two and a half seconds, which
both of the others agree on, though libopenmpt drops the part of a sample that this comes to at
its output's rate, and so runs faster by a third of a thousandth.

Of 167 files to hand that are named for the format, three are not 669 files at all and are
refused; the other 164 are played. Every channel's pitch and volume was set beside libopenmpt's
on every tick of every one, to its end or for ten minutes: the two are never at different rows
but for the one row of the one file where OpenMPT's speed comes late, and of 901,749 ticks they
are alike on 894,484. Every one of the rest is one of the three things above, or the last tick,
where libopenmpt stops and this goes round. What is heard was set beside it too, for the first
minute of each. With the ticks made the length libopenmpt makes them, the spectrum and the
loudness over time both agree to 1.000 for the middle file and to 0.999 and 0.998 for the file a
tenth of the way up from the worst. With the ticks their own length, a minute of music drifts
apart by a sixtieth of a second, and the same measures come to 0.992 and 0.966, which says more
about the measure than about the sound. The files are made as loud as XM files are, by measure:
the middle one of each is the same.

UNIS 669's two commands are played, in files that say they are its own: one moves a channel a
little to the left or the right on every row, and the other strikes a note again and again
through its row, which OpenMPT takes to mean every so many ticks and so does this. It also has a
tempo faster than the fastest, which nothing says the speed of; a file that asks for it is left
at the tempo it had, and says so. Two of the files have commands that neither program is said to
have had. They are left out, and those files say so too.

## C67 — Composer 670

A C67 file is from Composer 670, which is Composer 669 with an AdLib card beside it: four channels
of samples and nine of the card's FM voices, 32 samples and 32 patches for the chip. (CDFM, the
player that went with it, had another kind of file, the 670, which its converter turns back into
this one; a C67 is what the composer itself kept.)
It is the plainest module there is. It has no commands at all: a pattern is a list of notes, each
with an instrument and a volume, of volumes alone, and of how many rows to wait before the next
thing, and a tune has a speed that nothing changes. Its volumes are sixteen, and the least of them
is not silence, for a sample or for the chip; and it counted the chip's volumes evenly, which the
chip itself does not, so that each has to be looked up.

There is nothing in that which Impulse Tracker's replayer has not got, so it plays these files,
with the FM chip beside it played as OpenMPT plays it, as for an MPTM file. OpenMPT is the only
other player of them, and the pitches, the tempo of 143 to the minute and how loud the chip is
against the samples are as it has them. All 34 files to hand are played. Beside libopenmpt the two
are at the same row on every tick, and alike on 212,060 ticks of 216,154: the rest are the ends of
samples, the tick on which a tune comes round, and the highest FM notes, which OpenMPT keeps as
periods too coarse for them. What is heard agrees to 0.96 for the middle file, the two having
different emulations of the chip. The files are as loud as XM files are, by measure.

## FAR — Farandole Composer

A FAR file is from Farandole Composer, which Megan Potter of Digital Infinity wrote for the PC and
the Gravis Ultrasound in 1994, and which played on that card and nothing else: sixteen channels,
each at one of sixteen places between the speakers, 64 samples of eight bits or sixteen, and
patterns as long as they like, up to 256 rows. Its file was the composer's own working file, and
keeps what the composer had open as well as the tune.

It is like no other tracker in how it keeps time. A tune has a tempo from 0 to 15, which is how
many thirty-seconds of a second a row lasts, and a fine tempo that commands add to and take from.
From the two the program worked out how many ticks a second there were to be, and set the PC's
timer to that, four ticks to a row; where that is slower than the timer's sixteen bits can count,
it halved the tick and gave the row more of them, though not as many more as would keep the row
the length it was. And it took the timer to count a third of a percent faster than it does, so
every tune is that much slower than it says. All of that is kept. (The fine tempo is the part
other players leave out: OpenMPT reads the two commands for it as nothing, and so does what was
made from ModPlug's code, VLC among them. A tune that sets one is then heard at its plain tempo,
which for a tune that raises it by six on its first row is nearly a fifth too slow.) Its slides
are its own too.
They are counted in the steps of the Ultrasound's frequency register, so many samples a second
and not so much of a period, as in a 669 file. A slide to a note is asked for once, with the
number of rows it is to take, and goes on by itself until it is there; a slide to a volume the
same. How deep a vibrato goes is one setting for all sixteen channels. A sample's number counts
only beside a note, and a note with no volume beside it is silent.

The program's replayer was never published, so a FAR file has a small player written for it, as
a 669 file has, from the description of the file that came with the program and from libxmp,
whose authors set their player beside the program itself and wrote down what they found. Set
beside libxmp on every tick of the 37 files to hand, the two are never at different rows, and 32
files are alike on every tick. In four of the rest a note ends a tick sooner in one than in the
other; in the fifth a slide to a volume starts from the volume the channel has, as the program's
description says, where libxmp starts it from the loudest. Two things are libxmp's and not
OpenMPT's: a pattern that the list names and the file has nothing of is 64 rows of nothing, and
the tempo is the program's, where OpenMPT plays every file at one. The files are as loud as XM
files are, by measure.

## CMF — Creative's music files

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

## ROL — AdLib's Visual Composer

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

A CMF file and a ROL file are heard as the card put them out: one channel, through the filter on the card's board that
kept its output centred, and brought from the chip's rate to the player's through a windowed sinc.

## FMT — FM Tracker

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

## AYL — Ay_Emul's playlists

Ay_Emul, Sergey Bulba's player for Windows, keeps its playlists as text. An AYL file
begins with a line that says what it is, "ZX Spectrum Sound Chip Emulator Play List File", and
the version of the format, from 1.0 to 1.6. After it come the tunes, one to a line, each by its
path from the folder the list is in, as Windows writes a path. A tune may be followed by what
Ay_Emul knew about it, between a line that is `<` and a line that is `>`: its name and author, its
length and where it repeats, the chip and clock to play it on, where a module begins inside a
larger file, and a comment. The oldest lists open with such a block before any tune, which is the
program's settings on the day the list was saved.

The format matters because of what is kept in it. Tr_Songs, a large collection of the Spectrum's
tracker music, holds each tune once, under its author, and everything else it knows as lists:
which tunes were in which demo, game, magazine or album, what was entered at each party, and
people's lists of favourites. The comments are where a party's results are written, and where a
few authors say in their own words what a tune was for.

`PlaylistFile` reads one: the tunes and the comments, and nothing else. A tune's name and length
are read from the tune's own file, a module for two chips is found without being told where its
second half begins, and the chip settings are not followed (they are in about fifty entries of the
collection: a clock or a kind of chip that the tune's author meant). The text is taken as Unicode
if it is well formed as that, and otherwise as the Cyrillic of Windows, which is what the older
lists with Russian in them are in.

Finding the tunes is the part that differs between the two players. On the command line a path is
followed from the list's folder, and since the lists were made on Windows, to which capitals and
small letters in a name are one and a full stop at the end of a folder's name is nothing, a step
of the path that is not there as written is looked for as Windows would. A browser gives a page no
disk to look through, only the files it has been handed and the path each came by, and the page
does not know where the list itself was among them. So there a tune is found by the end of its
path: the file of the same name with the most folders above it named as the list names them.

It was checked on the 10,031 lists of that collection: every one of the 42,804 tunes they name
is found, and all are played but five, which are in a format that is not (FLS).
