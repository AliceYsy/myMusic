import SwiftUI
import AVFoundation
import MediaPlayer
import UniformTypeIdentifiers

struct Song: Identifiable, Codable, Equatable {
    var id: UUID
    var file: String
    var title: String
    var artist: String
    var duration: Double
}

@MainActor
final class Library: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var songs: [Song] = []
    @Published var current: Song?
    @Published var playing = false
    @Published var position = 0.0
    @Published var mode = 0
    @Published var importing = false
    @Published var error: String?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var targets: [Any] = []
    private let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Music")
    var duration: Double { player?.duration ?? 0 }
    override init() {
        super.init()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let index = root.appendingPathComponent("library.json")
            if FileManager.default.fileExists(atPath: index.path) { songs = try JSONDecoder().decode([Song].self, from: Data(contentsOf: index)) }
            try seedSamples()
            try AVAudioSession.sharedInstance().setCategory(.playback)
        } catch { self.error = error.localizedDescription }
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.position = self?.player?.currentTime ?? 0 }
        }
        let remote = MPRemoteCommandCenter.shared()
        bind(remote.playCommand) { $0.resume() }
        bind(remote.pauseCommand) { $0.pause() }
        bind(remote.togglePlayPauseCommand) { $0.toggle() }
        bind(remote.nextTrackCommand) { $0.next() }
        bind(remote.previousTrackCommand) { $0.previous() }
        targets.append(remote.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }; return .success
        })
        NotificationCenter.default.addObserver(self, selector: #selector(interruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(routeChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
    }
    private func seedSamples() throws {
        guard !UserDefaults.standard.bool(forKey: "samplesInstalledV1") else { return }
        let samples = [("morning", "晨光漫步"), ("night", "夜色微风"), ("journey", "轻快旅程")]
        for (name, title) in samples {
            let file = "sample-\(name).wav"
            guard !songs.contains(where: { $0.file == file }) else { continue }
            guard let source = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "Samples") else { throw CocoaError(.fileNoSuchFile) }
            let destination = root.appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: source, to: destination)
            }
            let audio = try AVAudioPlayer(contentsOf: destination)
            songs.append(Song(id: UUID(), file: file, title: title, artist: "Local Music · 原创测试音轨", duration: audio.duration))
        }
        try JSONEncoder().encode(songs).write(to: root.appendingPathComponent("library.json"), options: .atomic)
        UserDefaults.standard.set(true, forKey: "samplesInstalledV1")
    }
    private func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor (Library) -> Void) {
        targets.append(command.addTarget { [weak self] _ in Task { @MainActor in if let self { action(self) } }; return .success })
    }
    func importSongs(_ urls: [URL]) async {
        guard !importing else { return }
        importing = true
        defer { importing = false }
        var failed: [String] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let id = UUID()
            let file = id.uuidString + "." + url.pathExtension
            let destination = root.appendingPathComponent(file)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                let audio = try AVAudioPlayer(contentsOf: destination)
                guard audio.duration.isFinite, audio.duration > 0 else { throw CocoaError(.fileReadCorruptFile) }
                var title = url.deletingPathExtension().lastPathComponent
                var artist = "未知艺术家"
                let metadata = (try? await AVURLAsset(url: destination).load(.commonMetadata)) ?? []
                for item in metadata {
                    if item.commonKey == .commonKeyTitle, let value = try? await item.load(.stringValue), !value.isEmpty { title = value }
                    if item.commonKey == .commonKeyArtist, let value = try? await item.load(.stringValue), !value.isEmpty { artist = value }
                }
                songs.append(Song(id: id, file: file, title: title, artist: artist, duration: audio.duration))
                save()
            } catch { try? FileManager.default.removeItem(at: destination); failed.append(url.lastPathComponent) }
        }
        if !failed.isEmpty { error = "无法导入以下文件，请确认音频格式受支持：\n" + failed.joined(separator: "\n") }
    }
    private func save() {
        do { try JSONEncoder().encode(songs).write(to: root.appendingPathComponent("library.json"), options: .atomic) }
        catch { self.error = "保存失败：\(error.localizedDescription)" }
    }
    func play(_ song: Song) {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            let audio = try AVAudioPlayer(contentsOf: root.appendingPathComponent(song.file))
            player?.stop(); player = audio; audio.delegate = self
            current = song; position = 0; playing = audio.play(); nowPlaying()
        } catch { self.error = "播放失败：\(error.localizedDescription)" }
    }
    func resume() {
        guard let player else { if let song = songs.first { play(song) }; return }
        do { try AVAudioSession.sharedInstance().setActive(true); playing = player.play(); nowPlaying() }
        catch { self.error = error.localizedDescription }
    }
    func pause() { player?.pause(); playing = false; nowPlaying() }
    func toggle() { playing ? pause() : resume() }
    func seek(_ time: Double) { player?.currentTime = max(0, min(time, duration)); position = player?.currentTime ?? 0; nowPlaying() }
    func next() {
        guard !songs.isEmpty else { return }
        if mode == 2 { play(songs.filter { $0.id != current?.id }.randomElement() ?? songs[0]); return }
        let index = songs.firstIndex { $0.id == current?.id } ?? -1
        play(songs[(index + 1) % songs.count])
    }
    func previous() {
        if position > 3 { seek(0); return }
        guard !songs.isEmpty else { return }
        let index = songs.firstIndex { $0.id == current?.id } ?? 0
        play(songs[(index + songs.count - 1) % songs.count])
    }
    func delete(_ song: Song) {
        do { try FileManager.default.removeItem(at: root.appendingPathComponent(song.file)) }
        catch { self.error = error.localizedDescription; return }
        if current?.id == song.id { player?.stop(); player = nil; playing = false; current = nil; position = 0; MPNowPlayingInfoCenter.default().nowPlayingInfo = nil }
        songs.removeAll { $0.id == song.id }; save()
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in if self.mode == 1 { self.seek(0); self.resume() } else { self.next() } }
    }
    private func nowPlaying() {
        guard let current else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: current.title, MPMediaItemPropertyArtist: current.artist, MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: player?.currentTime ?? 0, MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0]
    }
    @objc private func interruption(_ notification: Notification) {
        guard let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
        if type == AVAudioSession.InterruptionType.began.rawValue { pause() }
        else if let raw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt, AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume) { resume() }
    }
    @objc private func routeChanged(_ notification: Notification) {
        if let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt, reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { pause() }
    }
}

func timestamp(_ time: Double) -> String {
    let seconds = time.isFinite ? max(0, Int(time)) : 0
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

@main
struct LocalMusicApp: App {
    @StateObject private var library = Library()
    var body: some Scene { WindowGroup { LibraryView().environmentObject(library).preferredColorScheme(.dark) } }
}
