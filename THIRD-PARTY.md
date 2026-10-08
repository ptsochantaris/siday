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

## it2play — Impulse Tracker 2

`Sources/SidayKit/ImpulseTracker` is a Swift port of it2play (https://github.com/8bitbubsy/it2play),
Olav Sørensen's C port of the replayer of Impulse Tracker 2.15, made from that tracker's own assembly:
the replayer (`IT2Player.swift`, `IT2Effects.swift`, `IT2Tables.swift`), the reading of IT files and
the unpacking of their compressed samples (`IT2Module.swift`), and the sound driver it2play adds to
Impulse Tracker's own, which mixes in floating point through a windowed sinc and has the resonant
filter (`IT2Mixer.swift`). Impulse Tracker's own drivers, and it2play's reading of S3M and MMCMP
files, are not ported.

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
