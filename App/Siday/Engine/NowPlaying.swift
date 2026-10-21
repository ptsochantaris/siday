// Copyright (C) 2026 Paul Tsochantaris
// SPDX-License-Identifier: GPL-2.0-or-later

import MediaPlayer

/// What the system shows of the tune that is playing (on the lock screen, in Control Center, in the
/// menu bar's Now Playing), and the controls it has for it: headphones' buttons and the keyboard's
/// media keys among them.
final class SystemNowPlaying {
    private let model: PlayerModel

    init(model: PlayerModel) {
        self.model = model
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak model] _ in
            model?.setPaused(false)
            return .success
        }
        commands.pauseCommand.addTarget { [weak model] _ in
            model?.setPaused(true)
            return .success
        }
        commands.togglePlayPauseCommand.addTarget { [weak model] _ in
            model?.togglePause()
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak model] _ in
            guard let model, model.hasNext else { return .noActionableNowPlayingItem }
            model.next()
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak model] _ in
            guard let model, model.hasPrevious else { return .noActionableNowPlayingItem }
            model.previous()
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak model] event in
            guard let model, let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            model.seek(to: event.positionTime)
            return .success
        }
        model.onNowPlayingChange = { [weak self] position in self?.update(at: position) }
    }

    /// Tells the system what is playing, where in it the sound is, and whether it is going.
    func update(at position: Double? = nil) {
        let center = MPNowPlayingInfoCenter.default()
        guard let tune = model.tune else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: tune.title.isEmpty ? model.fileName : tune.title,
            MPMediaItemPropertyPlaybackDuration: tune.length,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position ?? model.position,
            MPNowPlayingInfoPropertyPlaybackRate: model.paused || model.finished ? 0.0 : 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if !tune.author.isEmpty { info[MPMediaItemPropertyArtist] = tune.author }
        info[MPMediaItemPropertyAlbumTitle] = tune.songs.count > 1 ? String(localized: "\(tune.format), song \(tune.song + 1) of \(tune.songs.count)") : tune.format
        center.nowPlayingInfo = info
        center.playbackState = model.paused ? .paused : model.finished ? .stopped : .playing
    }
}
