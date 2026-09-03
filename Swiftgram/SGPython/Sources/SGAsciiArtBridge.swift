import Foundation
import UIKit

// MARK: ViboGram - ASCII-art photo plugin, image-side half. Idea + overall
// mechanism (aspect-corrected downsample, luminance-to-character ladder,
// message-length budget by shrinking the column count) ported from
// Margelet's own equivalent plugin. Our stdlib has no image codec
// (Pillow/PIL isn't vendored), so -- exactly like the source plugin relies
// on the host platform's own bitmap APIs for decode/scale rather than doing
// it in pure Python -- decode and downsampling live here in Swift
// (CoreGraphics), and only the brightness grid crosses into the actual
// `.vibo` file (ascii_art.vibo) for the art-rendering step itself.
public enum SGAsciiArtBridge {
    // A cell in a monospace font is roughly twice as tall as it is wide, so
    // half as many rows as a 1:1 sample of the image would need.
    private static let cellAspect: Double = 0.5
    private static let maxCharacterBudget = 3600
    private static let minColumns = 16
    private static let maxColumns = 120
    // MARK: ViboGram - bugfix: `fitColumns` below only ever *shrinks*
    // columns to fit the budget, and stops once columns hits `minColumns`
    // regardless of whether the budget is actually met -- for an extreme
    // aspect ratio (a very tall/narrow image), `rows` at minColumns can
    // still be far larger than the budget allows, since nothing was ever
    // capping rows on its own. That's a source array potentially large
    // enough to be a real problem downstream (JSON-encoding it, a >4096
    // char Telegram message once rendered, a huge alert). Same idea as
    // minColumns/maxColumns, just for the other axis.
    private static let maxRows = 200

    private static func boundedColumns(_ columns: Int) -> Int {
        return max(minColumns, min(maxColumns, columns))
    }

    private static func rows(forColumns columns: Int, aspectRatio: Double) -> Int {
        let raw = max(1, Int((Double(columns) * aspectRatio * cellAspect).rounded()))
        return min(maxRows, raw)
    }

    // Shrinks columns until (columns+1) * rows fits the message-length
    // budget (the +1 accounts for the newline ending each row) -- mirrors
    // the source plugin's own reasoning that rows must be computed from the
    // image's real aspect ratio before a message-length-safe width can be
    // chosen, not the other way around.
    private static func fitColumns(_ columns: Int, aspectRatio: Double) -> Int {
        var columns = boundedColumns(columns)
        while columns > minColumns {
            let r = rows(forColumns: columns, aspectRatio: aspectRatio)
            if (columns + 1) * r <= maxCharacterBudget {
                break
            }
            columns -= 4
        }
        return columns
    }

    public struct BrightnessGrid {
        public let columns: Int
        public let rows: Int
        // Row-major, one 0...255 luminance value per cell.
        public let values: [[Int]]
    }

    public static func brightnessGrid(from image: UIImage, requestedColumns: Int) -> BrightnessGrid? {
        guard let cgImage = image.cgImage, cgImage.width > 0, cgImage.height > 0 else {
            return nil
        }
        let aspectRatio = Double(cgImage.height) / Double(cgImage.width)
        let columns = fitColumns(requestedColumns, aspectRatio: aspectRatio)
        let rowCount = rows(forColumns: columns, aspectRatio: aspectRatio)

        // Downsample via a CoreGraphics draw pass (bilinear-filtered by
        // default), not manual nearest-neighbor sampling -- same reasoning
        // as the source plugin's use of Bitmap.createScaledBitmap: point
        // sampling would drop thin lines the average of the covered pixels
        // still carries.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * columns
        guard let context = CGContext(
            data: nil,
            width: columns,
            height: rowCount,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: columns, height: rowCount))
        guard let data = context.data else {
            return nil
        }
        let buffer = data.bindMemory(to: UInt8.self, capacity: bytesPerRow * rowCount)

        var grid: [[Int]] = []
        grid.reserveCapacity(rowCount)
        for y in 0..<rowCount {
            var line: [Int] = []
            line.reserveCapacity(columns)
            for x in 0..<columns {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let red = Int(buffer[offset])
                let green = Int(buffer[offset + 1])
                let blue = Int(buffer[offset + 2])
                // ITU-R BT.601 luma weights -- a standard broadcast/imaging
                // formula, not specific to any one implementation.
                let luminance = (red * 299 + green * 587 + blue * 114) / 1000
                line.append(luminance)
            }
            grid.append(line)
        }
        return BrightnessGrid(columns: columns, rows: rowCount, values: grid)
    }
}
