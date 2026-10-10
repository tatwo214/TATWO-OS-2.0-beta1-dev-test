import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Twelve original geometric pixel creatures, drawn here without external artwork.
enum PetAvatars {
    static let catalog = (0..<12).map { "pixel-\($0)" }
    static let uploadLimit = 2 * 1024 * 1024
    static let side = 256
    static func valid(_ name: String) -> Bool { name == "uploaded" || catalog.contains(name) }
    static func stable(_ projectID: UUID) -> String {
        let hash = projectID.uuidString.lowercased().utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return catalog[Int(hash % UInt64(catalog.count))]
    }
    private static func canvas() throws -> CGContext {
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw PetError.invalidData }
        return context
    }
    private static func encode(_ context: CGContext) throws -> Data {
        guard let image = context.makeImage() else { throw PetError.invalidData }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else { throw PetError.invalidData }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PetError.invalidData }
        return buffer as Data
    }
    static func png(_ avatar: String) throws -> Data {
        guard let seed = catalog.firstIndex(of: avatar) else { throw PetError.invalidData }
        let context = try canvas()
        let colors: [(Double, Double, Double)] = [(0.2,0.7,0.6),(0.6,0.4,0.8),(0.9,0.5,0.2),(0.3,0.6,0.9),
            (0.8,0.3,0.5),(0.6,0.7,0.2),(0.4,0.8,0.9),(0.9,0.7,0.3),(0.5,0.4,0.7),(0.3,0.7,0.3),(0.9,0.5,0.6),(0.6,0.6,0.8)]
        let color = colors[seed]
        func pixel(_ x: Int, _ y: Int, _ rgb: (Double, Double, Double)) {
            context.setFillColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
            context.fill(CGRect(x: x * 16, y: y * 16, width: 16, height: 16))
        }
        for y in 3...12 { for x in 3...12 {
            let corner = (x == 3 || x == 12) && (y == 3 || y == 12)
            if !corner { pixel(x, y, color) }
        } }
        for x in [4 + seed % 3, 11 - seed % 3] { pixel(x, 13, color); pixel(x, 14, color) }
        for x in 5...10 where (x + seed) % 3 == 0 { pixel(x, 2, color) }
        let dark = (0.1, 0.15, 0.2)
        for x in [5, 10] { pixel(x, 9, dark); if seed % 2 == 0 { pixel(x, 8, dark) }; pixel(x, 10, (1,1,1)) }
        for x in 6...9 where seed % 3 == 0 || x % 2 == seed % 2 { pixel(x, 6, dark) }
        return try encode(context)
    }
    static func upload(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= uploadLimit,
              let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source),
              [UTType.png.identifier, UTType.jpeg.identifier].contains(type as String),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: side] as CFDictionary) else { throw PetError.invalidData }
        let context = try canvas(); context.interpolationQuality = .high
        let scale = min(Double(side) / Double(image.width), Double(side) / Double(image.height))
        let width = Double(image.width) * scale, height = Double(image.height) * scale
        context.draw(image, in: CGRect(x: (Double(side) - width) / 2, y: (Double(side) - height) / 2, width: width, height: height))
        return try encode(context)
    }
}
