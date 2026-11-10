// A new row in a conversation prints in: its dots come in on the 2 pt halftone grid, in ordered-dither order, until it
// is solid. Played by the render server on the row's own layer, so it costs the main thread nothing while it runs.
#if os(iOS)
import UIKit

enum DitherReveal {
    /// The halftone grid the rest of the app is drawn on.
    static let cell: CGFloat = 2
    /// From the first dots to solid.
    static let duration: CFTimeInterval = 0.28

    /// 4×4 Bayer ranks: the order the dots of each 4×4 tile come in.
    private static let bayer: [Int] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]

    /// For each rank, a tile with only that rank's dots: stacked, the sixteen cover the whole tile.
    @MainActor static let levels: [CGColor] = (0..<16).map(level)

    private static func level(_ rank: Int) -> CGColor {
        let side = cell * 4
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            UIColor.black.setFill()
            for index in 0..<16 where bayer[index] == rank {
                // A hair over the cell, so neighbouring dots never leave a seam when the tile scales.
                context.fill(CGRect(x: CGFloat(index % 4) * cell, y: CGFloat(index / 4) * cell, width: cell + 0.01, height: cell + 0.01))
            }
        }
        return UIColor(patternImage: image).cgColor
    }

    /// The front of a strip of text printing in along its line, `width` wide: solid where it meets the text already
    /// printed, thinning out to nothing ahead of it, over a faint wash so the dots don't cut the letters hard.
    @MainActor static func front(_ width: CGFloat) -> CGColor {
        let columns = max(4, Int(width / cell) / 4 * 4)
        if let made = fronts[columns] { return made }
        let format = UIGraphicsImageRendererFormat()
        format.scale = UIScreen.main.scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: CGFloat(columns) * cell, height: cell * 4), format: format).image { context in
            for column in 0..<columns {
                let density = 1 - (Double(column) + 0.5) / Double(columns)
                UIColor.black.withAlphaComponent(0.45 * density * density).setFill()
                context.fill(CGRect(x: CGFloat(column) * cell, y: 0, width: cell + 0.01, height: cell * 4))
                UIColor.black.setFill()
                for row in 0..<4 where Double(bayer[row * 4 + column % 4]) < density * 16 {
                    context.fill(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell + 0.01, height: cell + 0.01))
                }
            }
        }
        let made = UIColor(patternImage: image).cgColor
        fronts[columns] = made
        return made
    }

    @MainActor private static var fronts: [Int: CGColor] = [:]

    /// Ends a print-in still running on `view`, leaving it solid.
    @MainActor static func stop(on view: UIView) {
        let layer = view.layer
        guard layer.mask != nil || layer.animation(forKey: "reveal") != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.mask = nil
        layer.removeAnimation(forKey: "reveal")
        CATransaction.commit()
    }

    /// Prints `view` in. Taller than the view, so a row still growing as it arrives (a reply streaming in) stays
    /// covered; removed once solid.
    @MainActor static func play(on view: UIView, reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled) {
        let layer = view.layer
        if reduceMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.2
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(fade, forKey: "reveal")
            return
        }
        let mask = CALayer()
        mask.frame = CGRect(x: -40, y: -40, width: max(view.bounds.width, 500) + 80, height: max(view.bounds.height, 900) + 2000)
        let now = layer.convertTime(CACurrentMediaTime(), from: nil)
        // Each rank fades up over a short step; the ranks start one after another, the last finishing at `duration`.
        let step = duration * 0.3
        for rank in 0..<16 {
            let dots = CALayer()
            dots.frame = mask.bounds
            dots.backgroundColor = levels[rank]
            dots.opacity = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = step
            fade.beginTime = now + (duration - step) * Double(rank) / 15
            fade.fillMode = .backwards
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dots.add(fade, forKey: "reveal")
            mask.addSublayer(dots)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.mask = mask
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { [weak layer] in
            guard let layer, layer.mask === mask else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.mask = nil
            CATransaction.commit()
        }
    }
}
#endif
