# Third-party work

This project is licensed under the GNU General Public License, version 2 or (at your option) any later
version; see `LICENSE`. It is built on the work of others, used under the terms below.

## reSIDfp — the SID chip

`Sources/SidayC64/SIDChipFP` is a Swift port of reSIDfp, the MOS 6581/8580 SID emulator engine of
libsidplayfp 2.16.1. It is the default SID engine.

- Copyright 2011-2025 Leandro Nini <drfiemost@users.sourceforge.net>
- Copyright 2007-2010 Antti Lankila
- Copyright 2004, 2010 Dag Lem <resid@nimrod.no>
- Copyright 2018 VICE Project (envelope generator)
- Copyright 2000-2001 Simon White (voice muting, from libsidplayfp's `sidemu`)
- reSIDfp's Java conversion, which the C++ descends from, is by Ken Händel
- GNU General Public License, version 2 or later
- Source: https://github.com/libsidplayfp/libsidplayfp

## reSID — the other SID chip

`Sources/SidayC64/SIDChip` is a Swift port of reSID 1.0, a MOS 6581/8580 SID emulator engine, kept as
`--sid-engine resid`.

- Copyright (C) 2010 Dag Lem <resid@nimrod.no>
- GNU General Public License, version 2 or later
- Source: https://github.com/libsidplayfp/resid

## libsidplayfp — C64 start-up

`Sources/SidayC64/C64/PSIDDriver.swift` contains libsidplayfp's PSID driver (`psiddrv.a65`) in assembled
form, and `Sources/SidayC64/C64/PowerOnMemory.swift` its power-on memory pattern (`poweron.bin`). The
ROM stand-ins, start-up state and timer and video timing rules in `Sources/SidayC64/C64` and
`Sources/SidayC64/SIDFile/SIDRenderer.swift` follow libsidplayfp's behaviour.

- Driver: Copyright 2014 Leandro Nini, Copyright 2001-2004 Simon White, Copyright 2000 Dag Lem
- Power-on pattern and its loader: Copyright 2011-2015 Leandro Nini, Copyright 2007-2010 Antti Lankila,
  Copyright 2001 Simon White
- GNU General Public License, version 2 or later
- Source: https://github.com/libsidplayfp/libsidplayfp

## Ay_Emul — tracker players, register recordings and AY files

The players in `Sources/SidayEightBit/Trackers`, the VTX and YM handling in `Sources/SidayEightBit/Dumps`
and the machine rules in `Sources/SidayEightBit/AYFile` are ported from, or follow, the source code of
Ay_Emul ("AY-3-8910/12 Emulator").

- (c) 1999-2026 Sergey Vladimirovich Bulba <svbulba@gmail.com>
- Terms, from the source archive's readme: "You can use this source code freely, only do references to
  author (Sergey Bulba)."
- Home page: http://ay.strangled.net/

## ayumi — the AY/YM chip

`Sources/SidayEightBit/AYChip` is a Swift port of ayumi (https://github.com/true-grue/ayumi). Its
`ChipOversampler.swift` is ayumi's way of bringing the chip's sound to the player's rate, taken out
of the chip for the other chips that make square waves and steps (the SN76489's, and a DAC's).

```
The MIT License

Copyright (c) Peter Sovietov, http://sovietov.com

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

## AtariAudio — the Atari ST

`Sources/SidayAtari` is a Swift port of AtariAudio 1.26 (https://github.com/arnaud-carre/AtariAudio):
the machine as a tune needs it (`STMachine.swift`), its YM2149 (`STSoundChip.swift`), its timer chip
(`MFP.swift`), the STE's sample player (`STESound.swift`), the reading of an SNDH file's header, and
the playing of Atari ST YM files with their effects (`STYMRenderer.swift`) and of digi-mix and YM
tracker files (`STSampleRenderer.swift`). `YM2Drums.swift` is AtariAudio's bank of the drum samples
that YM2 files call on by number.
`STMixTable.swift` is AtariAudio's table of how an Atari ST mixes its sound chip's three channels,
which its source says was measured and generated on real hardware by Paulo Simões and filled in
between the measured levels by Arnaud Carré. The 68000 is not AtariAudio's (it uses Musashi): it was
written for this project, and is in `Sources/SidayM68000`.

```
MIT License

Copyright (c) 2026 Arnaud Carré

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## ASAP — the 8-bit Ataris

`Sources/SidayEightBit/POKEY` and `Sources/SidayEightBit/SAP` are a Swift port of the emulation in ASAP
8.0.0 (Another Slight Atari Player, https://asap.sourceforge.net/, source at
https://github.com/pfusik/asap): its POKEY (`POKEY.swift`), with its band-limited steps and the levels of
its DAC; its 6502 (`SAP6502.swift`); the machine around them and the calling of a SAP file's code
(`SAPMachine.swift`); and the reading of a SAP file's header (`SAPFile.swift`). Of the other formats ASAP
reads, and the trackers' players it carries for them, nothing is used.

- Copyright (C) 2005-2026 Piotr Fusik
- GNU General Public License, version 2 or later
- Source: https://github.com/pfusik/asap

## ProWizard — modules packed by games' packers

`Sources/SidayAmigaTrackers/Packers/ProWizard` is a Swift port of the part of ProWizard, as libxmp 4.6.3
keeps it (`src/loaders/prowizard`), that unpacks the modules of The Player 4.x, 5.0a, 6.0a and 6.1a,
NoisePacker 1 to 3, ProRunner 1.0 and 2.0, ProPacker 2.1 and 3.0, Pha Packer, Tracker Packer 3, AC1D
Packer, the Novotrade Packer, Digital Illusions' packer, Promizer 1.8a (`pm18a.c`, Copyright (C) 1997
Asle / ReDoX, modified by Claudio Matsuoka and Alice Rowan) and Game Music Creator, and the finding of a
file's packer (`prowiz.c`), with libxmp's reading of a file (`hio.c`, `dataio.c`) as far as they need it.
Beside them, after libxmp's loaders of the same 4.6.3 (same licence): `IceTracker.swift`, which reads
SoundTracker 2.6 and Ice Tracker modules (`ice_load.c`), and
`Sources/SidayAmigaTrackers/OctaMED/MMDCFile.swift`, which unpacks MED modules packed by MMDC
(`mmd1_load.c`). Where these unpack what ProWizard does not, or otherwise than it, they do as UADE's
converter does, Deli-Wizard ("Deli-Wizard genie module v2.20 by Gryzor", "written by Nicolas FRANCK in
1994-95", carried in UADE's `amigasrc/players/tracker/converter`): The Player 6.0a's packed samples,
Promizer's patterns, NoisePacker 3's test, ProRunner's "+SNT", and the patterns of SoundTracker 2.6; and
`ChannelPlayer.swift` unpacks the one packer only Deli-Wizard knows, Channel Player's (`CheckChan`,
`ConvertChan`). Its code was read for that, and nothing of it is carried here but the table of steps of
the packed samples and the table of periods. Deli-Wizard's COPYING says it is not under the GPL; its
README, by Nicolas Franck, asks to be told of a tool that uses it on another system.

- Copyright (C) 1997-1999 Sylvain "Asle" Chipaux
- Copyright (C) 1996-2021 Claudio Matsuoka and Hipolito Carraro Jr
- Source: https://github.com/libxmp/libxmp

```
Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

## AMOS music banks

`Sources/SidayAmigaTrackers/Amiga/AMOSBankFile.swift` reads an AMOS music bank into a ProTracker module
as UADE's player of them does, step for step: "Amos Music Bank Player (Dec 2004)", which says "François
Lionet, adapted by DEFECT, just cut,copy'n pasted for UADE by mld/uade team"
(`amigasrc/players/ambk/AMOS.s` in UADE).

- GNU General Public License, version 2 or later
- Source: https://gitlab.com/uade-music-player/uade

## ChipTracker

`Sources/SidayAmigaTrackers/Amiga/ChipTrackerFile.swift` reads ChipTracker's modules as its own replayer
does, as Wanted Team keep it in their player of the files for EaglePlayer ("ChipTracker player module
V1.2", 2007, carried by UADE as `ChipTracker`; it says of itself "(c) 1991 by Krister 'Kris' Wombell,
adapted by Wanted Team"). Its 68000 code was read for that, and nothing of it is carried here but its
table of periods.

## libtfmxaudiodecoder — TFMX

`Sources/SidayAmigaComposers/TFMX` plays Chris Hülsbeck's TFMX with a Swift port of the player of it in
libtfmxaudiodecoder (`src/Chris/`, with what it uses of the library's checksum, byte order and buffer
code), and `Sources/SidayAmigaComposers/Hippel` Jochen Hippel's TFMX and Future Composer with a port of
its player of those (`src/Jochen/`, its tables generated from the source), both at its commit dcec102 of
2026-09-26.

- Copyright (C) Michael Schwendt
- GNU General Public License, version 2 or later
- Source: https://github.com/mschwendt/libtfmxaudiodecoder

Where Chris Hülsbeck's players did otherwise than the library (`TFMXOriginalPlayers.swift` and the
branches that follow it), how long the player's ticks are (`TFMXTiming`) and how TFMX 7V's voices are
mixed (`TFMXSevenVoices`) are as Chris Hülsbeck's players have them, read in Wanted Team's players of the
files for EaglePlayer, carried by UADE as `TFMX`, `TFMX-Pro` and `TFMX-7V` ("TFMX player module V1.3",
"TFMX Pro player module V1.3" and "TFMX 7V player module V1.1", 2002; they say of themselves "(c)
1988-90", "(c) 1990-94" and "(c) 1991-94 by Chris H"). Their 68000 code was read for that, and nothing of
it is carried here but what it does and its constants: the timer's dividends, the rate, buffer and period
of the mixing, its table of volumes, and the few bytes of a few modules that the players mend as they
load them. Which player a module is played as is chosen as UADE chooses it, by a port of the TFMX test in
UADE's `amifilemagic.c` (Copyright (C) 2000-2005 Heikki Orsila and Michael Doering; "dual licensed under
the GNU GPL and the Public Domain"; https://gitlab.com/uade-music-player/uade). Jochen Hippel's TFMX 7V
is mixed as Wanted Team's player of it has it ("Jochen Hippel 7V player module V1.1", 2009, carried by
UADE as `JochenHippel-7V`; it says of itself "(c) 1990-91 Jochen 'Mad Max' Hippel"), read in the same way
for the same kinds of constants; the rate it mixes at is the one UADE runs it at.

## Infogrames, Fashion Tracker, the Peter Verswyvelen Packer, the Alcatraz Packer and others

`Sources/SidayAmigaComposers/Infogrames`, `FashionTracker`, `PeterVerswyvelenPacker`, `AlcatrazPacker`,
`DigitalSonix`, `AndrewParton`, `EditeurMusicalSequentiel`, `ForgottenWorlds`, `Leggless`, `JamCracker`,
`AMComposer`, `ProfessionalSoundArtists`, `MusicalEnlightenment`, `SteveTurner`, `Cinemaware`,
`PaulShields`, `SoundPlayer`, `PaulRobotham`, `ThomasHermann`, `Soundfactory`, `SynthDream` and
`BladePacker` play these formats as the players of them carried by UADE do: Andy Silva's DeliTracker
player for Infogrames' music (read in UADE's `amigasrc/players/uade/infogrames`, whose licence is not
given), and Wanted Team's players for EaglePlayer of the others (`FashionTracker-v1.0`,
`PeterVerswyvelenPacker`, `Alcatraz_Packer`, `DigitalSonixChrome_v1.asm`, `Andrew Parton`, `EMS`, `LME`,
`AMComposer`, `PSA`, `TME`, `SteveTurner`, `Cinemaware`, `PaulShields`, `SoundPlayer`, `PaulRobotham`,
`ThomasHermann`, `Soundfactory`, `SynthDream`, `BladePacker` in `amigasrc/players/wanted_team`), and
Psygore's for Forgotten Worlds (UADE's `players/ForgottenWorlds_Game`, read in its 68000 code), and
Buggs/DEFECT's for JamCracker (`amigasrc/players/defect/jamcracker`). Their code was read for that, and
nothing of it is carried here but its tables of periods, and, for Paul Shields' player, the seven waves
of its own that its replayer plays, which Wanted Team's source keeps as data (one of them 400 bytes of
the game's player's own code, played as noise).

`Sources/SidayAmigaComposers/TimFollin`, `PaulSummers`, `ActionAmics` and `DavidHanney` are made after
players carried by UADE as well, read in their source where there is one and in their 68000 code where
there is not: Andy Silva's "Follin Player II" for DeliTracker ("Tim Follin / Mike D., adapted by Andy
Silva", `amigasrc/players/other/timfollin/DP_TimFollin.asm`, and the newer `players/TimFollin`); Wanted
Team's "Paul Summers player module V1.2 (2 Nov 2003)" ("(c) 1989-90 by Paul Summers & Mike Chilton",
whose V1.1 is in `amigasrc/players/wanted_team/PaulSummers`); "Action Amics SoundTools V0.1 player module
V1.1 (05 April 93)" (`players/ActionAmics`, "Testversion by Turbo/IFT & Eagleeye/DEFECT"); and "David
Hanney player module V1.1 (28 Feb 97)" (`players/DavidHanney`, "(c) 1992 by David Hanney, adapted by
Mr.Larmer/Wanted Team & DEFECT"). None of their code is carried, but for the tables of periods, and, for
David Hanney's, the whole of that player's data: Tearaway Thomas's music files carry neither samples nor
instruments, which were in the game and are kept only there, in the player's second hunk (HUNK_DATA,
5,540 bytes from the file's byte $E98, in UADE 3.05's `players/DavidHanney` of 9,280 bytes, SHA-256
1691e2912938304d52713afd162f01836b3e6fed92a786c88af92485c3ac2e3f): three samples and sixteen instruments,
thirteen of them short waves of the game's own. They are carried as they are, in `DavidHanneyData.swift`.

`Sources/SidayAmigaComposers/RonKlaren` plays Ron Klaren's music as Wanted Team's "CustomMade player
module V1.1 (5 Jan 2004)" plays it ("(c) 1989-90 by Ivo Zoer & Ron Klaren, adapted by Andy Silva & Wanted
Team", `players/CustomMade`, with its source in `amigasrc/players/wanted_team/CustomMade/CustomMade_v1.asm`),
whose copy of Ivo Zoer's replay routine was read for that. Nothing of its code is carried here but its
table of periods.

`Sources/SidayAmigaComposers/JasonPage` and `SoundControl` play Jason Page's music and SoundControl's as
Wanted Team's players of them play them, read in their source in `amigasrc/players/wanted_team`: "Jason
Page player module V1.3 (26 June 2001)" (`players/JasonPage`, `JasonPage/src/Jason Page_v5.s`, by
Mr.Larmer/Wanted Team and PP/Union), and "Soundcontrol 3.0/3.2/4.0/5.0 player module V1.2 (25 Mar 2002)"
(`players/SoundControl`, `Soundcontrol/src/Soundcontrol_v3.asm`; "(c) 1989-95 by Holger Gehrmann").
Nothing of their code is carried here but what it does and its tables of periods.

`Sources/SidayAmigaComposers/SynthPack` plays Karsten Obarski's Synth Pack songs as Wanted Team's "Synth
Pack player module V1.1 (20 Jun 2000)" plays them ("(c) 1989-92 by Karsten 'Obi' Obarski, adapted by Wanted
Team"; `players/SynthPack`, 10,000 bytes, of which there is no source), read in a disassembly of it. Its
waves are worked out in code, and checked to be the same bytes as the player's. Carried as data, in
`SynthPackTables.swift`, are only what cannot be worked out: from its code hunk (whose byte X is the
file's byte X + 32), its two tables of noise (the low bytes of the 32 words at $153E, and the 128 bytes
at $250A), its 72 periods (at $11EE), the seven songs' first positions of Dyter-07's routine (at $8AA),
and its arpeggios, as the steps they make.

`Sources/SidayAmigaComposers/Silmarils` plays the music of Silmarils' games as Wanted Team's "Silmarils
player module V1.0 (22 Oct 2001)" plays it ("(c) 1989-92 by Michel Pernot, adapted by Wanted Team";
`players/Silmarils`, of which there is no source), read in a disassembly of it. Nothing of its code is
carried here but what it does and its table of periods.

## PumaTracker, Pierre Adane's packer, Game Music Creator and Images Music System

`Sources/SidayAmigaComposers/Puma`, `PAP`, `GMC` and `IMS` play these four kinds of game music as their
own players did, as kept for EaglePlayer and DeliTracker and carried by UADE: "PumaTracker player module
V1.1" (2006, `PumaTracker`; "(c) 1991 by Jean-Charles Meyrignac & Pierre-Eric Loriaux, adapted by WT"),
"Pierre Adane Packer player module V1.1" (2001, `PierreAdane`; "(c) 1990 by Pierre Adane, adapted by
Mr.Larmer/Wanted Team"), "Game Music Creator player module V1.6" (1993, `GMC`; Andreas Tadic's, "adapted
by Delirium & (much more) by Buggs") and "Images Music System player module V1.2" (2001,
`ImagesMusicSystem`; "(c) 1990 by Images Software, adapted by Wanted Team"). Their 68000 code was read
for that, and nothing of it is carried here but what it does and its tables: PumaTracker's periods and
its 42 waveforms (`PumaTables.swift`, taken from the player; the same bytes as OpenMPT's `Load_puma.cpp`
has, BSD licence, Copyright (c) 2004-2026, OpenMPT Project Developers and Contributors), Pierre Adane's
and Images Music System's periods, and the list of Beast Busters' songs that Wanted Team made.

## SoundMon

`Sources/SidayAmigaComposers/SoundMon` plays Brian Postma's SoundMon as his replay routines of SoundMon
2.0 and 2.2 do, which he placed into the public domain, as mld adapted them for UADE ("SoundMon 2.0
player module" and "SoundMon 2.2 player module", Jul 2004, carried by UADE as `SoundMon2.0` and
`SoundMon2.2`, with their source in `amigasrc/players/uade/soundmon`). Their code was read for that, and
nothing of it is carried here but what it does and its tables of periods and of vibrato.

## SidMon, Digital Mugician, Delta Music and Sonic Arranger

`Sources/SidayAmigaComposers/SidMon`, `Mugician`, `DeltaMusic` and `SonicArranger` play these formats as
their own players do, as UADE runs them: "SIDMon 1.0 player module for UADE" (2001, by mld; the player
says "SID-MON BY R.v.VLIET (c) 1988"), "Sidmon-II Eagleplayer V1.8" (1993, adapted by Defect), Wanted
Team's "Mugician player module V1.1" and "Mugician II player module V1.7" ("(c) 1990-94" and "(c) 1991-94
Reinier 'Rhino' van Vliet", with their source in UADE's `amigasrc/players/wanted_team`), "Deltamusic V2.0
player module V1.2" (1993, adapted by Eagleeye), Wanted Team's "Sonic Arranger 2.18 player module V1.0"
("(c) 1991-95 by Carsten Schlote, Branko Mikić & Carsten Herbst") and "SonicArranger(pc)all versions
player module V1.0" (1993, by Turbo of Infect). Their code, and the replay routines that SidMon's, Delta
Music's and some of Sonic Arranger's files carry in front of their music, were read for that, and nothing
of them is carried here but what they do and their tables.

## MaxTrax

`Sources/SidayAmigaComposers/MaxTrax` is a Swift port of the MaxTrax Music Driver (`max.asm`,
`shared.asm`, `driver.i`), as UADE carries its source (`amigasrc/players/other/max_trax`).

- Written by Talin (David Joiner) and Joe Pearce; licensed to game developers by The Dreamers Guild
- GNU Lesser General Public License, version 2.1 or later
- Source: https://gitlab.com/uade-music-player/uade

It was checked against ScummVM's player of MaxTrax (`audio/mods/maxtrax.cpp`, GNU General Public
License, version 2 or later, https://github.com/scummvm/scummvm), from which the tempos Legend of
Kyrandia's game gives its scores are taken (`engines/kyra/sound/sound_amiga_lok.cpp`).

## Sonix Music Driver

`Sources/SidayAmigaComposers/Sonix` plays the Sonix Music Driver's scores as Mark Riley's players of them
do ("Sonix Music Driver (C) Copyright 1987-91 Mark Riley, All Rights Reserved"), as Wanted Team keep
three of them in their player of the scores for EaglePlayer ("Sonix Music Driver player module V2.0",
2004, carried by UADE as `SonixMusicDriver`, with its source in `amigasrc/players/wanted_team`; it says
of itself "(c) 1987-91 by Mark Riley, adapted by Wanted Team"): version 2.3c, from Dynamix's Rise of the
Dragon, 2.0b, from Melbourne House's Magic Johnson's Basketball, and 2.0f, from Synergistic's Vengeance
of Excalibur. Their 68000 code was read for that, and nothing of it is carried here but what it does and
its tables: of the steps of an octave and of pitch bends, of tempos, of the lengths of notes and rests,
and of the filters a synthesised instrument is passed through.

## Musicline Editor

`Sources/SidayAmigaComposers/Musicline` is a Swift port of the Musicline Editor's player for
DeliTracker (`mlineplayer102.asm`, "Musicline Editor DeliPlayer 1.02"), as UADE carries its source
(`amigasrc/players/other/musicline_editor`), with its tables (its `raw` folder) as Swift arrays.

- Copyright (C) John Carehag; the authors of the work include Conny Cyreus, Christian Cyreus, John
  Carehag and Jimmy Fredriksson
- GNU Lesser General Public License. Its source names no version and points to UADE's
  COPYING.LGPL, which is version 2.1. As its section 3 allows, the port is distributed under the GNU
  General Public License, version 2 or later, with the rest of this project
- Source: https://gitlab.com/uade-music-player/uade

## Wanted Team's players, and more composers' drivers

`Sources/SidayAmigaMachine/WantedTeam` finds, mends and calls the drivers of 28 more of the Amiga's
composers and studios, which are in the files themselves, on siday's own Amiga, as the players of them
for EaglePlayer that UADE carries do: Wanted Team's (in `amigasrc/players/wanted_team`, where their
source is given, or in UADE's `players`, read in their 68000 code where it is not: Fred Gray, Howie
Davies, Sound Programming Language, Beathoven Synthesizer, Sean Connolly, Sound Images, Mike Davies,
Jason C. Brooke, Dynamic Synthesizer), Andy Silva's for the SCUMM
sounds and Eagleeye's for Mark II (in UADE's `players`, read in their code), Stephen Mifsud's for
Darius Zendeh (`amigasrc/players/dz`), and UADE's own for Fred Monitor (`amigasrc/players/fred`,
Heikki Orsila, LGPL). Their code was read for that, and nothing of it is
carried here but what it does: their patches are written afresh as the same instructions, assembled by
siday, and their tables of patterns to find written out.

## David Whittaker

`Sources/SidayAmigaMachine/Whittaker` finds, mends and calls David Whittaker's drivers, which are in the
files themselves and are run as they are on siday's own Amiga (`Sources/SidayAmigaMachine/AmigaMachine`),
as Wanted Team's player of them for EaglePlayer does ("David Whittaker player module V1.0", 2000, carried
by UADE as `DavidWhittaker`; it says of itself "(c) 1987-94 by David Whittaker & Rob Hubbard, adapted by
Wanted Team"). Its 68000 code was read for that, and nothing of it is carried here but what it does: the
hooks it puts into a driver are written afresh, in a few instructions of 68000 code of siday's own. The
first bytes of the Amiga's memory are laid out as UADE's host for the players, its sound core `score`,
lays them out (`amigasrc/score/score.s`, Copyright Heikki Orsila, GNU Lesser General Public License;
https://gitlab.com/uade-music-player/uade), whose layout was read for that and nothing of whose code is
carried here.

## Ben Daglish

`Sources/SidayAmigaMachine/Daglish` finds, mends and calls Ben Daglish's drivers, which are in the files
themselves and are run as they are on siday's own Amiga, as Wanted Team's player of them for
EaglePlayer does ("Benn Daglish player module V1.2", 2004, carried by UADE as `BenDaglish`, with its
source in `amigasrc/players/wanted_team`; "(c) 1988-92 by Colin Dooley & Ben(n) Daglish, adapted by
Mr.Larmer/WT"). Its code was read for that, and nothing of it is carried here but what it does: the
hooks it puts into a driver are written afresh, in 68000 code of siday's own. When the sound chip asks
for an interrupt is as UADE's emulation of it has it (`src/audio.c`, `src/custom.c`, from UAE, GNU
General Public License), which was read for that.

## Martin Walker

`Sources/SidayAmigaMachine/MartinWalker` finds, mends and calls Martin Walker's drivers, which are in the
files themselves and are run as they are on siday's own Amiga, as Wanted Team's player of them for
EaglePlayer does ("Martin Walker player module V1.1", 2001, carried by UADE as `MartinWalker`, with its
source in `amigasrc/players/wanted_team`; "(c) 1990-94 by Martin Walker, adapted by Wanted Team"). Its
code was read for that, and nothing of it is carried here but what it does: the hooks it puts into a
driver are written afresh, in 68000 code of siday's own.

## Special FX

`Sources/SidayAmigaMachine/SpecialFX` moves, mends and calls Special FX's driver, which is in each file
itself and is run as it is on siday's own Amiga, as Wanted Team's player of it for EaglePlayer does
("Special FX player module V1.1", 2007, carried by UADE as `Special-FX`, with its source in
`amigasrc/players/wanted_team`; "(c) 1989-91 by Matthew Cannon & Jonathan Dunn, adapted by Wanted Team").
Its code was read for that, and nothing of it is carried here but what it does: the hooks it puts into
the driver are written afresh, in 68000 code of siday's own that does as theirs does.

## The Maniacs of Noise

`Sources/SidayAmigaMachine/ManiacsOfNoise` calls the Maniacs of Noise's drivers, which are in the files
themselves and are run as they are on siday's own Amiga: Charles Deenen's later one as UADE's own player
of it does ("MON player module V0.1 for UADE", 2002, Copyright Heikki Orsila, GNU Lesser General Public
License; "based on replayer by Frederick Hahn and Maniacs of Noise/Charles Deenen"; its source in UADE's
`amigasrc/players/uade/mon/ManiacsOfNoise.asm`), and Jeroen Tel's and Charles Deenen's earlier one as
Wanted Team's player of it for EaglePlayer does ("Jeroen Tel player module V1.0", 2004, carried by UADE
as `JeroenTel`; "(c) 1989-90 by Jeroen Tel & Charles Deenen, adapted by Wanted Team"). Their code was
read for that, and nothing of it is carried here but what it does: where Wanted Team's player changes the
driver, the change is made afresh in 68000 code of siday's own.

## DeliTracker's custom modules, and Dave Lowe's earlier music

`Sources/SidayAmigaMachine/AmigaMachine/DeliTrackerHost.swift` hosts DeliTracker's custom modules
(`Sources/SidayAmigaMachine/DeliCustom`) as UADE's host for the players does, in its order and at its
addresses: its sound core `score` (`amigasrc/score/score.s`, Copyright Heikki Orsila, GNU Lesser General
Public License; https://gitlab.com/uade-music-player/uade), with the DeliTracker and EaglePlayer include
files beside it, was read for that, and nothing of its code is carried here. When the sound chip asks for
an interrupt is as UADE's emulation of the hardware has it (`src/audio.c`, `src/custom.c`, from UAE, GNU
General Public License), which was read for that. DeliTracker is Frank Riffel's and Peter Kunath's. Dave
Lowe's earlier music (`Sources/SidayAmigaMachine/DaveLoweCode`) is loaded and called as Wanted Team's
player of it does ("Dave Lowe", carried by UADE as `DaveLowe`, with its source in
`amigasrc/players/wanted_team`), whose code was read for that. Its older rips
(`DaveLoweSoundSystemPlayer.swift`) are played as DeliTracker's player "Dave Lowe's Sound System" plays
them ("Dave Lowe DeliPlayer V1.0 (3/9/97) by DARKNESS/SYNERGY", carried by UADE as `DaveLowe_Deli`,
without source), whose replay routine, Dave Lowe's own, was read in a disassembly of it; nothing of its
code is carried here.
Electronic Arts' modules, which need more of the Amiga's system than score gives, are given an exec,
timer.device and audio.device of siday's own (`AmigaExec.swift`, `AmigaTimerDevice.swift`,
`AmigaAudioDevice.swift`), written from Commodore's Autodocs and from what Kickstart 1.3's were measured
doing, write by write, in [Copperline](https://copperline.dev/), an emulator of the whole Amiga; no code
of any ROM's is carried here.

## Richard Joseph's player and Dave Lowe's

`Sources/SidayAmigaComposers/RichardJoseph` and `DaveLowe` play these composers' music as their own
players do, as Wanted Team keep them for EaglePlayer, carried by UADE with their source in
`amigasrc/players/wanted_team`: "Richard Joseph Player V1.7A module replayer V1.1" (2001,
`RichardJoseph_Player`; "(c) 1992-93 by Richard Joseph & Andi Smithers, adapted by Wanted Team") and
"Dave Lowe New" (V1.1, 2001, `DaveLoweNew`; "(c) 1993-95 Dave Lowe from Uncle Art, adapted by Wanted
Team"). Their 68000 code was read for that, and nothing of it is carried here but what it does and its
tables, and the bytes of the few modules that the players mend as they load them.

## Magnetic Fields Packer

`Sources/SidayAmigaTrackers/Amiga/MagneticFieldsPacker.swift` reads the songs of the Magnetic Fields
Packer as libxmp 4.6.3 reads them (`src/loaders/mfp_load.c`, Copyright (C) 1996-2021 Claudio Matsuoka and
Hipolito Carraro Jr, under the MIT licence given above for ProWizard), but for the table that says where
each voice's notes begin, which is read as the format's replayer reads it (and as libxmp has since
4.7.1): Wanted Team's player of the files for EaglePlayer ("Magnetic Fields Packer player module V1.3",
2003, carried by UADE as `MagneticFieldsPacker`; it says of itself "(c) 1994-95 by Shaun Southern,
adapted by Mr.Larmer/Wanted Team"), with which it was compared. Nothing of that player is carried here.

## Sierra AGI sounds

`Sources/SidayEightBit/AGI` plays the sounds of Sierra On-Line's AGI games as the company's interpreter
for the Amiga did, by the two routines Wanted Team kept in their player of the sounds for
EaglePlayer ("Sierra AGI player module V1.0", 2006, on Aminet as `mus/play/EP_SierraAGI.lha`, and
carried by UADE as `Sierra-AGI`; it says of itself "(c) 1986-88 by Sierra On-Line, adapted by Wanted
Team"). Its 68000 code was read for what the routines do, and nothing of it is carried here but what
it holds as data: the two waves of the tones, the shift register the noise is made from and its
constant, the steps by which the later routine turns a note down, and the rates of the noise and the
timer. The way the PC's interpreter wrote to the chip is as NewRisingSun's recordings of King's Quest
II show it (https://vgmrips.net/); the chip is MAME's (below).

## pt2-clone — the Amiga

`Sources/SidayAmigaTrackers/Amiga` is a Swift port of the playing parts of pt2-clone 1.92
(https://github.com/8bitbubsy/pt2-clone), Olav Sørensen's re-creation of ProTracker 2.3D: its replayer,
which is a C port of ProTracker's own (`ProTrackerReplayer.swift`), its reading of 31-sample and
15-sample modules (`ProTrackerModule.swift`), and its emulation of Paula with the Amiga's filters and its
way of halving the sample rate (`Paula.swift`, in `Sources/SidayChips/Paula`). The band-limited steps in
Paula's output (`PaulaStep.swift`) are credited in its source to aciddose, who wrote them for that
project. `Sources/SidayAmigaTrackers/Packers/PowerPacker.swift` follows the depacker in the same source,
which says it is taken from Heikki Orsila's amigadepack.

The player of MED modules (`Sources/SidayAmigaTrackers/OctaMED`) is not a port of anything: it was
written for this project, to do what OctaMED's own players do, and none of their code is in it; nor is
its mixer for OctaMED Soundstudio's mixing mode taken from anywhere. Its modules for the Amiga's voices
play on the Paula above, its renderer (`MEDRenderer.swift`) is made after `MODRenderer.swift`, and its
table of periods is built from the table in `ProTrackerReplayer.swift`, so those parts of it stand on
pt2-clone as the rest of this folder does.

`MED4File.swift`, which reads a MED4 file, the songs of MED 2.10 to 3.00, into the MMD0 module
the player plays, is made after libxmp's loader of that format (https://github.com/libxmp/libxmp,
`src/loaders/med4_load.c`): the layout of the file. libxmp's player is not used. Under the MIT
licence, Copyright (C) 1996-2026 Claudio Matsuoka and Hipolito Carraro Jr, the text of which is
below, under "libxmp and OpenMPT — reading MTM, DTM and AMF files".

`StartrekkerSynth.swift` and the playing of Startrekker's synthesised instruments in
`ProTrackerReplayer.swift` are made after the 68000 code of ASREPLAY, The Synchron Assembly's replay
routine for Audio Sculpture's and Startrekker's modules, as UADE carries it in its AudioSculpture
player ("AudioSculpture/Startrekker4AM player V0.1.1 (Jul. 2004)", adapted for UADE by mld and shd;
https://zakalwe.fi/uade, `amigasrc/players/uade/adsc/AudioSculpture.asm`): the layout of the file of
instruments, the tables of waveforms and of the vibrato, and what is done on each tick. No code of it
is carried; it is written again in Swift.

Nor are the players of SoundFX modules (`Sources/SidayAmigaTrackers/SoundFX`) and of Oktalyzer modules
(`Sources/SidayAmigaTrackers/Oktalyzer`) ports of anything: they were written for this project, to do
what the trackers' own replay routines do, and none of those routines' code is in them. They play on the
Paula above, their renderers are made after `MODRenderer.swift`, and their periods are the table in
`ProTrackerReplayer.swift` (with, for SoundFX, the periods its routine has below that table's lowest), so
those parts of them stand on pt2-clone as the rest of this folder does.

```
BSD 3-Clause License

Copyright (c) 2010-2026, Olav Sørensen
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## ahx2play — AHX

`Sources/SidayAmigaTrackers/AHX` is a Swift port of ahx2play (https://github.com/8bitbubsy/ahx2play), Olav
Sørensen's C port of the replayer of AHX 2.3d-sp3, made from that tracker's own source: the replayer
(`AHXReplayer.swift`), the making of the tracker's waves and of its filtered copies of them
(`AHXWaves.swift`), the reading of AHX files (`AHXModule.swift`), and its way of writing its output,
which is kept for comparing the two (`AHXRenderer.swift`). ahx2play's emulation of Paula is not
ported: its voices are those of pt2-clone's, above, and that is what the tunes are played on.

```
BSD 3-Clause License

Copyright (c) 2021-2024, Olav Sørensen
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## HivelyTracker — HVL

`Sources/SidayAmigaTrackers/Hively` is a Swift port of the replayer of HivelyTracker 1.9
(https://github.com/pete-gordon/hivelytracker), by Pete Gordon and those who have worked on it since:
the replayer and its mixer (`HVLReplayer.swift`), with the tables of how much of a voice goes to each
side as the replayer works them out, and the reading of HVL files and of AHX files as that replayer
reads them (`HVLModule.swift`). The waves it plays are the same as AHX's, to the byte, and are made
by the code that makes those (`AHXWaves.swift`, above).

```
BSD 3-Clause License

Copyright (c) 2006-2018, Pete Gordon
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

* Neither the name of the copyright holder nor the names of its
  contributors may be used to endorse or promote products derived from
  this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## libdigibooster3 — DBM files

`Sources/SidayAmigaTrackers/DigiBooster` is a Swift port of libdigibooster3 1.2, DigiBooster 3's replayer,
which its makers published in 2014 as "the official loader/replayer portable library for
DigiBooster 3 music modules": its `player.c` (`DBMPlayer.swift`), with its tables
(`DBMTables.swift`); its `dsp_wavetable.c`, `dsp_linresampler.c`, `dsp_panoramizer.c` and
`dsp_echo.c` (`DBMVoice.swift`); and its `loader.c` (`DBMModule.swift`), where what it would refuse
a file for is made the best of instead. The package came from Amiga Future's archive of downloads,
where the DigiBooster site sent it.

```
Copyright (c) 2014, Grzegorz Kraszewski
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

This software is provided by the copyright holders and contributors "as is" and
any express or implied warranties, including, but not limited to the implied
warranties of merchantability and fitness for a particular purpose are
disclaimed. In no event shall the copyright owner or contributors be liable for
any direct, indirect, incidental, special, exemplary, or consequential damages
(including, but not limited to, procurement of substitute goods or services;
loss of use, data, or profits; or business interruption) however caused and
on any theory of liability, whether in contract  strict liability or tort
(including negligence or otherwise) arising in any way out of the use of this
software, even if advised of the possibility of such damage.
```

## ft2play — FastTracker 2

`Sources/SidayTrackers/FastTracker` is a Swift port of ft2play (https://github.com/8bitbubsy/ft2play),
Olav Sørensen's C port of the replayer and mixer of FastTracker 2.09, made directly from that tracker's
assembly and Pascal: the replayer (`FT2Replayer.swift`), the mixer (`FT2Player.swift`), the reading of XM
files and of MOD files as FastTracker reads them (`FT2Module.swift`), and FastTracker's tables
(`FT2Tables.swift`).

```
BSD 3-Clause License

Copyright (c) 2020-2024, Olav Sørensen
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## libxmp and OpenMPT — reading MTM, DTM and AMF files

No code of either player is in this one, but the three loaders in `Sources/SidayTrackers/FastTracker` that
read the modules of MultiTracker, Digital Tracker and DSMI into what FastTracker 2's replayer plays
(`MTMFile.swift`, `DTMFile.swift`, `AMFFile.swift`) were written from theirs: from libxmp
(https://github.com/libxmp/libxmp), `src/loaders/mtm_load.c`, `dt_load.c` and `amf_load.c`, and from
OpenMPT (https://openmpt.org), `soundlib/Load_mtm.cpp`, `Load_dtm.cpp` and `Load_amf.cpp`. The layout
of each file, what each tracker's commands mean and which of them a version of a tracker had, are as
those loaders have them; where the two differ, the Swift says which it follows and why.

libxmp:

```
Extended Module Player
Copyright (C) 1996-2026 Claudio Matsuoka and Hipolito Carraro Jr

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

OpenMPT:

```
Copyright (c) 2004-2026, OpenMPT Project Developers and Contributors
Copyright (c) 1997-2003, Olivier Lapicque
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the OpenMPT project nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## st3play — Scream Tracker 3

`Sources/SidayTrackers/ScreamTracker` is a Swift port of st3play (https://github.com/8bitbubsy/st3play),
Olav Sørensen's C port of the replayer of Scream Tracker 3.21, made from that tracker's own assembly and
C: the replayer (`ST3Player.swift`, `ST3Effects.swift`), the reading of S3M files (`ST3Module.swift`),
Scream Tracker's driver for the Gravis Ultrasound with st3play's emulation of that card's sound chip, its
mixing for the Sound Blaster Pro, and the windowed sinc that brings either card's rate to the player's
(`ST3Cards.swift`, and `ST3Sinc.swift` in `Sources/SidayFoundation`), and Scream Tracker's driver for the
AdLib card (`ST3AdLib.swift`). st3play's own OPL2 emulator is not ported: the AdLib card's chip here is
Nuked OPL3, below.

```
BSD 3-Clause License

Copyright (c) 2021-2025, Olav Sørensen
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## st2play — Scream Tracker 2

`Sources/SidayTrackers/ScreamTracker2` is a Swift port of st2play (https://github.com/viiri/st2play), a C
port of the replayer and the mixing of Scream Tracker 2: `ST2Player.swift` is the `st2play.c` of its
branch for version 2.3, and `ST2Module.swift` its `stmload.c`. Changed from the original: carried
over from C to Swift; a pattern, a place in the list or a sample that a file has none of is read as
nothing, where the original reads whatever is in memory; a number in the list of patterns that is
neither a pattern's nor a mark of the end is taken for the end; a sample that is to go round from
past its own end is read on into what follows it in the file, where the original brings the end in
(it is brought in for `--raw`); a file is held to OpenMPT's checks before it is taken for an STM
file; and the player is told which rows it has played, so that a tune's length can be found.
`STMRenderer.swift`, which brings the sound to the player's rate, is not from st2play.

- Copyright 2017 Sergei "x0r" Kolzun
- Apache License, Version 2.0, the text of which is below, under "fmdrv — Creative's driver for CMF
  files", with what that licence means for this project as a whole
- Source: https://github.com/viiri/st2play

`Sources/SidayTrackers/ScreamTracker2/STXFile.swift`, which reads an STX file into the STM file it was
made from, is made after the STX loaders of OpenMPT (https://openmpt.org, `soundlib/Load_stm.cpp`)
and libxmp (https://github.com/libxmp/libxmp, `src/loaders/stx_load.c`): the layout of the file, its
two versions, and the checks a file is held to. Under the licences set out above, under "libxmp and
OpenMPT — reading MTM, DTM and AMF files".

## it2play — Impulse Tracker 2

`Sources/SidayTrackers/ImpulseTracker` is a Swift port of it2play (https://github.com/8bitbubsy/it2play),
Olav Sørensen's C port of the replayer of Impulse Tracker 2.15, made from that tracker's own assembly:
the replayer (`IT2Player.swift`, `IT2Effects.swift`, `IT2Tables.swift`), the reading of IT files and the
unpacking of their compressed samples (`IT2Module.swift`), and the sound driver it2play adds to Impulse
Tracker's own, which mixes in floating point through a windowed sinc and has the resonant filter
(`IT2Mixer.swift`). Impulse Tracker's own drivers, and it2play's reading of S3M and MMCMP files, are not
ported (MMCMP is unpacked as below). (`IT2ForeignModule.swift`, `GDMFile.swift`, `PTMFile.swift` and
`ULTFile.swift` in that folder are not from it2play: they are what gives that replayer three other kinds
of file to play, and are below. Nor are `MPTMFile.swift`, `IT2OpenMPT.swift` and `IT2AdLib.swift`, which
give it OpenMPT's own kind of file, and what that kind of file asks of it that an IT file does not; they
are below too, and the few lines in the replayer and its mixer that are there for them say so where they
stand. Nor are `MDLFile.swift` and `IT2Digitrakker.swift`, for Digitrakker's files, below as well, nor
`DMFFile.swift` and `IT2XTracker.swift`, for X-Tracker's.)

```
BSD 3-Clause License

Copyright (c) 2022-2025, Olav Sørensen
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## libxmp and OpenMPT — 669 and FAR files

No code of either player is in this one, but the reading and the playing of 669 files
(`Sources/SidayTrackers/Composer669`) were written with theirs open: libxmp's `src/loaders/669_load.c`
and the 669 effects in its `src/effects.c`, and OpenMPT's `soundlib/Load_669.cpp` and what its
`Snd_fx.cpp` and `Sndmix.cpp` do for a module of that kind. The checks a file is held to before it
is taken for a 669 file, how far each command moves a note's pitch, the tempo, and how far to each
side the channels sit are as OpenMPT has them; where the two differ, or differ from the manuals of
Composer 669 and UNIS 669, the Swift and the README say which is followed and why. Both are used
under the licences set out above, under "libxmp and OpenMPT — reading MTM, DTM and AMF files", and
below, under "OpenMPT — FM Tracker files".

The reading and the playing of FAR files (`Sources/SidayTrackers/Farandole`) were written the same way,
with libxmp's `src/loaders/far_load.c` and `src/far_extras.c` open, and OpenMPT's
`soundlib/Load_far.cpp`: how the program kept time, how far each command moves a pitch or a volume,
and when a note is struck again are as libxmp has them, whose authors found them out from
Farandole Composer itself. No code of either is in it. Under the same licences.

## libxmp and OpenMPT — GDM, PTM and ULT files

`Sources/SidayTrackers/ImpulseTracker/GDMFile.swift`, `PTMFile.swift` and `ULTFile.swift`, which read GDM,
PTM and ULT files into the shape Impulse Tracker's replayer plays, are made after the loaders of
those formats in libxmp (https://github.com/libxmp/libxmp, `src/loaders/gdm_load.c`, `ptm_load.c`
and `ult_load.c`) and in OpenMPT (https://openmpt.org, `soundlib/Load_gdm.cpp`, `Load_ptm.cpp` and
`Load_ult.cpp`): the layout of the files, and what each of their commands is taken to mean. Neither
library's player is used. Both are used under the licences set out above, under "libxmp and OpenMPT —
reading MTM, DTM and AMF files": libxmp's the MIT licence, Copyright (C) 1996-2026 Claudio Matsuoka
and Hipolito Carraro Jr, and OpenMPT's the BSD 3-Clause licence, Copyright (c) 2004-2026 OpenMPT
Project Developers and Contributors and Copyright (c) 1997-2003 Olivier Lapicque.

## OpenMPT — C67 files

`Sources/SidayTrackers/ImpulseTracker/C67File.swift`, which reads a Composer 670 module into the shape
Impulse Tracker's replayer plays, is made after OpenMPT's loader of that format
(`soundlib/Load_c67.cpp`): the layout of the file, the checks it is held to, and what its notes and
volumes are taken to mean. It is used under OpenMPT's licence, the BSD 3-Clause, set out below under
"OpenMPT — FM Tracker files".

## OpenMPT — MT2 files

`Sources/SidayTrackers/ImpulseTracker/MT2File.swift`, which reads a MadTracker 2 module into the shape
Impulse Tracker's replayer plays, is made after OpenMPT's loader of that format
(`soundlib/Load_mt2.cpp`, by Olivier Lapicque and the OpenMPT developers, with the way its samples
are packed from `soundlib/SampleIO.cpp`): the layout of the file, the checks it is held to, and what
its commands, instruments, envelopes, samples and drums are taken to mean. `IT2MadTracker.swift`,
and the lines in `IT2Player.swift`, `IT2Effects.swift` and `IT2Mixer.swift` that are marked as an MT2
file's, follow what OpenMPT's player does for these files and not for an IT file (`soundlib/Snd_fx.cpp`
and `soundlib/Sndmix.cpp`): its slides by their first half, its rounded slides of pitch and
vibrato, a sample's own vibrato, a key let go, a fade, an instrument named without a note, and how
quickly a sample that ends dies away. They are used under OpenMPT's licence, the BSD 3-Clause, set
out below under "OpenMPT — FM Tracker files".

## OpenMPT — SymMOD files

`Sources/SidayTrackers/ImpulseTracker/SymMODFile.swift`, `SymMODSamples.swift`, `SymMODModule.swift` and
`SymMODRenderer.swift`, which read a module of Symphonie's or Symphonie Pro's into the shape Impulse
Tracker's replayer plays, are made after OpenMPT's loader of that format (`soundlib/Load_symmod.cpp`,
by Devin Acker and the OpenMPT developers, which follows Patrick Meng's own Java player and
Symphonie's Amiga source): the layout of the file, how its parts are packed, what its events,
sequences and instruments are taken to mean, and everything done to an instrument's sample, the
mixing of its virtual instruments and the blending of its transwave ones among it. With them, the
kinds of sound file those samples are kept in, as OpenMPT reads them (`soundlib/SampleFormats.cpp`,
`soundlib/WAVTools.cpp`, `soundlib/SampleIO.cpp`, `soundlib/ModSampleCopy.h`), what it does to a
sample's sound (`soundlib/modsmp_ctrl.cpp`, `soundlib/ModSample.cpp`), the mixing a virtual
instrument is made by (`soundlib/IntMixer.h`, `soundlib/MixerInterface.h`,
`src/openmpt/soundbase/SampleConvertFixedPoint.hpp`), and where a speed is put on a pattern's row
(`soundlib/pattern.cpp`). `IT2Symphonie.swift`, and the lines in `IT2Player.swift`, `IT2Effects.swift`
and `IT2Mixer.swift` that are marked as Symphonie's, follow what OpenMPT's player does for these
files and for no file of its own (`soundlib/Snd_fx.cpp`, `soundlib/Sndmix.cpp`,
`soundlib/Fastmix.cpp`, `soundlib/ModChannel.cpp`): a sample stopped and let go on, a start by
256ths of a sample, a slide to a note in no time, a vibrato and a tremolo that go on by themselves,
and the filter turned about by a macro. They are used under OpenMPT's licence, the BSD 3-Clause, set
out below under "OpenMPT — FM Tracker files".

## OpenMPT — IMF files

`Sources/SidayTrackers/ImpulseTracker/IMFFile.swift`, which reads an Imago Orpheus module into the shape
Impulse Tracker's replayer plays, is made after OpenMPT's loader of that format
(`soundlib/Load_imf.cpp`, which Storlek wrote for Schism Tracker and the OpenMPT developers took up):
the layout of the file, the checks it is held to, and what its commands, instruments, envelopes and
samples are taken to mean, with how OpenMPT turns an envelope of that kind into Impulse Tracker's
(`soundlib/ModInstrument.cpp`). `OpenMPTCell.swift` is how OpenMPT's loaders put two commands into
one cell (`soundlib/modcommand.cpp`). `IT2OpenMPTForeign.swift`, and the lines in `IT2Player.swift`,
`IT2Effects.swift` and `IT2Mixer.swift` that are marked as Imago Orpheus's, follow what OpenMPT's
player does for these files and not for an IT file (`soundlib/Snd_fx.cpp`, `soundlib/Sndmix.cpp`
and the filter's cutoffs in `soundlib/Snd_flt.cpp`). They are used under OpenMPT's licence, the BSD
3-Clause, set out below under "OpenMPT — FM Tracker files".

## OpenMPT — AMS files

`Sources/SidayTrackers/ImpulseTracker/AMSFile.swift`, which reads a module of Velvet Studio's or of
Extreme's Tracker into the shape Impulse Tracker's replayer plays, is made after OpenMPT's loader of
those formats (`soundlib/Load_ams.cpp`): the layout of both kinds of file, the checks they are held to,
what their commands, instruments, envelopes, shadows and samples are taken to mean, how a note's commands
are put into one cell, and how a packed sample is unpacked (`AMSUnpack`), with how a ProTracker command
is taken (`soundlib/MODTools.cpp`, `soundlib/modcommand.cpp`). The lines in `IT2OpenMPTForeign.swift` and
in the replayer that are marked as Velvet Studio's follow what OpenMPT's player does for these files
(`soundlib/Snd_fx.cpp`, `soundlib/Sndmix.cpp`): their envelope for pitch, their key let go, and their
samples played backwards. They are used under OpenMPT's licence, the BSD 3-Clause, set out below under
"OpenMPT — FM Tracker files".

## libxmp and OpenMPT — MDL files

`Sources/SidayTrackers/ImpulseTracker/MDLFile.swift`, which reads a Digitrakker module into the shape
Impulse Tracker's replayer plays, is made after OpenMPT's loader of that format
(`soundlib/Load_mdl.cpp`: the layout of the file, what its commands are taken to mean, how two of
them share a note, and how a packed sample is unpacked, in `soundlib/SampleIO.cpp`) and libxmp's
(`src/loaders/mdl_load.c`, with the description of the packing that came with Digitrakker, which it
quotes). `IT2Digitrakker.swift`, and the lines in the replayer that are there for these files and
say so, are made after what OpenMPT's `soundlib/Snd_fx.cpp` and `soundlib/Sndmix.cpp` do for a
module of that kind, with the table of 64 steps of a wave and the one at random from its
`soundlib/Tables.cpp`. Both are used under the licences set out above, under "libxmp and OpenMPT —
reading MTM, DTM and AMF files", and below, under "OpenMPT — FM Tracker files".

## OpenMPT — J2B files

`Sources/SidayTrackers/ImpulseTracker/J2BFile.swift`, which reads a Jazz Jackrabbit 2 module of the Galaxy
Sound System into the shape Impulse Tracker's replayer plays, is made after OpenMPT's loader of that
format (`soundlib/load_j2b.cpp`, by Johannes Schultz, largely after the J2B loader of kode54's DUMB):
the header around the packed file and the checks it is held to, the layout of the two kinds of RIFF
file inside, and what their commands, instruments, envelopes and samples are taken to mean. The lines
in `IT2OpenMPT.swift` that are there for these files follow what OpenMPT's `soundlib/Snd_fx.cpp` does
with a vibrato after a note. They are used under OpenMPT's licence, the BSD 3-Clause, set out below
under "OpenMPT — FM Tracker files".

## OpenMPT — DMF files

`Sources/SidayTrackers/ImpulseTracker/DMFFile.swift`, which reads an X-Tracker module into the shape
Impulse Tracker's replayer plays, is made after OpenMPT's loader of that format
(`soundlib/Load_dmf.cpp`: the layout of the file and the lengths its early versions wrote wrongly,
how its patterns are made for each place in the list, how its tempo, timings and commands are taken
to mean Impulse Tracker's, and how a packed sample is unpacked), with what that loader calls on to
put several commands in one cell (`ModCommand::FillInTwoCommands`, `ConvertToVolCommand` and
`GetEffectWeight` in `soundlib/modcommand.cpp`, and `CPattern::WriteEffect` in
`soundlib/pattern.cpp`). `IT2XTracker.swift`, and the lines in the replayer that are there for these
files and say so, are made after what OpenMPT's `soundlib/Snd_fx.cpp`, `soundlib/Sndmix.cpp` and
`soundlib/Sndfile.cpp` do for a module of that kind: its tremolo, its vibrato's first tick, its cut,
its two commands that an IT file has not, and how long its ticks are. They are used under OpenMPT's
licence, the BSD 3-Clause, set out below under "OpenMPT — FM Tracker files".

## OpenMPT — PLM files

`Sources/SidayTrackers/ImpulseTracker/PLMFile.swift`, which reads a Disorder Tracker 2 module into the
shape Impulse Tracker's replayer plays, is made after OpenMPT's loader of that format
(`soundlib/Load_plm.cpp`): the layout of the file, how its patterns are laid on its song and the
song cut into patterns, and what its commands are taken to mean. `IT2DisorderTracker.swift`, and the
lines in `IT2Effects.swift` that are there for these files and say so, follow what OpenMPT's
`soundlib/Snd_fx.cpp` does for a module of that kind. They are used under OpenMPT's licence, the BSD
3-Clause, set out below under "OpenMPT — FM Tracker files".

## OpenMPT — DSM files

`Sources/SidayTrackers/ScreamTracker/DSMFile.swift`, which reads a DSM file of the Digital Sound Interface
Kit into an S3M file for Scream Tracker 3's replayer, is made after OpenMPT's loader of that format
(`soundlib/Load_dsm.cpp`): the layout of the file, how its samples are kept, and what its commands
are taken to mean. The lines in `ST3Player.swift` that are there for these files and say so follow
what OpenMPT's `soundlib/Snd_fx.cpp` does for a module of that kind and not for an S3M file. They are
used under OpenMPT's licence, the BSD 3-Clause, set out below under "OpenMPT — FM Tracker files".

## OpenMPT — MASI files

`Sources/SidayTrackers/ScreamTracker/MASIFile.swift`, which reads a PSM file of Epic MegaGames' MASI, of
the older kind and the newer, into an S3M file for Scream Tracker 3's replayer, is made after
OpenMPT's loader of that format (`soundlib/Load_psm.cpp`): the layout of both kinds of file and of
Sinaria's, the program each song of a newer file is, how the samples are kept, and what the commands
are taken to mean. The lines in `ST3Player.swift`, `ST3Cards.swift` and `ST3Effects.swift` that are
there for these files and say so (the songs, each with its own list, speed, tempo and places, and
the channels in surround) follow what OpenMPT does for a module of that kind. They are used under
OpenMPT's licence, the BSD 3-Clause, set out below under "OpenMPT — FM Tracker files".

## OpenMPT — DIGI files

`Sources/SidayTrackers/FastTracker/DIGIFile.swift`, which reads a DIGI Booster module into what
FastTracker 2's replayer plays, is made after OpenMPT's loader of that format (`soundlib/Load_digi.cpp`):
the layout of the file, how its patterns are packed or not, and what its commands are taken to mean.
`FT2DigiBooster.swift`, and the lines in `FT2Replayer.swift` and `FT2Player.swift` that are there
for these files and say so, follow what OpenMPT's `soundlib/Snd_fx.cpp` and `soundlib/Sndmix.cpp` do
for a module of that kind, with its wave for vibrato and tremolo. They are used under OpenMPT's
licence, the BSD 3-Clause, set out below under "OpenMPT — FM Tracker files".

## OpenMPT — MPTM files

`Sources/SidayTrackers/ImpulseTracker/MPTMFile.swift` reads an MPTM file, OpenMPT's own kind of module,
as OpenMPT (https://openmpt.org) reads it: the parts of the file that are OpenMPT's own and no IT
file has (`soundlib/Load_it.cpp`, `ITTools.cpp`, `InstrumentExtensions.cpp`, `ModSequence.cpp`,
`pattern.cpp`, `patternContainer.cpp`, `tuning.cpp`, `tuningCollection.cpp` and
`common/serialization_utils.cpp`), and what OpenMPT changes in a file that an older version of
itself saved (`soundlib/UpgradeModule.cpp`). `IT2OpenMPT.swift`, and the lines in `IT2Player.swift`,
`IT2Effects.swift` and `IT2Mixer.swift` that are marked as an MPTM file's, are what Impulse Tracker's
replayer has been given so as to play such a file, and follow OpenMPT's player in what they do: its
three ways of keeping time, its swing and its tempos that are fractions (`CSoundFile::GetTickDuration`
in `soundlib/Sndfile.cpp`); its values that go on into the rows below a command, its delayed and cut
note, its offsets by cue point, and its sample played backwards (`soundlib/Snd_fx.cpp`); the point an
envelope goes to when a key is let go, the filter that lets the high through, and where a channel to
one side is put (`soundlib/Sndmix.cpp`, `Snd_flt.cpp`). `OpenMPTTuning.swift` is OpenMPT's tunings
(`soundlib/tuning.cpp`), and the lines of `IT2OpenMPT.swift` for a tuned instrument are how its
player moves such a note (`soundlib/Snd_fx.cpp`, `Sndmix.cpp`). `IT2Periods.swift` is how its player
keeps a note's pitch as a period, for a file that asks for that and for a module of Digitrakker's,
and how it slides one kept in hertz (`soundlib/Snd_fx.cpp`, `Sndmix.cpp`, with the tables of
`Tables.cpp`). Changed from the original:
carried over from C++ to Swift; none of OpenMPT's own player is here, only these parts of it set
into another replayer, which plays the rest as Impulse Tracker would; and of the many ways of
playing that a file can ask OpenMPT for, one by one, only the few that the source names are
followed. Used under the BSD 3-Clause licence set
out below, under "OpenMPT — FM Tracker files": Copyright (c) 2004-2026 OpenMPT Project Developers and
Contributors and Copyright (c) 1997-2003 Olivier Lapicque.

## OpenMPT — commands of later trackers in IT, S3M and XM files

A file of one of the old trackers' kinds that a later tracker made may have commands its own tracker
never had. Some of them are played, by OpenMPT's rules (`soundlib/Snd_fx.cpp`, `Sndmix.cpp`): in an IT
file, a sample played backwards and a macro sent a little at a time over a row (`IT2OpenMPT.swift`, as
for an MPTM file); and such a file, and an MPTM file, is heard through ModPlug Tracker's own filter where
it was made with it (`setOwnFilter` and the rule for when a voice has it in
`Sources/SidayTrackers/ImpulseTracker/IT2Mixer.swift`, after `SetupChannelFilter` in
`soundlib/Snd_flt.cpp` and `HandleNoteChangeFilter` in `Sndmix.cpp`; the signs by which a file is known
for one, and the ways of playing it asks for, in `modPlugWays` and `ModPlugWays` in `IT2Module.swift`,
after `soundlib/Load_it.cpp` and `UpgradeModule.cpp`), with its filter moved at random from note to note
(`ApplyRandomValues` in `IT2Player.swift`, after `NoteChange` in `Snd_fx.cpp`) and its envelopes carried
on and started again by ModPlug Tracker's rules (`InstrumentChange` there), with its voices read between
a sample's points in OpenMPT's ways, by the instrument's choice or the song's or else OpenMPT's own
(`Sources/SidayTrackers/ImpulseTracker/IT2Resampling.swift` and the tables it gives `IT2Mixer.swift`,
after `soundlib/IntMixer.h` and `Sndmix.cpp`, with the curve of `soundlib/Tables.cpp` and the windowed
sinc of `WindowedFIR.cpp`; the same for an MPTM file), and what it says of its instruments found where
OpenMPT finds it (`extrasPlace` in `IT2Module.swift`, after `soundlib/Load_it.cpp`); in an S3M file, a
channel's volume, a slide of it and a slide of the whole tune's (`laterCommand` in
`Sources/SidayTrackers/ScreamTracker/ST3Effects.swift`); in an XM file, a sweep from side to side
(`sweepFromSideToSide` in `Sources/SidayTrackers/FastTracker/FT2Replayer.swift`, with its two tables of
64 numbers in `FT2Tables.swift`, which are OpenMPT's `ModSinusTable` and `ModRandomTable` from
`soundlib/Tables.cpp`) and a channel's filter, set by macros (`sendFilterMacro` there, and `setFilter`
and the filter's line in the mixer in `FT2Player.swift`, after `soundlib/Snd_flt.cpp` and the mixer's own
filter, and `dieAway` there, after `EndChannelOfs` and `StereoFill` in `soundlib/MixerLoops.cpp`, with
its voices read between a sample's points through OpenMPT's ways, as for an IT file of theirs (`FT2Edges`
there, after `PrecomputeLoops` in `soundlib/ModSample.cpp`)). The first of the signs by which an XM file
is taken not to be FastTracker's own are those of `soundlib/Load_xm.cpp`. Changed from the original:
carried over from C++ to Swift, and each set into another tracker's replayer, which plays the rest as
that tracker would. Used under the BSD 3-Clause licence set out below, under "OpenMPT — FM Tracker
files": Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and Copyright (c) 1997-2003
Olivier Lapicque.

## OpenMPT — FM instruments and built-in plug-ins

Three more things in this player are made from OpenMPT (https://openmpt.org), and are for the files
of OpenMPT and of ModPlug Tracker before it: MPTM files, and IT files that say one of the two made
them.

`Sources/SidayTrackers/ImpulseTracker/IT2AdLib.swift` plays an instrument that is a patch for the AdLib's
FM chip as OpenMPT plays one: how it gives the chip's eighteen voices out to notes, and what it sets
the chip's registers to for a note's patch, pitch, level and side (`soundlib/OPL.cpp` and `OPL.h`),
and when it does each (`soundlib/Snd_fx.cpp`, `soundlib/Sndmix.cpp`). Changed from the original:
carried over from C++ to Swift; what OpenMPT does as each thing happens to a note is done here once
a tick, from what Impulse Tracker's replayer has made of its voices by then, so that the chip is
left set as OpenMPT leaves it; the chip itself is Nuked OPL3 (below) where OpenMPT's is Opal; and a
note's pitch is Impulse Tracker's replayer's, which is not in every case OpenMPT's.

`Sources/SidayTrackers/OpenMPT` has OpenMPT's own effects, which are its remakes of the effects that came
with Windows as DirectX Media Objects, and three more: `OpenMPTEcho.swift`, `OpenMPTChorus.swift` (the
chorus and both flangers), `OpenMPTGargle.swift`, `OpenMPTWavesReverb.swift`,
`OpenMPTI3DL2Reverb.swift`, `OpenMPTDistortion.swift`, `OpenMPTParamEq.swift` and
`OpenMPTCompressor.swift`, with `OpenMPTDMOUtils.swift`, from `soundlib/plugins/dmo/Echo.cpp`,
`Chorus.cpp`, `Flanger.cpp`, `Gargle.cpp`, `WavesReverb.cpp`, `I3DL2Reverb.cpp`, `Distortion.cpp`,
`ParamEq.cpp`, `Compressor.cpp` and `DMOUtils.cpp`; `OpenMPTDigiBoosterEcho.swift` from
`soundlib/plugins/DigiBoosterEcho.cpp`; `OpenMPTSymMODEcho.swift` from
`soundlib/plugins/SymMODEcho.cpp`; and `ModPlugReverb.swift`, the reverb of ModPlug's own mixer and
not a plug-in, from `sounddsp/Reverb.cpp` and `Reverb.h` (its plain C path only: not the SSE2 one,
nor the two functions for a reverb at half the rate, which the original never calls).
`OpenMPTEffect.swift` is what the plug-ins have in common (`soundlib/plugins/PlugInterface.h`).
Changed from the originals: carried over from C++ to Swift, each as a class that is given sound and
gives sound back and knows nothing of OpenMPT's mixer; their
delay lines are laid out once and nothing is allocated while they play; the six powers of 0.93 that
set the lengths of the I3DL2 reverb's late delays are written out as the numbers they come to, so
that no maths library can make a delay a sample longer or shorter; a few loops are written to go
faster without changing a sum or its order; and where the original is undefined (a number too large
for the whole number it is cut to, a delay outside its line) the port does what ARM does, or stays
inside.

`OpenMPTPlugIns.swift` in the same folder sends sound through a song's plug-ins as OpenMPT does:
which plug-in a voice goes to, a plug-in's sound going on to another or to the listener, one put on
the whole sound, and how what it makes is put together with what it was given (`ProcessPlugins` and
`MixChannel` in `soundlib/Fastmix.cpp`, `GetBestPlugin` in `soundlib/Snd_fx.cpp`, `ProcessMixOps`
and `RecalculateGain` in `soundlib/plugins/PlugInterface.cpp`). `ModPlugSound.swift` reads a
plug-in from a file and finds which of OpenMPT's own it is (`ReadMixPluginChunk` in
`soundlib/Load_it.cpp`, `soundlib/plugins/PluginStructs.h`, and `CreateMixPlugin` and the list of
built-in plug-ins in `soundlib/plugins/PluginManager.cpp`), and how OpenMPT changes a plug-in's
settings as a tune plays is in `IT2OpenMPT.swift` and `IT2Player.swift` (parameter control notes and
the MIDI macros that address a plug-in, `soundlib/Snd_fx.cpp`). Changed from the original: carried
over from C++ to Swift, and set into Impulse Tracker's mixer, which mixes in floating point and a
tick at a time; only OpenMPT's own effects are there to be run, and a place whose plug-in is
anything else is treated as OpenMPT treats one whose plug-in it cannot find.

All of it is used under the BSD 3-Clause licence set out below, under "OpenMPT — FM Tracker files":
Copyright (c) 2004-2026 OpenMPT Project Developers and Contributors and Copyright (c) 1997-2003
Olivier Lapicque.

## Nuked OPL3 — the FM chip of the AdLib and Sound Blaster cards

`Sources/SidayChips/OPL3/OPL3Chip.swift` and `OPL3Tables.swift` are a Swift port of Nuked OPL3 1.8, an
emulator of the Yamaha YMF262 (OPL3), which also plays what was written for the YM3812 (OPL2). The
port leaves out the original's own resampling and its optional stereo extension, and adds one
shortcut that changes no number: the operators of the chip's second register set are not worked
through until something is written there.

- Copyright (C) 2013-2020 Nuke.YKT
- Its thanks: the MAME Development Team (Jarek Burczynski, Tatsuyuki Satoh) for feedback and rhythm
  part calculation information; forums.submarine.org.uk (carbon14, opl3) for tremolo and phase
  generator calculation information; OPLx decapsulated (Matthew Gambrell, Olli Niemitalo) for the
  OPL2 ROMs; siliconpr0n.org (John McMaster, digshadow) for YMF262 and VRC VII decaps and die shots
- GNU Lesser General Public License, version 2.1 or later. As its section 3 allows, the port is
  distributed under the GNU General Public License, version 2 or later, with the rest of this project
- Source: https://github.com/nukeykt/Nuked-OPL3

## libADLMIDI — General MIDI on the FM chip

`Sources/SidayEightBit/MIDI/ADLMIDISynth.swift` and `MIDIFMRenderer.swift` are a Swift port of
libADLMIDI 1.6.2.1's MIDI player and OPL3 driver (`src/adlmidi_midiplay.cpp`, `src/adlmidi_opl3.cpp`,
and the playing loop of `src/adlmidi.cpp`). `Sources/SidayMIDI` follows its sequencer's rules
(`src/midiseq`) and the volume model of Windows 9x (`src/models/model_win9x.c`, with the brightness
table of `model_generic.c`).

- Copyright (c) 2010-2014 Joel Yliluoma (ADLMIDI), (c) 2015-2026 Vitaly Novichkov
- The player and driver: GNU General Public License, version 3 or later ("Other parts of library are
  licensed under GPLv3+", its README). The sequencer and the volume models: MIT licence
- Source: https://github.com/Wohlstand/libADLMIDI

The instruments are The Fat Man's two-operator General MIDI set, as libADLMIDI 1.6.2.1 carries it
(`fm_banks_new/fatman-2op.woplx`, with `LICENSE-TheFatMan.txt`), in `FatManBank.swift`, which holds its
full notice.

- "Tone libraries for OPL2 and OPL3 chips produced by The Fat Man. Developed by K. Weston Phelan and
  George Alistair Sanger. Copyright (c) 1993-2025 The Fat Man (TM)"
- MIT licence

## Munt — the MT-32's synthesiser

`Sources/SidayMT32` is a Swift port of mt32emu, from libmt32emu 2.8.3 (tag `libmt32emu_2_8_3`):
`Synth.cpp`, `Part.cpp`, `Partial.cpp`, `PartialManager.cpp`, `Poly.cpp`, `TVA.cpp`, `TVF.cpp`, `TVP.cpp`,
`LA32Ramp.cpp`, `LA32WaveGenerator.cpp` (the integer one), `BReverbModel.cpp` (the integer one),
`Analog.cpp`, `Tables.cpp` (as numbers), `Structures.h` and `MemoryRegion.h`. The table of ROMs by their
SHA-1 digests comes from `ROMInfo.cpp`.

- Copyright (C) 2003, 2004, 2005, 2006, 2008, 2009 Dean Beeler, Jerome Fisher; Copyright (C) 2011-2024
  Dean Beeler, Jerome Fisher, Sergey V. Mikayev
- GNU Lesser General Public License, version 2.1 or (at your option) any later version
- Source: https://github.com/munt/munt

The ROMs it plays are Roland's. They are not part of siday: a listener gives them to the player.

## SAASound — the SAA1099

`Sources/SidayEightBit/SAA1099/SAA1099.swift` is a Swift port of SAASound
(https://github.com/stripwax/SAASound), Dave Hooper's emulation of the Philips SAA1099: its oscillators
and when what is written to them is taken up, its noise, its envelopes, and how a channel's mixer, volume
and envelope make its level. It is stepped at a rate of its own and not as SAASound steps it, and two
things are otherwise than in SAASound: each channel swings either side of nought, and an offset written
on its own is not held for a half of the wave more (see FORMATS.md, under VGM).

```
SAASound - a portable Phillips SAA 1099 sound chip emulator

Copyright (c) 1998-2004, Dave Hooper <dave@beermex.com>
Copyright (c) 2004-2025, Dave Hooper <dave@beermex.com> + Simon Owen <simon@simonowen.com>
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

- Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

- Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

- Neither the name Dave Hooper nor the names of its contributors may
  be used to endorse or promote products derived from this software without
  specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## MAME — the SN76489

`Sources/SidayChips/SN76489/SN76489.swift` is a Swift port of MAME's emulation of Texas Instruments'
SN76489 and the chips made like it (`sn76496.c`), as libvgm has it (https://github.com/ValleyBell/libvgm,
`emu/cores/sn76496.c`): its registers, its tones, its noise in each chip's kind, and its volumes. The
way what the chip makes is brought to the player's rate is not MAME's but ayumi's (see above), and
the Game Gear's sides and a channel's samples are worked out as libvgm's copy does.

- By Nicola Salmoria, with contributions by others: Sebastien Chevalier, Lord Nightmare, Michael
  Zapf, PlgDavid, Enik, Justin Kerk, Nemesis, Qbix, Valley Bell and NewRisingSun among them
- Source: https://github.com/mamedev/mame (`src/devices/sound/sn76496.cpp`)

```
BSD 3-Clause License

Copyright (c) Nicola Salmoria
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## fmdrv — Creative's driver for CMF files

`Sources/SidayEightBit/OPL/SBFMDriver.swift` and `SBFMTables.swift` are a Swift port of fmdrv
(https://github.com/viiri/fmdrv), a C port of SBFMDRV, the driver for the FM chip that came with the
Sound Blaster. Changed from the original: carried over from C to Swift; made to stop at the end of a
file's music, where the original reads on; made to leave alone a tune that has no instruments, where
the original divides by nothing; and the chip it plays on is this project's and not the one fmdrv
comes with.

- Copyright 2024 Sergei "x0r" Kolzun
- Apache License, Version 2.0, below. That licence can be combined with version 3 of the GNU General
  Public License and not with version 2, so with these files in it this project as a whole is
  distributed under version 3 or later, which its own "version 2 or later" allows
- Source: https://github.com/viiri/fmdrv

```
Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided Your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS

   APPENDIX: How to apply the Apache License to your work.

      To apply the Apache License to your work, attach the following
      boilerplate notice, with the fields enclosed by brackets "{}"
      replaced with your own identifying information. (Don't include
      the brackets!)  The text should be enclosed in the appropriate
      comment syntax for the file format. We also recommend that a
      file or class name and description of purpose be included on the
      same "printed page" as the copyright notice for easier
      identification within third-party archives.

   Copyright 2017 Sergei "x0r" Kolzun

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
```

## AdPlug — ROL files and AdLib's sound driver

`Sources/SidayEightBit/OPL/ROLTune.swift` is a Swift port of AdPlug's ROL player (`rol.cpp`), and
`AdLibDriver.swift` of the sound driver under it (`composer.cpp`), which follows the `ADLIB.C` of
AdLib's programming kit. The port finds an instrument in any of several banks and in one of its own,
where AdPlug reads one bank file.

- Copyright (C) 1999 - 2006 Simon Peter <dn.tlp@gmx.net>, et al.
- ROL player and Visual Composer synth class by OPLx <oplx@yahoo.com>, with improvements by Stas'M
  <binarymaster@mail.ru> and Jepael
- GNU Lesser General Public License, version 2.1 or later. As its section 3 allows, the port is
  distributed under the GNU General Public License, version 2 or later, with the rest of this project
- Source: https://github.com/adplug/adplug

## AdLib instrument banks

`Sources/SidayEightBit/OPL/AdLibBankData.swift` holds 9,683 instruments for the FM chip by name, each as
the eleven numbers the chip is given for it, packed by `Scripts/pack-bank.swift` from bank files
(`.BNK`):

- `STANDARD.BNK`, the 145 instruments that came with AdLib's Visual Composer (Ad Lib Inc., 1987 to 1989);
- a dozen enlarged banks that were passed around with collections of ROL files in the years after,
  each AdLib's with other people's instruments added: several more called `STANDARD.BNK`, and
  `BNK356.BNK`, `BNK835.BNK`, `MORE1.BNK`, `TMC-BANK.BNK`, `DOCSRR10.BNK` and `ROLDEMO.BNK`;
- `implay.bnk`, the bank of the player IMPlay, and two banks made for single tunes, for the names
  the others have not got. `implay.bnk` and one of the two are from AdPlug's test files.

None of them states a licence. Ad Lib Inc. went bankrupt in 1992; the banks were made to be shared
among the people who wrote and played these tunes, and have been ever since.

## OpenMPT — FM Tracker files

`Sources/SidayEightBit/OPL/FMTTune.swift` reads the songs of Davey W Taylor's FM Tracker as OpenMPT's
loader for them does (`soundlib/Load_fmt.cpp`), and plays them as OpenMPT plays the module that
loader makes: the sums by which a note becomes the chip's octave and number
(`CSoundFile::GetPeriodFromNote` and `GetFreqFromPeriod` in `Snd_fx.cpp`, `CSoundFile::ReadNote` in
`Sndmix.cpp`, `OPL::Frequency` in `OPL.cpp`), and how a note is struck and stopped. Changed from the
original: carried over from C++ to Swift, as a small player of its own with nothing of OpenMPT's
module player around it; the clock is the PC's timer at its real rate, where OpenMPT's tempo is 18.2
ticks a second; a song ends where OpenMPT goes round; and the chip it plays on is this project's and
not the one OpenMPT comes with.

- Copyright (c) 2004-2026, OpenMPT Project Developers and Contributors
- Copyright (c) 1997-2003, Olivier Lapicque
- BSD 3-Clause License, below
- Source: https://github.com/OpenMPT/openmpt

```
Copyright (c) 2004-2026, OpenMPT Project Developers and Contributors
Copyright (c) 1997-2003, Olivier Lapicque
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the OpenMPT project nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Ice 2.4 — unpacking SNDH files

`Sources/SidayAtari/ICE.swift` follows the "Ice 2_40 depacker, universal C version" that Hans
Wessels placed in the public domain in 2007, as it is distributed with AtariAudio.

## superzazu/z80 — Z80 cycle counts

The cycle-count tables in `Sources/SidayEightBit/Z80/Z80.swift` follow those of superzazu/z80
(https://github.com/superzazu/z80), which the core was also checked against.

```
MIT License

Copyright (c) 2019 Nicolas Allemand

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## ancient — unpacking XPK, MMCMP and zlib's DEFLATE

`Sources/SidayAmigaTrackers/Packers/XPK.swift` (XPK files, and their SQSH, NUKE and DUKE packers),
`Sources/SidayAmigaTrackers/Packers/MMCMP.swift` and `Sources/SidayFoundation/Inflate.swift` (DEFLATE and
the zlib stream around it, which J2B files are packed with; written also after RFC 1950 and RFC 1951,
which describe them) follow the decompressors in ancient (https://github.com/temisu/ancient) by
Teemu Suutari:

```
BSD 2-Clause License

Copyright (c) 2017-2026, Teemu Suutari
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## ar002 — LH5 unpacking

`Sources/SidayFoundation/LH5.swift` follows the decoder in ar002 by Haruhiko Okumura, which its author
placed in the public domain.

## OpenMPT and UNMO3 — MO3 files

`Sources/SidayCodecs/MO3` reads MO3 files as libopenmpt 0.8.9's loader does (`soundlib/Load_mo3.cpp`):
its unpacking of the music and of the samples, and what it makes of each part of the file. Changed from
the original: carried over from C++ to Swift, into a model of the module of siday's own, which is then
written again as the IT, MPTM, XM, S3M, MOD or MTM file it was made from, as OpenMPT's savers lay those
files out, for siday's own replayers to play. The loader is based on the documentation and the unpacking
of the UNMO3 project, relicensed to the BSD license with Laurent Clévy's permission, as the loader says.

- Copyright (c) 2004-2026, OpenMPT Project Developers and Contributors (Load_mo3.cpp by Johannes Schultz
  and OpenMPT's developers)
- UNMO3 by Laurent Clévy: https://github.com/lclevy/unmo3
- BSD 3-Clause License, as for FM Tracker files above
- Source: https://github.com/OpenMPT/openmpt

## stb_vorbis — Ogg Vorbis

`Sources/SidayCodecs/Vorbis` is a Swift port of stb_vorbis 1.22, the decoder of Ogg Vorbis, as libopenmpt
0.8.9 ships it and builds it: its push-data decoder only (`STB_VORBIS_NO_PULLDATA_API`,
`STB_VORBIS_NO_STDIO`). It decodes what the original decodes, to the bit. It plays Ogg Vorbis files,
and the samples MO3 files keep as Ogg Vorbis.

- Written by Sean Barrett, from 2007, with the contributors its file names; first sponsored by RAD Game
  Tools
- Public domain, or the MIT License (Copyright (c) 2017 Sean Barrett), at the user's choice
- Source: https://github.com/nothings/stb

## minimp3 — MPEG audio

`Sources/SidayCodecs/MP3` is a Swift port of minimp3, the decoder of MPEG audio's three layers, as
OpenMPT's fork of it is in libopenmpt 0.8.9, without its vector instructions; and of the rules of its
`minimp3_ex.h` by which a file's tags are skipped and an encoder's delay and padding are taken off. It
decodes what the original decodes, to the bit. It plays MP3 and MP2 files, and the samples MO3 files
keep as MP3.

- By lieff and the contributors to https://github.com/lieff/minimp3; OpenMPT's fork is
  https://github.com/manxorist/minimp3
- CC0 1.0: dedicated to the public domain
- Source: https://github.com/lieff/minimp3

## High Voltage SID Collection — song lengths

`Sources/SidayC64/SIDFile/SongLengthsData.swift` holds the play time of every song of every tune in
release 85 of the [High Voltage SID Collection](https://www.hvsc.c64.org), packed from the
`Songlengths.md5` in its `DOCUMENTS` folder by `Scripts/pack-songlengths.swift`. The times are the work
of the collection's team. The table has the times and part of each SID file's MD5, and nothing of the
tunes themselves. The collection's documents give no licence for the file; it is published for players
to use, and players commonly carry it.

## Reference material

- The SID file format and environment follow `SID_file_format.txt` from the High Voltage SID Collection.
- The `.ay` format follows the ZXAYEMUL description by Patrik Rak and Sergey Bulba.
- The 6510 core was written for this project and verified with SingleStepTests/65x02.
- What DigiBooster Pro's commands are, and which of them DigiBooster 3's replayer leaves out, is from
  `DigiBooster_E.guide`, the guide that came with DigiBooster Pro 2.21.
