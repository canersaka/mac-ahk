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

    // Find the template anywhere on any display (full ImageSearch).
    // Returns the global point (CGEvent coordinate space) at the center
    // of the best match within tolerance (0…1), or nil. Costs a full
    // screen grab plus a scan, so expect ~a few hundred ms per call.
    static func findOnScreen(template: CGImage,
                             tolerance: Double) -> CGPoint? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success,
              count > 0 else { return nil }
        var best: (point: CGPoint, score: Double)?
        for id in ids.prefix(Int(count)) {
            guard let shot = CGDisplayCreateImage(id),
                  let hit = locate(template: template, in: shot),
                  hit.score <= tolerance else { continue }
            // Match position is in screenshot pixels; displays report
            // bounds in points (retina), so scale back.
            let bounds = CGDisplayBounds(id)
            let pt = CGPoint(
                x: bounds.origin.x
                    + hit.center.x * bounds.width / CGFloat(shot.width),
                y: bounds.origin.y
                    + hit.center.y * bounds.height / CGFloat(shot.height))
            if best == nil || hit.score < best!.score {
                best = (pt, hit.score)
            }
        }
        return best?.point
    }

    // Naive template matching, made affordable by downscaling both
    // images by the same factor and comparing only a coarse grid of
    // template pixels, with an early-out against the best score so far.
    // Returns the best match's center (haystack pixel coordinates) and
    // its mean per-channel difference (0 identical … 1 opposite).
    private static func locate(template: CGImage, in haystack: CGImage)
        -> (center: CGPoint, score: Double)? {
        let tw = template.width, th = template.height
        let hw = haystack.width, hh = haystack.height
        guard tw > 0, th > 0, tw <= hw, th <= hh else { return nil }

        // Shrink the search space to ~640px on the long side, but never
        // let the template drop below ~8px on its short side.
        var f = max(1, (max(hw, hh) + 639) / 640)
        while f > 1 && min(tw, th) / f < 8 { f -= 1 }

        let sw = max(1, hw / f), sh = max(1, hh / f)
        let stw = max(1, tw / f), sth = max(1, th / f)
        guard stw <= sw, sth <= sh,
              let hay = rgbaBytes(haystack, width: sw, height: sh),
              let tpl = rgbaBytes(template, width: stw, height: sth)
        else { return nil }

        // ≤ ~13 sample points per axis, spread over the template.
        let gx = max(1, stw / 12), gy = max(1, sth / 12)
        var samples: [(Int, Int)] = []
        var py = 0
        while py < sth {
            var px = 0
            while px < stw {
                samples.append((px, py))
                px += gx
            }
            py += gy
        }

        var bestScore = Int.max
        var bestX = 0, bestY = 0
        for y in 0...(sh - sth) {
            for x in 0...(sw - stw) {
                var total = 0
                for (px, py) in samples {
                    let hi = ((y + py) * sw + (x + px)) * 4
                    let ti = (py * stw + px) * 4
                    total += abs(Int(hay[hi]) - Int(tpl[ti]))
                        + abs(Int(hay[hi + 1]) - Int(tpl[ti + 1]))
                        + abs(Int(hay[hi + 2]) - Int(tpl[ti + 2]))
                    if total >= bestScore { break }
                }
                if total < bestScore {
                    bestScore = total
                    bestX = x
                    bestY = y
                }
            }
        }
        guard bestScore < Int.max else { return nil }
        let score = Double(bestScore) / Double(samples.count * 3 * 255)
        return (CGPoint(x: Double((bestX + stw / 2) * f),
                        y: Double((bestY + sth / 2) * f)), score)
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image)
            .representation(using: .png, properties: [:])
    }

    static func image(fromPNG data: Data) -> CGImage? {
        NSBitmapImageRep(data: data)?.cgImage
    }

    private static func rgbaBytes(_ image: CGImage, size: Int) -> [UInt8]? {
        rgbaBytes(image, width: size, height: size)
    }

    private static func rgbaBytes(_ image: CGImage, width: Int,
                                  height: Int) -> [UInt8]? {
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let ptr = ctx.data else { return nil }
        return Array(UnsafeBufferPointer(
            start: ptr.assumingMemoryBound(to: UInt8.self),
            count: width * height * 4))
    }
}
