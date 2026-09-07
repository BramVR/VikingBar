import AppKit
import Testing
@testable import VikingBarApp
@testable import VikingBarCore

struct HelmetRendererTests {
    private let treatments: [(String, HelmetTreatment)] = [
        ("full", .finite(fraction: 1)), ("half", .finite(fraction: 0.5)),
        ("near-empty", .finite(fraction: 0.01)), ("empty", .finite(fraction: 0)),
        ("unlimited", .unlimited), ("unavailable", .unavailable),
    ]

    @Test(arguments: [1, 2])
    func `native vector keeps silhouette and left anchored draining fill`(scale: Int) throws {
        let rasters = try self.treatments.map { try self.raster($0.1, scale: scale) }
        let empty = rasters[3]
        #expect(HelmetRenderer.image(for: .finite(fraction: 1)).isTemplate)
        for raster in rasters {
            #expect(raster.width == 22 * scale)
            #expect(raster.height == 18 * scale)
            #expect(self.bounds(raster) == self.bounds(empty))
        }
        let full = rasters[0]
        let half = rasters[1]
        let nearEmpty = rasters[2]
        let yCoord = 14 * scale
        #expect(self.alpha(full, x: 5 * scale, y: yCoord) == 0)
        #expect(self.alpha(half, x: 5 * scale, y: yCoord) == 0)
        #expect(self.alpha(half, x: 16 * scale, y: yCoord) == 255)
        #expect(self.alpha(empty, x: 5 * scale, y: yCoord) == 255)
        var removedAlpha = [Int](repeating: 0, count: 4)
        for yCoord in 0 ..< empty.height {
            for xCoord in 0 ..< empty.width {
                let values = [full, half, nearEmpty, empty].map { self.alpha($0, x: xCoord, y: yCoord) }
                #expect(values[0] <= values[1] && values[1] <= values[2] && values[2] <= values[3])
                for index in 0 ..< 4 {
                    removedAlpha[index] += Int(values[3]) - Int(values[index])
                }
            }
        }
        #expect(removedAlpha[0] > removedAlpha[1])
        #expect(removedAlpha[1] > removedAlpha[2])
        #expect(removedAlpha[2] > 0)
        #expect(removedAlpha[3] == 0)
        #expect(abs(removedAlpha[0] - 2 * removedAlpha[1]) < 10)
        #expect(rasters[4].dataProvider?.data != empty.dataProvider?.data)
        #expect(rasters[5].dataProvider?.data != empty.dataProvider?.data)
        #expect(rasters[4].dataProvider?.data != rasters[5].dataProvider?.data)
    }

    @Test func `render contact sheet when an explicit proof directory is supplied`() throws {
        guard let path = ProcessInfo.processInfo.environment["VIKINGBAR_RENDER_PROOF_DIR"] else { return }
        try #require(path.hasPrefix("/"))
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sheet = try self.context(width: 720, height: 400)
        sheet.setFillColor(CGColor(gray: 0.85, alpha: 1))
        sheet.fill(CGRect(x: 0, y: 0, width: 720, height: 400))
        for (row, appearance) in [(1, false), (2, false), (1, true), (2, true)].enumerated() {
            let (scale, dark) = appearance
            for (column, entry) in self.treatments.enumerated() {
                let mask = try self.raster(entry.1, scale: scale)
                let icon = try self.composite(mask, dark: dark)
                let name = "\(entry.0)-\(dark ? "dark" : "light")-\(scale)x"
                try self.save(icon, to: directory.appending(path: name + ".png"))
                sheet.setFillColor(CGColor(gray: dark ? 0 : 1, alpha: 1))
                let cell = CGRect(x: column * 120, y: (3 - row) * 100, width: 120, height: 100)
                sheet.fill(cell)
                sheet.interpolationQuality = .none
                sheet.draw(icon, in: CGRect(x: cell.minX + 16, y: cell.minY + 20, width: 88, height: 72))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: sheet, flipped: false)
                ("\(entry.0) \(scale)x" as NSString).draw(
                    at: CGPoint(x: cell.minX + 5, y: cell.minY + 4),
                    withAttributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: dark ? NSColor.white : .black,
                    ],
                )
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        try self.save(#require(sheet.makeImage()), to: directory.appending(path: "helmet-contact-sheet.png"))
    }

    private func raster(_ treatment: HelmetTreatment, scale: Int) throws -> CGImage {
        let context = try self.context(width: 22 * scale, height: 18 * scale)
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        HelmetRenderer.draw(treatment, in: context)
        return try #require(context.makeImage())
    }

    private func context(width: Int, height: Int) throws -> CGContext {
        try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    }

    private func alpha(_ image: CGImage, x xCoord: Int, y yCoord: Int) -> UInt8 {
        let bytes = CFDataGetBytePtr(image.dataProvider!.data!)!
        return bytes[yCoord * image.bytesPerRow + xCoord * 4 + 3]
    }

    private func bounds(_ image: CGImage) -> CGRect {
        var result = CGRect.null
        for yCoord in 0 ..< image.height {
            for xCoord in 0 ..< image.width where self.alpha(image, x: xCoord, y: yCoord) > 0 {
                result = result.union(CGRect(x: xCoord, y: yCoord, width: 1, height: 1))
            }
        }
        return result
    }

    private func composite(_ mask: CGImage, dark: Bool) throws -> CGImage {
        let context = try self.context(width: mask.width, height: mask.height)
        let bounds = CGRect(x: 0, y: 0, width: mask.width, height: mask.height)
        context.setFillColor(CGColor(gray: dark ? 0 : 1, alpha: 1))
        context.fill(bounds)
        context.clip(to: bounds, mask: mask)
        context.setFillColor(CGColor(gray: dark ? 1 : 0, alpha: 1))
        context.fill(bounds)
        return try #require(context.makeImage())
    }

    private func save(_ image: CGImage, to url: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
