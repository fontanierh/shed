// Files dropped on the composer: uploaded to the session's computer as soon as they land, then sent with the message
// as Markdown embeds of their paths there, which the agents open with their read tools and the transcript shows.
import SwiftUI
import UniformTypeIdentifiers

/// A dropped file, uploading until it has a path on the session's computer.
struct Attachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    var path: String?
    var error: String?

    var uploading: Bool { path == nil && error == nil }

    /// How the message carries it: an embed, as the agents write theirs.
    var embed: String? { path.map { "![\(name)](<\($0)>)" } }
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

/// The dropped files above the text field, each with a remove button.
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
                            Image(systemName: MediaKind(URL(fileURLWithPath: attachment.name)) == .image ? "photo" : "doc")
                                .foregroundStyle(Palette.amber.opacity(0.9))
                        }
                        Text(attachment.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180)
                        Button { remove(attachment) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove")
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.moon)
                    .padding(.horizontal, 10).frame(height: 26)
                    .card(radius: 13, fill: Palette.raised)
                    .help(attachment.error ?? attachment.path ?? "Uploading…")
                }
            }
        }
        .scrollIndicators(.never)
    }
}

/// A user message's trailing embeds, split from its text: what the composer appends for dropped files.
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
