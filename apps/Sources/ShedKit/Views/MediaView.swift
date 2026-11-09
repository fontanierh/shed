// Images, videos, audio and other files the agents embed in their replies (`![caption](/path/on/the/mac.mp4)`), fetched
// through the bridge.
import AVKit
import ImageIO
@preconcurrency import MarkdownUI
import SwiftUI

/// Where media comes from: https URLs as they are, local paths on the agents' Mac through the bridge's `/media` route.
public struct MediaSource: Sendable, Equatable {
    var bridgeURL: String
    var token: String
    /// The session's working directory, which paths the agent gives relative to start from.
    var cwd: String

    public init(bridgeURL: String, token: String, cwd: String = "") {
        self.bridgeURL = bridgeURL
        self.token = token
        self.cwd = cwd
    }

    /// A path as the agent gave it, made absolute against the session's folder.
    func url(forPath path: String) -> URL {
        if path.hasPrefix("/") || cwd.isEmpty { return URL(fileURLWithPath: path) }
        let home = cwd.hasPrefix("~") ? NSHomeDirectory() + cwd.dropFirst() : cwd
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: home, isDirectory: true)).standardizedFileURL
    }

    /// The request to load `url` with, or nil when it can't be reached.
    func request(for url: URL) -> URLRequest? {
        if url.scheme == "http" || url.scheme == "https" { return URLRequest(url: url) }
        let path = url.scheme == "file" ? url.path : url.absoluteString.removingPercentEncoding ?? url.absoluteString
        guard path.hasPrefix("/"),
              var components = URLComponents(string: bridgeURL.trimmingCharacters(in: .whitespaces)) else { return nil }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = "/media"
        components.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let media = components.url else { return nil }
        var request = URLRequest(url: media)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
}

extension EnvironmentValues {
    @Entry var media = MediaSource(bridgeURL: "", token: "")
    @Entry var lightbox: Lightbox? = nil
}

/// The image shown over the whole window, or the file open in the viewer, if any.
@MainActor @Observable
public final class Lightbox {
    struct Shown {
        let image: CGImage
        let name: String
        let request: URLRequest
    }

    var shown: Shown?
    var file: ShownFile?

    public init() {}
}

/// Saves a media file where the user picks (on the iPhone, through the share sheet), named as on the Mac. Fetched again rather than kept, so large clips aren't held in memory.
@MainActor
func saveMedia(_ request: URLRequest, name: String) {
    #if os(macOS)
    let panel = NSSavePanel()
    panel.nameFieldStringValue = name
    panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    guard panel.runModal() == .OK, let destination = panel.url else { return }
    Task {
        do {
            let (file, response) = try await URLSession.shared.download(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw MediaError(status: http.statusCode) }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: file, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            NSAlert(error: error).runModal()
        }
    }
    #else
    // The share sheet, with Save to Files and Save Image.
    Task { if let local = try? await downloadFile(request, name: name) { shareFile(local) } }
    #endif
}

/// A small round control floating on media: download, enlarge.
struct MediaButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.moon)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Palette.sunken.opacity(0.75)))
                .overlay(Circle().strokeBorder(Palette.border))
        }
        .buttonStyle(PressStyle())
        .help(help)
    }
}

/// Every embed goes through here, whatever its type, so agents use one syntax for all media.
struct MediaImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        MediaView(url: url)
    }
}

extension ImageProvider where Self == MediaImageProvider {
    static var media: Self { .init() }
}

enum MediaKind {
    case image, video, audio, file

    init(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff", "bmp", "svg": self = .image
        case "mp4", "m4v", "mov": self = .video
        case "mp3", "m4a", "aac", "wav", "aif", "aiff", "flac": self = .audio
        // An https image link often has no extension at all.
        case "" where url.scheme == "https" || url.scheme == "http": self = .image
        default: self = .file
        }
    }
}

struct MediaView: View {
    let url: URL?
    @Environment(\.media) private var media

