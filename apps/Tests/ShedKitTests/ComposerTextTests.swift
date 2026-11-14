import ImageIO
import XCTest
@testable import ShedKit

/// The words and levels the composer and what sits above it work out from a session.
final class ComposerTextTests: XCTestCase {
    /// Prime's own notices wait in the queue too; the reader is shown only the messages they sent.
    func testTheQueueShownLeavesOutTheAgentsOwnNotices() {
        let queue = Queue(
            steering: ["Use the staging database", "[agent-message from child:scout] Done", "Agent message received: hello"],
            followUp: ["[goal continue] Keep going", "[child-exited: no-reply child:scout] gone", "[bash-done pid:1 exit:0] make", "Then open a pull request",
                       "[draft] a message that only starts with a bracket"]
        )
        XCTAssertEqual(queue.forReader, Queue(steering: ["Use the staging database"],
                                              followUp: ["Then open a pull request", "[draft] a message that only starts with a bracket"]))
    }

    @MainActor func testAStuckReasonNamesTheComputerAndEndsAsASentence() {
        XCTAssertEqual(StuckBanner.phrase("macOS is asking for permission on this Mac", on: "studio"),
                       "MacOS is asking for permission on studio.")
        XCTAssertEqual(StuckBanner.phrase("the command waits for input on this Mac", on: nil), "The command waits for input on this Mac.")
        XCTAssertEqual(StuckBanner.phrase("Is it waiting?", on: "studio"), "Is it waiting?")
    }

    @MainActor func testAnEffortLevelIsItsPlaceAmongTheModels() {
        let levels = ["low", "medium", "high"]
        XCTAssertEqual(EffortBars.level(of: "low", in: levels), 0)
        XCTAssertEqual(EffortBars.level(of: "medium", in: levels), 0.5)
        XCTAssertEqual(EffortBars.level(of: "high", in: levels), 1)
        // Unknown, unset, or nothing to place it among: the middle.
        XCTAssertEqual(EffortBars.level(of: "max", in: levels), 0.5)
        XCTAssertEqual(EffortBars.level(of: nil, in: levels), 0.5)
        XCTAssertEqual(EffortBars.level(of: "high", in: ["high"]), 0.5)
    }

    func testPreparedAttachmentTranscodesHeicAndTiffToJpegWhileKeepingPngAndFilesAsIs() throws {
        // Build a tiny 2x2 CGImage and encode it as TIFF and PNG via ImageIO.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels: [UInt8] = [
            255, 0, 0, 255,   0, 255, 0, 255,
            0, 0, 255, 255,   255, 255, 255, 255,
        ]
        let ctx = try XCTUnwrap(CGContext(
            data: &pixels, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let cgImage = try XCTUnwrap(ctx.makeImage())

        func encode(_ uti: String) -> Data? {
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, uti as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, cgImage, nil)
            return CGImageDestinationFinalize(dest) ? (out as Data) : nil
        }

        let tiff = try XCTUnwrap(encode("public.tiff"))
        let convertedTiff = Attachment.prepared(name: "Capture.TIFF", data: tiff)
        XCTAssertEqual(convertedTiff.name, "Capture.jpg")
        // JPEG SOI marker: FF D8 FF
        XCTAssertEqual(Array(convertedTiff.data.prefix(3)), [0xFF, 0xD8, 0xFF])

        if let heic = encode("public.heic") {
            let convertedHeic = Attachment.prepared(name: "IMG_4821.HEIC", data: heic)
            XCTAssertEqual(convertedHeic.name, "IMG_4821.jpg")
            XCTAssertEqual(Array(convertedHeic.data.prefix(3)), [0xFF, 0xD8, 0xFF])
        }

        let png = try XCTUnwrap(encode("public.png"))
        let keptPng = Attachment.prepared(name: "Screen.png", data: png)
        XCTAssertEqual(keptPng.name, "Screen.png")
        XCTAssertEqual(keptPng.data, png)

        let pdf = Data("%PDF-1.7\n".utf8)
        let keptPdf = Attachment.prepared(name: "spec v2.pdf", data: pdf)
        XCTAssertEqual(keptPdf.name, "spec v2.pdf")
        XCTAssertEqual(keptPdf.data, pdf)

        var uploaded = Attachment(name: keptPdf.name, path: "/tmp/shed-uploads/1/spec v2.pdf")
        XCTAssertEqual(uploaded.embed, "![spec v2.pdf](</tmp/shed-uploads/1/spec v2.pdf>)")
        let split = MessageAttachments.split("Check this\n\n\(uploaded.embed!)")
        XCTAssertEqual(split.text, "Check this")
        XCTAssertEqual(split.paths, ["/tmp/shed-uploads/1/spec v2.pdf"])
        uploaded.path = nil
        XCTAssertTrue(uploaded.uploading)
    }
}
