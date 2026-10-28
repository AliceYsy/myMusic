import SwiftUI
import UniformTypeIdentifiers

private let lime = Color(red: 0.77, green: 0.94, blue: 0.4)

struct LibraryView: View {
    @EnvironmentObject private var library: Library
    @State private var importer = false
    @State private var player = false
    @State private var query = ""
    @State private var deleting: Song?
    private var results: [Song] { library.songs.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.artist.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack {
                        Label("LOCAL / MUSIC", systemImage: "waveform").tracking(2).foregroundStyle(lime)
                        Spacer()
                        Text("离线 · 随心听").foregroundStyle(.secondary)
                    }.font(.caption.bold())
                    Text("你的音乐，\n随身珍藏。").font(.system(size: 38, weight: .bold, design: .rounded))
                    Text("\(library.songs.count) 首歌曲 · \(Int(library.songs.reduce(0) { $0 + $1.duration } / 60)) 分钟").font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button { library.mode = 2; library.next() } label: {
                            Label("随机播放", systemImage: "shuffle").frame(maxWidth: .infinity).padding(.vertical, 16)
                        }.background(lime, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.black).disabled(library.songs.isEmpty)
                        Button { importer = true } label: {
                            Label("导入歌曲", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 16)
                        }.background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 16)).disabled(library.importing)
                    }.buttonStyle(.plain).font(.subheadline.bold())
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索歌曲或艺术家", text: $query).autocorrectionDisabled()
                    }.padding(14).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    HStack {
                        Text("音乐库").font(.title2.bold())
                        Spacer()
                        if library.importing { ProgressView(); Text("正在导入…").font(.caption) }
                    }
                    if library.songs.isEmpty {
                        VStack(spacing: 18) {
                            Image(systemName: "music.note.house").font(.system(size: 48)).foregroundStyle(lime)
                            Text("收藏你的第一首歌").font(.headline)
                            Text("从“文件”导入 MP3、M4A、WAV 等音频\n保存在本机，随时离线播放")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("选择本地歌曲") { importer = true }.disabled(library.importing)
                        }.frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else if results.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(results) { song in
                                HStack(spacing: 12) {
                                    Button { library.play(song) } label: {
                                        HStack(spacing: 14) {
                                            Image(systemName: library.current?.id == song.id && library.playing ? "waveform" : "music.note")
                                                .foregroundStyle(lime).frame(width: 52, height: 52).background(lime.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                                            VStack(alignment: .leading, spacing: 6) {
                                                Text(song.title).font(.subheadline.bold()).foregroundStyle(library.current?.id == song.id ? lime : .white).lineLimit(1)
                                                Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                            Spacer(minLength: 0)
                                            Text(timestamp(song.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    Menu { Button("删除歌曲", role: .destructive) { deleting = song } } label: {
                                        Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 28, height: 44)
                                    }.accessibilityLabel("\(song.title) 的更多选项")
                                }.padding(.vertical, 4)
                            }
                        }
                    }
                }.padding(24)
            }.background(Color(red: 0.055, green: 0.07, blue: 0.06))
            .safeAreaInset(edge: .bottom) {
                if let song = library.current {
                    HStack {
                        Button { player = true } label: {
                            HStack {
                                Image(systemName: "opticaldisc.fill").font(.title).foregroundStyle(lime)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(song.title).font(.subheadline.bold()).lineLimit(1)
                                    Text(song.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button { library.toggle() } label: { Image(systemName: library.playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }.accessibilityLabel(library.playing ? "暂停" : "播放")
                        Button { library.next() } label: { Image(systemName: "forward.end.fill").frame(width: 36, height: 44) }.accessibilityLabel("下一首")
                    }.padding(14).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20)).padding(.horizontal, 16).padding(.bottom, 8)
                }
            }
            .fileImporter(isPresented: $importer, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await library.importSongs(urls) }
                case .failure(let error): library.error = error.localizedDescription
                }
            }
            .sheet(isPresented: $player) { PlayerView() }
            .alert("操作未完成", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
                Button("好") { library.error = nil }
            } message: { Text(library.error ?? "") }
            .confirmationDialog("从本机音乐库删除这首歌曲？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("删除歌曲", role: .destructive) { if let song = deleting { library.delete(song) }; deleting = nil }
                Button("取消", role: .cancel) { deleting = nil }
            }
        }.tint(lime)
    }
}

struct PlayerView: View {
    @EnvironmentObject private var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var dragging = false
    @State private var seekTime = 0.0
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 30) {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "chevron.down").padding(10) }.accessibilityLabel("收起播放器")
                        Spacer()
                        Text("正在播放 · 本地音乐").font(.caption.bold()).tracking(2)
                        Spacer()
                        Image(systemName: "waveform").padding(10)
                    }.foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    ZStack {
                        RoundedRectangle(cornerRadius: 32).fill(LinearGradient(colors: [lime.opacity(0.35), .black], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Circle().fill(.black.opacity(0.65)).padding(28)
                        Circle().stroke(lime.opacity(0.18), lineWidth: 1).padding(44)
                        Circle().stroke(lime.opacity(0.18), lineWidth: 1).padding(60)
                        Circle().fill(lime).frame(width: 70, height: 70)
                        Image(systemName: "music.note").font(.title).foregroundStyle(.black)
                    }.frame(width: min(geometry.size.width - 48, 340), height: min(geometry.size.width - 48, 340))
                    VStack(spacing: 10) {
                        Text(library.current?.title ?? "未选择歌曲").font(.title2.bold()).multilineTextAlignment(.center)
                        Text(library.current?.artist ?? "本地音乐库").foregroundStyle(.secondary)
                    }
                    VStack(spacing: 4) {
                        Slider(value: Binding(get: { dragging ? seekTime : library.position }, set: { seekTime = $0 }), in: 0...max(1, library.duration)) { editing in
                            if editing { seekTime = library.position; dragging = true }
                            else { library.seek(seekTime); dragging = false }
                        }.disabled(library.current == nil)
                        HStack {
                            Text(timestamp(dragging ? seekTime : library.position)); Spacer(); Text(timestamp(library.duration))
                        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 40) {
                        Button { library.previous() } label: { Image(systemName: "backward.end.fill").font(.title) }.accessibilityLabel("上一首")
                        Button { library.toggle() } label: {
                            Image(systemName: library.playing ? "pause.fill" : "play.fill").font(.title).foregroundStyle(.black).frame(width: 78, height: 78).background(lime, in: Circle())
                        }.accessibilityLabel(library.playing ? "暂停" : "播放")
                        Button { library.next() } label: { Image(systemName: "forward.end.fill").font(.title) }.accessibilityLabel("下一首")
                    }.foregroundStyle(.white)
                    Button { library.mode = (library.mode + 1) % 3 } label: {
                        Label(["顺序循环", "单曲循环", "随机播放"][library.mode], systemImage: ["repeat", "repeat.1", "shuffle"][library.mode])
                    }.font(.subheadline).padding(12)
                    Spacer(minLength: 8)
                }.padding(24).frame(minHeight: geometry.size.height)
            }.background(Color(red: 0.055, green: 0.075, blue: 0.065))
        }.tint(lime)
    }
}
