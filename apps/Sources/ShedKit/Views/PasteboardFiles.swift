#if os(macOS)
// Files dropped or pasted onto the composer's text, which it attaches instead of pasting their paths.
import AppKit

/// Files read off a pasteboard: on disk, or image data with no file behind it.
struct PasteboardFiles: @unchecked Sendable {
    var urls: [URL] = []
    var images: [(name: String, data: Data)] = []

    var isEmpty: Bool { urls.isEmpty && images.isEmpty }

    /// The files' names and contents, read off the main thread.
    func load() async -> [(name: String, data: Data)] {
        let urls = urls
        let read = await Task.detached {
            urls.compactMap { url -> (name: String, data: Data)? in
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true,
                      let data = try? Data(contentsOf: url) else { return nil }
                return (url.lastPathComponent, data)
            }
        }.value
        return read + images
    }
}

extension NSPasteboard {
    /// Its files and images, or nothing for plain text (a copied path stays text).
    var files: PasteboardFiles {
        var files = PasteboardFiles()
        files.urls = readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if files.urls.isEmpty, availableType(from: [.png, .tiff]) != nil,
           let image = NSImage(pasteboard: self), let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            files.images = [("Image.png", png)]
        }
        return files
    }
}
#endif
