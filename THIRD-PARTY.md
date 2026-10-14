# Third-party work

This project is licensed under the GNU General Public License, version 2 or (at your option) any later
version; see `LICENSE`. It is built on the work of others, used under the terms below.

## reSIDfp — the SID chip

`Sources/SidayKit/SIDChipFP` is a Swift port of reSIDfp, the MOS 6581/8580 SID emulator engine of
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

`Sources/SidayKit/SIDChip` is a Swift port of reSID 1.0, a MOS 6581/8580 SID emulator engine, kept as
`--sid-engine resid`.

- Copyright (C) 2010 Dag Lem <resid@nimrod.no>
- GNU General Public License, version 2 or later
- Source: https://github.com/libsidplayfp/resid

## libsidplayfp — C64 start-up

`Sources/SidayKit/C64/PSIDDriver.swift` contains libsidplayfp's PSID driver (`psiddrv.a65`) in assembled
form, and `Sources/SidayKit/C64/PowerOnMemory.swift` its power-on memory pattern (`poweron.bin`). The
ROM stand-ins, start-up state and timer and video timing rules in `Sources/SidayKit/C64` and
`Sources/SidayKit/SIDFile/SIDRenderer.swift` follow libsidplayfp's behaviour.

- Driver: Copyright 2014 Leandro Nini, Copyright 2001-2004 Simon White, Copyright 2000 Dag Lem
- Power-on pattern and its loader: Copyright 2011-2015 Leandro Nini, Copyright 2007-2010 Antti Lankila,
  Copyright 2001 Simon White
- GNU General Public License, version 2 or later
- Source: https://github.com/libsidplayfp/libsidplayfp

## Ay_Emul — tracker players, register recordings and AY files

The players in `Sources/SidayKit/Trackers`, the VTX and YM handling in `Sources/SidayKit/Dumps` and the
machine rules in `Sources/SidayKit/AYFile` are ported from, or follow, the source code of Ay_Emul
("AY-3-8910/12 Emulator").

- (c) 1999-2026 Sergey Vladimirovich Bulba <svbulba@gmail.com>
- Terms, from the source archive's readme: "You can use this source code freely, only do references to
  author (Sergey Bulba)."
- Home page: http://ay.strangled.net/

## ayumi — the AY/YM chip

