// Files attached to the composer (dropped/pasted on Mac, picked from Photos, Camera, Files or Pasteboard on iPhone):
// uploaded to the session's computer as soon as they land, then sent with the message as Markdown embeds of their
// paths there, which the agents open with their read tools and the transcript shows.
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
import UIKit
#endif

/// An attached file, uploading until it has a path on the session's computer.
struct Attachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    /// Kept on pre-session drafts so switching computers in New Session re-uploads onto the chosen machine.
    var data: Data?
    var uploadedEnv: String?
    var path: String?
    var error: String?

    var uploading: Bool { path == nil && error == nil }

    /// How the message carries it: an embed, as the agents write theirs.
    var embed: String? { path.map { "![\(name)](<\($0)>)" } }

    /// Joins trimmed message text with the Markdown embeds of every uploaded attachment.
    static func compose(message: String, attachments: [Attachment]) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([trimmed].filter { !$0.isEmpty } + attachments.compactMap(\.embed)).joined(separator: "\n\n")
    }

    /// Re-encodes HEIC/HEIF/TIFF photos as JPEG so agent vision tools (`attach_image`, `read`) accept them alongside
    /// Shed's own viewer; leaves PNG, JPEG, GIF, WebP, videos, audio and documents untouched.
    static func prepared(name: String, data: Data) -> (name: String, data: Data) {
        let ext = (name as NSString).pathExtension.lowercased()
        guard ["heic", "heif", "tif", "tiff"].contains(ext),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { return (name, data) }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            return (name, data)
        }
        CGImageDestinationAddImageFromSource(dest, source, 0,
                                             [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return (name, data) }
        let stem = (name as NSString).deletingPathExtension
        return ("\(stem.isEmpty ? "Image" : stem).jpg", out as Data)
    }
}

/// What a drop or paste can carry: files (Finder, the screenshot thumbnail) and image or video data.
let attachableTypes: [UTType] = [.fileURL, .image, .movie]

extension MediaSource {
    /// Saves `data` on the session's computer through the bridge's `/upload` route; returns its path there.
    func upload(_ data: Data, name: String) async throws -> String {
        guard var components = URLComponents(string: bridgeURL.trimmingCharacters(in: .whitespaces)) else {
            throw BridgeError("That computer has no address")
        }
        components.scheme = components.scheme == "wss" ? "https" : "http"
        components.path = "/upload"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components.url else { throw BridgeError("That computer has no address") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (body, response) = try await URLSession.shared.upload(for: request, from: data)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // A bridge from before uploads answers 404 or 405.
            throw BridgeError(http.statusCode == 404 || http.statusCode == 405
                ? "That computer's bridge is too old to take files"
                : "Upload failed (\(http.statusCode))")
        }
        guard let path = (try JSONSerialization.jsonObject(with: body) as? [String: Any])?["path"] as? String else {
            throw BridgeError("Upload failed")
        }
        return path
    }
}

/// The files in a drop, read off the main thread: a file URL when there is one, otherwise the item's own image or
/// video data, which is how file promises such as the screenshot thumbnail arrive.
@MainActor
func droppedFiles(_ providers: [NSItemProvider]) async -> [(name: String, data: Data)] {
    var files: [(name: String, data: Data)] = []
    for provider in providers {
        if let file = await fileURL(from: provider) {
            files.append(file)
        } else if let file = await representation(from: provider) {
            files.append(file)
        }
    }
    return files
}

@MainActor
private func fileURL(from provider: NSItemProvider) async -> (name: String, data: Data)? {
    guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
    return await withCheckedContinuation { done in
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true,
                  let data = try? Data(contentsOf: url) else { return done.resume(returning: nil) }
            done.resume(returning: (url.lastPathComponent, data))
        }
    }
}

