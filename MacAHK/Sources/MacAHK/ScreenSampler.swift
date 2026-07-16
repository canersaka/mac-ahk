import Foundation
import AppKit
import CoreGraphics

// Screen pixel sampling for the pixel/snapshot conditions. Needs the
// Screen Recording permission — requested only when these conditions are
// actually used, never at launch.
enum ScreenSampler {
    // Capture a rect given in global (top-left origin) coordinates, the
    // same space CGEvent locations use.
    static func capture(rect: CGRect) -> CGImage? {
        var display = CGMainDisplayID()
        var found: CGDirectDisplayID = 0
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(CGPoint(x: rect.midX, y: rect.midY),
                                  1, &found, &count) == .success, count > 0 {
            display = found
        }
        let bounds = CGDisplayBounds(display)
        let local = CGRect(x: rect.origin.x - bounds.origin.x,
                           y: rect.origin.y - bounds.origin.y,
                           width: max(rect.width, 1),
                           height: max(rect.height, 1))
        return CGDisplayCreateImage(display, rect: local)
    }

    // Average color of a small area around a point (3×3, tolerant of
    // retina scaling and antialiasing).
    static func pixelRGB(at point: CGPoint) -> (r: Int, g: Int, b: Int)? {
        guard let img = capture(rect: CGRect(x: point.x - 1, y: point.y - 1,
                                             width: 3, height: 3))
        else { return nil }
        guard let bytes = rgbaBytes(img, size: 4) else { return nil }
        var r = 0, g = 0, b = 0
        let pixels = bytes.count / 4
        for i in stride(from: 0, to: bytes.count, by: 4) {
            r += Int(bytes[i]); g += Int(bytes[i + 1]); b += Int(bytes[i + 2])
        }
        return (r / pixels, g / pixels, b / pixels)
    }

    // Mean per-channel difference between two images, 0 (identical) to 1
    // (opposite). Both are normalized to 32×32 first, so retina scale and
    // small size differences don't matter.
    static func difference(_ a: CGImage, _ b: CGImage) -> Double? {
        let n = 32
        guard let ba = rgbaBytes(a, size: n),
              let bb = rgbaBytes(b, size: n) else { return nil }
        var total = 0
        for i in stride(from: 0, to: min(ba.count, bb.count), by: 4) {
            total += abs(Int(ba[i]) - Int(bb[i]))
                + abs(Int(ba[i + 1]) - Int(bb[i + 1]))
                + abs(Int(ba[i + 2]) - Int(bb[i + 2]))
        }
        return Double(total) / Double(n * n * 3 * 255)
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image)
            .representation(using: .png, properties: [:])
    }

    static func image(fromPNG data: Data) -> CGImage? {
        NSBitmapImageRep(data: data)?.cgImage
    }

    private static func rgbaBytes(_ image: CGImage, size: Int) -> [UInt8]? {
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        guard let ptr = ctx.data else { return nil }
        return Array(UnsafeBufferPointer(
            start: ptr.assumingMemoryBound(to: UInt8.self),
            count: size * size * 4))
    }
}