`Sources/SidayKit/AYChip` is a Swift port of ayumi (https://github.com/true-grue/ayumi).

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

`Sources/SidayKit/Atari` is a Swift port of AtariAudio 1.26 (https://github.com/arnaud-carre/AtariAudio):
the machine as a tune needs it (`STMachine.swift`), its YM2149 (`STSoundChip.swift`), its timer chip
(`MFP.swift`), the STE's sample player (`STESound.swift`), the reading of an SNDH file's header, and
the playing of Atari ST YM files with their effects (`STYMRenderer.swift`) and of digi-mix and YM
tracker files (`STSampleRenderer.swift`). `YM2Drums.swift` is AtariAudio's bank of the drum samples
that YM2 files call on by number.
`STMixTable.swift` is AtariAudio's table of how an Atari ST mixes its sound chip's three channels,
which its source says was measured and generated on real hardware by Paulo Simões and filled in
between the measured levels by Arnaud Carré. The 68000 is not AtariAudio's (it uses Musashi): it was
written for this project, and is in `Sources/SidayKit/M68000`.

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

## pt2-clone — the Amiga

`Sources/SidayKit/Amiga` is a Swift port of the playing parts of pt2-clone 1.92
(https://github.com/8bitbubsy/pt2-clone), Olav Sørensen's re-creation of ProTracker 2.3D: its replayer,
which is a C port of ProTracker's own (`ProTrackerReplayer.swift`), its reading of 31-sample and
15-sample modules (`ProTrackerModule.swift`), and its emulation of Paula with the Amiga's filters and
its way of halving the sample rate (`Paula.swift`). The band-limited steps in Paula's output
(`PaulaStep.swift`) are credited in its source to aciddose, who wrote them for that project.
`PowerPacker.swift` follows the depacker in the same source, which says it is taken from Heikki
Orsila's amigadepack.

The player of MED modules (`Sources/SidayKit/OctaMED`) is not a port of anything: it was written for
this project, to do what OctaMED's own players do, and none of their code is in it; nor is its
mixer for OctaMED Soundstudio's mixing mode taken from anywhere. Its modules for the Amiga's voices
play on the Paula above, its renderer (`MEDRenderer.swift`) is made after `MODRenderer.swift`, and
its table of periods is built from the table in `ProTrackerReplayer.swift`, so those parts of it
stand on pt2-clone as the rest of this folder does.

Nor are the players of SoundFX modules (`Sources/SidayKit/SoundFX`) and of Oktalyzer modules
(`Sources/SidayKit/Oktalyzer`) ports of anything: they were written for this project, to do what the
trackers' own replay routines do, and none of those routines' code is in them. They play on the Paula
above, their renderers are made after `MODRenderer.swift`, and their periods are the table in
`ProTrackerReplayer.swift` (with, for SoundFX, the periods its routine has below that table's
lowest), so those parts of them stand on pt2-clone as the rest of this folder does.

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

`Sources/SidayKit/AHX` is a Swift port of ahx2play (https://github.com/8bitbubsy/ahx2play), Olav
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

`Sources/SidayKit/Hively` is a Swift port of the replayer of HivelyTracker 1.9
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

## ft2play — FastTracker 2

`Sources/SidayKit/FastTracker` is a Swift port of ft2play (https://github.com/8bitbubsy/ft2play), Olav
Sørensen's C port of the replayer and mixer of FastTracker 2.09, made directly from that tracker's
assembly and Pascal: the replayer (`FT2Replayer.swift`), the mixer (`FT2Player.swift`), the reading of
XM files and of MOD files as FastTracker reads them (`FT2Module.swift`), and FastTracker's tables
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

No code of either player is in this one, but the three loaders in `Sources/SidayKit/FastTracker` that
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

`Sources/SidayKit/ScreamTracker` is a Swift port of st3play (https://github.com/8bitbubsy/st3play),
Olav Sørensen's C port of the replayer of Scream Tracker 3.21, made from that tracker's own assembly
and C: the replayer (`ST3Player.swift`, `ST3Effects.swift`), the reading of S3M files
(`ST3Module.swift`), Scream Tracker's driver for the Gravis Ultrasound with st3play's emulation of
that card's sound chip, its mixing for the Sound Blaster Pro, and the windowed sinc that brings either
card's rate to the player's (`ST3Cards.swift`, `ST3Tables.swift`), and Scream Tracker's driver for
the AdLib card (`ST3AdLib.swift`). st3play's own OPL2 emulator is not ported: the AdLib card's chip
here is Nuked OPL3, below.

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

`Sources/SidayKit/ScreamTracker2` is a Swift port of st2play (https://github.com/viiri/st2play), a C
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

## it2play — Impulse Tracker 2

`Sources/SidayKit/ImpulseTracker` is a Swift port of it2play (https://github.com/8bitbubsy/it2play),
Olav Sørensen's C port of the replayer of Impulse Tracker 2.15, made from that tracker's own assembly:
the replayer (`IT2Player.swift`, `IT2Effects.swift`, `IT2Tables.swift`), the reading of IT files and
the unpacking of their compressed samples (`IT2Module.swift`), and the sound driver it2play adds to
Impulse Tracker's own, which mixes in floating point through a windowed sinc and has the resonant
filter (`IT2Mixer.swift`). Impulse Tracker's own drivers, and it2play's reading of S3M and MMCMP
files, are not ported. (`IT2ForeignModule.swift`, `GDMFile.swift`, `PTMFile.swift` and `ULTFile.swift`
in that folder are not from it2play: they are what gives that replayer three other kinds of file to
play, and are below.
Nor are `MPTMFile.swift`, `IT2OpenMPT.swift` and `IT2AdLib.swift`, which give it OpenMPT's own kind
of file, and what that kind of file asks of it that an IT file does not; they are below too, and the
few lines in the replayer and its mixer that are there for them say so where they stand.)

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
(`Sources/SidayKit/Composer669`) were written with theirs open: libxmp's `src/loaders/669_load.c`
and the 669 effects in its `src/effects.c`, and OpenMPT's `soundlib/Load_669.cpp` and what its
`Snd_fx.cpp` and `Sndmix.cpp` do for a module of that kind. The checks a file is held to before it
is taken for a 669 file, how far each command moves a note's pitch, the tempo, and how far to each
side the channels sit are as OpenMPT has them; where the two differ, or differ from the manuals of
Composer 669 and UNIS 669, the Swift and the README say which is followed and why. Both are used
under the licences set out above, under "libxmp and OpenMPT — reading MTM, DTM and AMF files", and
below, under "OpenMPT — FM Tracker files".

The reading and the playing of FAR files (`Sources/SidayKit/Farandole`) were written the same way,
with libxmp's `src/loaders/far_load.c` and `src/far_extras.c` open, and OpenMPT's
`soundlib/Load_far.cpp`: how the program kept time, how far each command moves a pitch or a volume,
and when a note is struck again are as libxmp has them, whose authors found them out from
Farandole Composer itself. No code of either is in it. Under the same licences.

## libxmp and OpenMPT — GDM, PTM and ULT files

`Sources/SidayKit/ImpulseTracker/GDMFile.swift`, `PTMFile.swift` and `ULTFile.swift`, which read GDM,
PTM and ULT files into the shape Impulse Tracker's replayer plays, are made after the loaders of
those formats in libxmp (https://github.com/libxmp/libxmp, `src/loaders/gdm_load.c`, `ptm_load.c`
and `ult_load.c`) and in OpenMPT (https://openmpt.org, `soundlib/Load_gdm.cpp`, `Load_ptm.cpp` and
`Load_ult.cpp`): the layout of the files, and what each of their commands is taken to mean. Neither
library's player is used. Both are used under the licences set out above, under "libxmp and OpenMPT —
reading MTM, DTM and AMF files": libxmp's the MIT licence, Copyright (C) 1996-2026 Claudio Matsuoka
and Hipolito Carraro Jr, and OpenMPT's the BSD 3-Clause licence, Copyright (c) 2004-2026 OpenMPT
Project Developers and Contributors and Copyright (c) 1997-2003 Olivier Lapicque.

## OpenMPT — C67 files

`Sources/SidayKit/ImpulseTracker/C67File.swift`, which reads a Composer 670 module into the shape
Impulse Tracker's replayer plays, is made after OpenMPT's loader of that format
(`soundlib/Load_c67.cpp`): the layout of the file, the checks it is held to, and what its notes and
volumes are taken to mean. It is used under OpenMPT's licence, the BSD 3-Clause, set out below under
"OpenMPT — FM Tracker files".

## OpenMPT — MT2 files

`Sources/SidayKit/ImpulseTracker/MT2File.swift`, which reads a MadTracker 2 module into the shape
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

## OpenMPT — MPTM files

`Sources/SidayKit/ImpulseTracker/MPTMFile.swift` reads an MPTM file, OpenMPT's own kind of module,
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
one side is put (`soundlib/Sndmix.cpp`, `Snd_flt.cpp`). Changed from the original: carried over from
C++ to Swift; none of OpenMPT's own player is here, only these parts of it set into another
replayer, which plays the rest as Impulse Tracker would; an instrument tuned to a temperament has
its notes started at the tuning's pitches and nothing more of the tuning, and a tuning further from
the usual one is not played at all; and of the many ways of playing that a file can ask OpenMPT for,
one by one, only the few that the source names are followed. Used under the BSD 3-Clause licence set
out below, under "OpenMPT — FM Tracker files": Copyright (c) 2004-2026 OpenMPT Project Developers and
Contributors and Copyright (c) 1997-2003 Olivier Lapicque.

## OpenMPT — commands of later trackers in IT, S3M and XM files

A file of one of the old trackers' kinds that a later tracker made may have commands its own
tracker never had. Some of them are played, by OpenMPT's rules (`soundlib/Snd_fx.cpp`,
`Sndmix.cpp`): in an IT file, a sample played backwards and a macro sent a little at a time over a
row (`IT2OpenMPT.swift`, as for an MPTM file); and such a file, and an MPTM file, is heard through
ModPlug Tracker's own filter where it was made with it (`setOwnFilter` and the rule for when a voice
has it in `Sources/SidayKit/ImpulseTracker/IT2Mixer.swift`, after `SetupChannelFilter` in
`soundlib/Snd_flt.cpp` and `HandleNoteChangeFilter` in `Sndmix.cpp`; the signs by which a file is
known for one, and the ways of playing it asks for, in `modPlugWays` and `ModPlugWays` in
`IT2Module.swift`, after `soundlib/Load_it.cpp` and `UpgradeModule.cpp`), with its filter moved at
random from note to note (`ApplyRandomValues` in `IT2Player.swift`, after `NoteChange` in
`Snd_fx.cpp`) and its envelopes carried on and started again by ModPlug Tracker's rules
(`InstrumentChange` there); in an S3M file, a channel's volume, a slide of it and
a slide of the whole tune's (`laterCommand` in `Sources/SidayKit/ScreamTracker/ST3Effects.swift`);
in an XM file, a sweep from side to side (`sweepFromSideToSide` in
`Sources/SidayKit/FastTracker/FT2Replayer.swift`, with its two tables of 64 numbers in
`FT2Tables.swift`, which are OpenMPT's `ModSinusTable` and `ModRandomTable` from
`soundlib/Tables.cpp`) and a channel's filter, set by macros (`sendFilterMacro` there, and
`setFilter` and the filter's line in the mixer in `FT2Player.swift`, after `soundlib/Snd_flt.cpp`
and the mixer's own filter). The first of the signs by which an XM file is taken not to be FastTracker's
own are those of `soundlib/Load_xm.cpp`. Changed from the original: carried over from C++ to Swift,
and each set into another tracker's replayer, which plays the rest as that tracker would. Used
under the BSD 3-Clause licence set out below, under "OpenMPT — FM Tracker files": Copyright (c)
2004-2026 OpenMPT Project Developers and Contributors and Copyright (c) 1997-2003 Olivier Lapicque.

## OpenMPT — FM instruments and built-in plug-ins

Three more things in this player are made from OpenMPT (https://openmpt.org), and are for the files
of OpenMPT and of ModPlug Tracker before it: MPTM files, and IT files that say one of the two made
them.

`Sources/SidayKit/ImpulseTracker/IT2AdLib.swift` plays an instrument that is a patch for the AdLib's
FM chip as OpenMPT plays one: how it gives the chip's eighteen voices out to notes, and what it sets
the chip's registers to for a note's patch, pitch, level and side (`soundlib/OPL.cpp` and `OPL.h`),
and when it does each (`soundlib/Snd_fx.cpp`, `soundlib/Sndmix.cpp`). Changed from the original:
carried over from C++ to Swift; what OpenMPT does as each thing happens to a note is done here once
a tick, from what Impulse Tracker's replayer has made of its voices by then, so that the chip is
left set as OpenMPT leaves it; the chip itself is Nuked OPL3 (below) where OpenMPT's is Opal; and a
note's pitch is Impulse Tracker's replayer's, which is not in every case OpenMPT's.

`Sources/SidayKit/OpenMPT` has OpenMPT's own effects, which are its remakes of the effects that came
with Windows as DirectX Media Objects, and one more: `OpenMPTEcho.swift`, `OpenMPTChorus.swift` (the
chorus and both flangers), `OpenMPTGargle.swift`, `OpenMPTWavesReverb.swift`,
`OpenMPTI3DL2Reverb.swift`, `OpenMPTDistortion.swift`, `OpenMPTParamEq.swift` and
`OpenMPTCompressor.swift`, with `OpenMPTDMOUtils.swift`, from `soundlib/plugins/dmo/Echo.cpp`,
`Chorus.cpp`, `Flanger.cpp`, `Gargle.cpp`, `WavesReverb.cpp`, `I3DL2Reverb.cpp`, `Distortion.cpp`,
`ParamEq.cpp`, `Compressor.cpp` and `DMOUtils.cpp`; `OpenMPTDigiBoosterEcho.swift` from
`soundlib/plugins/DigiBoosterEcho.cpp`; and `OpenMPTSymMODEcho.swift` from
`soundlib/plugins/SymMODEcho.cpp`. `OpenMPTEffect.swift` is what they have in common
(`soundlib/plugins/PlugInterface.h`). Changed from the originals: carried over from C++ to Swift,
each as a class that is given sound and gives sound back and knows nothing of OpenMPT's mixer; their
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

`Sources/SidayKit/OPL/OPL3Chip.swift` and `OPL3Tables.swift` are a Swift port of Nuked OPL3 1.8, an
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

## fmdrv — Creative's driver for CMF files

`Sources/SidayKit/OPL/SBFMDriver.swift` and `SBFMTables.swift` are a Swift port of fmdrv
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

`Sources/SidayKit/OPL/ROLTune.swift` is a Swift port of AdPlug's ROL player (`rol.cpp`), and
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

`Sources/SidayKit/OPL/AdLibBankData.swift` holds 9,683 instruments for the FM chip by name, each as
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

`Sources/SidayKit/OPL/FMTTune.swift` reads the songs of Davey W Taylor's FM Tracker as OpenMPT's
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

`Sources/SidayKit/Atari/ICE.swift` follows the "Ice 2_40 depacker, universal C version" that Hans
Wessels placed in the public domain in 2007, as it is distributed with AtariAudio.

## superzazu/z80 — Z80 cycle counts

The cycle-count tables in `Sources/SidayKit/Z80/Z80.swift` follow those of superzazu/z80
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

## ar002 — LH5 unpacking

`Sources/SidayKit/Dumps/LH5.swift` follows the decoder in ar002 by Haruhiko Okumura, which its author
placed in the public domain.

## High Voltage SID Collection — song lengths

`Sources/SidayKit/SIDFile/SongLengthsData.swift` holds the play time of every song of every tune in
release 85 of the [High Voltage SID Collection](https://www.hvsc.c64.org), packed from the
`Songlengths.md5` in its `DOCUMENTS` folder by `Scripts/pack-songlengths.swift`. The times are the work
of the collection's team. The table has the times and part of each SID file's MD5, and nothing of the
tunes themselves. The collection's documents give no licence for the file; it is published for players
to use, and players commonly carry it.

## Reference material

- The SID file format and environment follow `SID_file_format.txt` from the High Voltage SID Collection.
- The `.ay` format follows the ZXAYEMUL description by Patrik Rak and Sergey Bulba.
- The 6510 core was written for this project and verified with SingleStepTests/65x02.