@MainActor
private func representation(from provider: NSItemProvider) async -> (name: String, data: Data)? {
    let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
    guard let type = types.first(where: { $0.conforms(to: .image) || $0.conforms(to: .movie) }) else { return nil }
    let suggested = provider.suggestedName
    return await withCheckedContinuation { done in
        _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
            // The file is gone once this returns: read it now.
            guard let url, let data = try? Data(contentsOf: url) else { return done.resume(returning: nil) }
            var name = suggested ?? url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension.isEmpty ? type.preferredFilenameExtension ?? "" : url.pathExtension
            if !ext.isEmpty, !name.lowercased().hasSuffix("." + ext.lowercased()) { name += "." + ext }
            done.resume(returning: (name, data))
        }
    }
}

/// The attached files above the text field, each with a remove button.
struct AttachmentStrip: View {
    let attachments: [Attachment]
    let remove: (Attachment) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 6) {
                        if attachment.uploading {
                            ProgressView().controlSize(.mini)
                        } else if attachment.error != nil {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.danger)
                        } else {
                            Image(systemName: Self.icon(for: attachment.name))
                                .foregroundStyle(Palette.accent.opacity(0.9))
                        }
                        Text(attachment.error.map { "\(attachment.name) · \($0)" } ?? attachment.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: attachment.error == nil ? 180 : 240)
                        Button { remove(attachment) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .frame(width: 20, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.moon)
                    .padding(.leading, 10).padding(.trailing, 4).frame(height: 26)
                    .card(radius: 13, fill: Palette.raised)
                    .help(attachment.error ?? attachment.path ?? "Uploading…")
                }
            }
        }
        .scrollIndicators(.never)
    }

    private static func icon(for name: String) -> String {
        switch MediaKind(URL(fileURLWithPath: name)) {
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .file: "doc"
        }
    }
}

/// A user message's trailing embeds, split from its text: what the composer appends for attached files.
enum MessageAttachments {
    static func split(_ text: String) -> (text: String, paths: [String]) {
        var lines = text.components(separatedBy: "\n")
        var paths: [String] = []
        while let last = lines.last {
            if last.trimmingCharacters(in: .whitespaces).isEmpty, !paths.isEmpty { lines.removeLast(); continue }
            guard let path = embeddedPath(last) else { break }
            paths.insert(path, at: 0)
            lines.removeLast()
        }
        return (lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), paths)
    }

    /// The path in a `![name](<path>)` line.
    private static func embeddedPath(_ line: String) -> String? {
        let line = line.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("!["), line.hasSuffix(">)"), let open = line.range(of: "](<") else { return nil }
        let path = String(line[open.upperBound..<line.index(line.endIndex, offsetBy: -2)])
        return path.hasPrefix("/") ? path : nil
    }
}

#if os(iOS)
/// The `+` button inside the iPhone composers: opens Photos & Videos, Camera, Files, or Paste from clipboard.
struct PhoneAttachButton: View {
    var size: CGFloat = 36
    let attach: (@escaping @MainActor () async -> [(name: String, data: Data)]) -> Void
    @State private var pickingPhotos = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var pickingFiles = false
    @State private var showingCamera = false
    @State private var canPaste = false

    var body: some View {
        Menu {
            Button { pickingPhotos = true } label: {
                Label("Photos & Videos", systemImage: "photo.on.rectangle")
            }
            if CameraPicker.isAvailable {
                Button { showingCamera = true } label: {
                    Label("Camera", systemImage: "camera")
                }
            }
            Button { pickingFiles = true } label: {
                Label("Files", systemImage: "folder")
            }
            if canPaste {
                Divider()
                Button { attach { await PhoneAttachments.loadClipboard() } } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: size <= 30 ? 14 : 16, weight: .semibold))
                .foregroundStyle(Palette.moon.opacity(0.85))
                .frame(width: size, height: size)
                .background(Palette.raised, in: Circle())
                .overlay(Circle().strokeBorder(Palette.border))
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel("Attach media or files")
        .photosPicker(isPresented: $pickingPhotos, selection: $pickedPhotos, matching: .any(of: [.images, .videos]))
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            attach { await PhoneAttachments.loadPhotos(items) }
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                attach { await PhoneAttachments.loadFiles(urls) }
            }
        }
        .fullScreenCover(isPresented: $showingCamera) {
            CameraPicker { file in attach { [file] } }
                .ignoresSafeArea()
        }
        .onAppear { canPaste = PhoneAttachments.hasClipboardItems }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            canPaste = PhoneAttachments.hasClipboardItems
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            canPaste = PhoneAttachments.hasClipboardItems
        }
    }
}