    var body: some View {
        if let url, let request = media.request(for: url) {
            switch MediaKind(url) {
            case .image: MediaImage(request: request, name: url.lastPathComponent)
            case .video: MediaVideo(request: request)
            case .audio: MediaAudio(request: request, name: url.lastPathComponent)
            case .file: FileCard(url: url, request: request)
            }
        } else {
            MediaMissing(text: url?.absoluteString ?? "No media")
        }
    }
}

// MARK: Images

/// Loads and decodes an image off the main thread, cached for the session so scrolling back doesn't refetch.
@MainActor
final class MediaCache {
    static let shared = MediaCache()
    private var images: [URL: CGImage] = [:]

    func image(for request: URLRequest) async throws -> CGImage {
        let key = request.url!
        if let cached = images[key] { return cached }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MediaError(status: http.statusCode)
        }
        let image = try await Task.detached {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { throw MediaError(status: nil) }
            return image
        }.value
        images[key] = image
        return image
    }
}

struct MediaError: LocalizedError {
    let status: Int?
    var errorDescription: String? {
        switch status {
        case 404: "File not found"
        case 401: "Not authorized"
        case let status?: "Couldn't load (\(status))"
        case nil: "Not an image"
        }
    }
}

struct MediaImage: View {
    let request: URLRequest
    let name: String
    @State private var image: CGImage?
    @State private var failure: String?
    @State private var hovering = false
    @Environment(\.lightbox) private var lightbox

    private func enlarge() {
        guard let image else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            lightbox?.shown = .init(image: image, name: name, request: request)
        }
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(CGFloat(image.width) / 2, .infinity), maxHeight: 460, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border.opacity(0.8)))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    .overlay(alignment: .topTrailing) {
                        HStack(spacing: 6) {
                            MediaButton(systemImage: "arrow.down.to.line", help: "Download") { saveMedia(request, name: name) }
                            MediaButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Enlarge") { enlarge() }
                        }
                        .padding(8)
                        .opacity(hovering ? 1 : 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { enlarge() }
                    .onHover { over in withAnimation(.easeOut(duration: 0.15)) { hovering = over } }
                    .contextMenu {
                        Button("Enlarge") { enlarge() }
                        Button("Download…") { saveMedia(request, name: name) }
                    }
                    .help("Click to enlarge")
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else if let failure {
                MediaMissing(text: "\(name): \(failure)")
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Palette.surface.opacity(0.6))
                    .frame(maxWidth: 360).frame(height: 200)
                    .overlay { Image(systemName: "photo").font(.system(size: 22)).foregroundStyle(Palette.lineNumber) }
                    .shimmer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.35), value: image != nil)
        .task(id: request.url) {
            do { image = try await MediaCache.shared.image(for: request) } catch { failure = error.localizedDescription }
        }
    }
}

/// An image over the whole window: fitted, magnified with a pinch or a double click, dragged around once magnified.
public struct LightboxView: View {
    let lightbox: Lightbox
    @State private var scale = 1.0
    @State private var settledScale = 1.0
    @State private var offset = CGSize.zero
    @State private var settledOffset = CGSize.zero

    public init(lightbox: Lightbox) {
        self.lightbox = lightbox
    }

