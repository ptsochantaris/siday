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
(`MFP.swift`), the STE's sample player (`STESound.swift`) and the reading of an SNDH file's header.
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