private struct PickedAttachmentFile: Transferable, Sendable {
    let name: String
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let url = received.file
            let data = try Data(contentsOf: url)
            return PickedAttachmentFile(name: url.lastPathComponent, data: data)
        }
    }
}

enum PhoneAttachments {
    @MainActor
    static var hasClipboardItems: Bool {
        UIPasteboard.general.hasImages || UIPasteboard.general.hasURLs
    }

    static func loadPhotos(_ items: [PhotosPickerItem]) async -> [(name: String, data: Data)] {
        var out: [(name: String, data: Data)] = []
        for (index, item) in items.enumerated() {
            let preferredExt = item.supportedContentTypes.first?.preferredFilenameExtension
            if let picked = try? await item.loadTransferable(type: PickedAttachmentFile.self) {
                var name = picked.name
                if (name as NSString).pathExtension.isEmpty, let ext = preferredExt, !ext.isEmpty {
                    name += ".\(ext)"
                }
                out.append((name, picked.data))
            } else if let data = try? await item.loadTransferable(type: Data.self) {
                let ext = preferredExt ?? "jpg"
                out.append(("Attachment \(index + 1).\(ext)", data))
            }
        }
        return out
    }

    static func loadFiles(_ urls: [URL]) async -> [(name: String, data: Data)] {
        await Task.detached {
            urls.compactMap { url -> (name: String, data: Data)? in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                var coordError: NSError?
                var loaded: (name: String, data: Data)?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
                    guard (try? readURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true,
                          let data = try? Data(contentsOf: readURL) else { return }
                    loaded = (readURL.lastPathComponent, data)
                }
                return coordError == nil ? loaded : nil
            }
        }.value
    }

    @MainActor
    static func loadClipboard() async -> [(name: String, data: Data)] {
        let urls = (UIPasteboard.general.urls ?? []).filter(\.isFileURL)
        if !urls.isEmpty {
            return await loadFiles(urls)
        }
        let images = UIPasteboard.general.images ?? []
        return images.enumerated().compactMap { index, image in
            guard let png = image.pngData() else { return nil }
            let name = images.count == 1 ? "Image.png" : "Image \(index + 1).png"
            return (name, png)
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onPick: @MainActor ((name: String, data: Data)) -> Void
    @Environment(\.dismiss) private var dismiss

    @MainActor
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        if let types = UIImagePickerController.availableMediaTypes(for: .camera), !types.isEmpty {
            picker.mediaTypes = types
        }
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let movieURL = info[.mediaURL] as? URL, let data = try? Data(contentsOf: movieURL) {
                let ext = movieURL.pathExtension.isEmpty ? "mov" : movieURL.pathExtension.lowercased()
                parent.onPick(("Video.\(ext)", data))
            } else if let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage,
                      let jpeg = image.uprightJPEG(quality: 0.9) {
                parent.onPick(("Photo.jpg", jpeg))
            }
            parent.dismiss()
        }
    }
}

private extension UIImage {
    func uprightJPEG(quality: CGFloat) -> Data? {
        guard imageOrientation != .up else { return jpegData(compressionQuality: quality) }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format)
            .image { _ in draw(in: CGRect(origin: .zero, size: size)) }
            .jpegData(compressionQuality: quality)
    }
}
#endif