    private func close() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { lightbox.shown = nil }
        scale = 1; settledScale = 1; offset = .zero; settledOffset = .zero
    }

    public var body: some View {
        @Bindable var lightbox = lightbox
        ZStack { image }
            .sheet(item: $lightbox.file) { file in FileViewer(file: file) }
    }

    @ViewBuilder
    private var image: some View {
        if let shown = lightbox.shown {
            ZStack {
                Rectangle().fill(.black.opacity(0.78)).background(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .onTapGesture { close() }

                Image(decorative: shown.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
                    .scaleEffect(scale)
                    .offset(offset)
                    .padding(.horizontal, 32).padding(.top, 64).padding(.bottom, 32)
                    .gesture(MagnifyGesture()
                        .onChanged { value in scale = min(max(settledScale * value.magnification, 1), 6) }
                        .onEnded { _ in settledScale = scale; if scale == 1 { offset = .zero; settledOffset = .zero } })
                    .simultaneousGesture(DragGesture()
                        .onChanged { value in
                            guard scale > 1 else { return }
                            offset = CGSize(width: settledOffset.width + value.translation.width, height: settledOffset.height + value.translation.height)
                        }
                        .onEnded { _ in settledOffset = offset })
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            scale = scale > 1 ? 1 : 2.5
                            settledScale = scale
                            if scale == 1 { offset = .zero; settledOffset = .zero }
                        }
                    }

                VStack {
                    HStack(spacing: 10) {
                        Text(shown.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.moon).lineLimit(1)
                        Text("\(shown.image.width) × \(shown.image.height)").font(.mono(11.5)).foregroundStyle(.secondary)
                        Spacer()
                        MediaButton(systemImage: "arrow.down.to.line", help: "Download") { saveMedia(shown.request, name: shown.name) }
                        MediaButton(systemImage: "xmark", help: "Close (Esc)") { close() }
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    Spacer()
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
        }
    }
}

// MARK: Video and audio

private func makePlayer(_ request: URLRequest) -> AVPlayer {
    let headers = request.allHTTPHeaderFields ?? [:]
    let asset = AVURLAsset(url: request.url!, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
    return AVPlayer(playerItem: AVPlayerItem(asset: asset))
}

struct MediaVideo: View {
    let request: URLRequest
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.sunken)
            if let player { PlayerView(player: player) }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(alignment: .topTrailing) {
            MediaButton(systemImage: "arrow.down.to.line", help: "Download") {
                saveMedia(request, name: request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value }
                    .map { ($0 as NSString).lastPathComponent } ?? "video.mp4")
            }
            .padding(8)
        }
        .frame(maxWidth: 640)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border.opacity(0.8)))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if player == nil { player = makePlayer(request) } }
        .onDisappear { player?.pause() }
    }

}

/// The platform's own player view. AVKit's SwiftUI `VideoPlayer` fails to load in this app's build, so it isn't used.
#if os(macOS)
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
#else
struct PlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
#endif

/// A compact player: a lantern-amber play button, the clip's name, and a rail to scrub along.
struct MediaAudio: View {
    let request: URLRequest
    let name: String
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var time = 0.0
    @State private var duration = 0.0

    var body: some View {
        HStack(spacing: 12) {
            Button {
                let player = self.player ?? makePlayer(request)
                self.player = player
                if playing { player.pause() } else {
                    if duration > 0, time >= duration - 0.05 { player.seek(to: .zero) }
                    player.play()
                }
                playing.toggle()
            } label: {
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Palette.sunken)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Palette.accent))
                    .glow(radius: 8, on: playing)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(PressStyle())

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.moon).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(Self.clock(time)) / \(Self.clock(duration))")
                        .font(.mono(11.5)).foregroundStyle(.secondary).monospacedDigit()
                    Button { saveMedia(request, name: name) } label: {
                        Image(systemName: "arrow.down.to.line").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Download")
                }
                GeometryReader { proxy in
                    let fraction = duration > 0 ? min(time / duration, 1) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.rail.opacity(0.6))
                        Capsule().fill(LinearGradient(colors: [Palette.accentDeep, Palette.accent], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, proxy.size.width * fraction))
                    }
                    .frame(height: 4)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard duration > 0, let player else { return }
                        let target = min(max(value.location.x / proxy.size.width, 0), 1) * duration
                        time = target
                        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    })
                }
                .frame(height: 12)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: 420)
        .card(radius: 14, fill: Palette.raised.opacity(0.7))
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: playing) {
            // Follow the clock while playing; settle when the clip ends.
            while playing, let player, !Task.isCancelled {
                time = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
                if let item = player.currentItem, item.duration.seconds.isFinite { duration = item.duration.seconds }
                if duration > 0, time >= duration - 0.05 { playing = false }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .task {
            // The length, before playing.
            let asset = AVURLAsset(url: request.url!, options: ["AVURLAssetHTTPHeaderFieldsKey": request.allHTTPHeaderFields ?? [:]])
            if let length = try? await asset.load(.duration), length.seconds.isFinite { duration = length.seconds }
        }
        .onDisappear { player?.pause(); playing = false }
    }


    static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct MediaMissing: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "photo.badge.exclamationmark")
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .card(radius: 10, fill: Palette.surface.opacity(0.6))
    }
}
