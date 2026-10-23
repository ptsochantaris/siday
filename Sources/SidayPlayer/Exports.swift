// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

// SidayPlayer is what the front ends share between a tune and a listener: a tune played to its end by
// the same rules everywhere (`TuneSession`), the settings, the levelling, the television and the
// spectrum analyser, the keeping of a whole song to move about in (`TunePlayer`, `SongKeeper`), the
// playlists and the pictures to listen by. SidayKit, which turns a tune's bytes into its sound, comes
// with it.
@_exported import SidayKit
