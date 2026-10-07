import AppKit
import ImageIO
import UniformTypeIdentifiers

func nativeImage(
  _ source: UnsafePointer<CChar>?, _ destination: UnsafePointer<CChar>?, _ size: UInt32,
  _ options: UnsafePointer<CChar>?, _ result: UnsafeMutablePointer<LiltImageInfo>?
) -> Int32 {
  autoreleasepool {
    guard let source, let destination, let options, let result else { return 1 }
    let input = URL(fileURLWithPath: String(cString: source))
    let output = URL(fileURLWithPath: String(cString: destination))
    let opts =
      (try? JSONSerialization.jsonObject(with: Data(String(cString: options).utf8)))
      as? [String: Any] ?? [:]
    guard
      let src = CGImageSourceCreateWithURL(
        input as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    else { return 2 }
    let properties = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    let w = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
    let h = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    let rotated = (5...8).contains(orientation)
    result.pointee.width = UInt32(rotated ? h : w)
    result.pointee.height = UInt32(rotated ? w : h)
    result.pointee.frames = UInt32(CGImageSourceGetCount(src))
    let limit = size == 0 ? max(w, h) : min(Int(size), max(w, h))
    if limit <= 0
      || (opts["thumbnail"] as? Bool != true && Int64(w) * Int64(h) > 200_000_000 && size == 0)
    {
      return 3
    }
    let raw = ["dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf", "pef"].contains(
      input.pathExtension.lowercased())
    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: !raw,
      kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: limit,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    guard
      let decoded = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbnailOptions as CFDictionary)
    else { return 4 }
    let format = opts["format"] as? String ?? "png"
    let transparency = opts["transparency"] as? String ?? "preserve"
    let flatten = format == "jpeg" || transparency != "preserve"
    guard let colour = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: decoded.width, height: decoded.height, bitsPerComponent: 8,
        bytesPerRow: 0, space: colour, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return 5 }
    let bounds = CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height)
    if flatten {
      context.setFillColor((transparency == "black" ? NSColor.black : NSColor.white).cgColor)
      context.fill(bounds)
    }
    context.interpolationQuality = .high
    context.draw(decoded, in: bounds)
    guard let image = context.makeImage() else { return 6 }
    let temporary = output.appendingPathExtension("partial")
    defer { try? FileManager.default.removeItem(at: temporary) }
    guard
      let target = CGImageDestinationCreateWithURL(
        temporary as CFURL,
        (format == "jpeg" ? UTType.jpeg.identifier : UTType.png.identifier) as CFString, 1, nil)
    else { return 7 }
    var metadata: [CFString: Any] = opts["metadata"] as? Bool == true ? properties : [:]
    metadata[kCGImagePropertyOrientation] = 1
    metadata[kCGImagePropertyPixelWidth] = image.width
    metadata[kCGImagePropertyPixelHeight] = image.height
    metadata[kCGImageDestinationLossyCompressionQuality] =
      Double(opts["quality"] as? Int ?? 88) / 100
    CGImageDestinationAddImage(target, image, metadata as CFDictionary)
    guard CGImageDestinationFinalize(target) else { return 8 }
    do {
      if FileManager.default.fileExists(atPath: output.path) {
        try FileManager.default.removeItem(at: output)
      }
      try FileManager.default.moveItem(at: temporary, to: output)
      return 0
    } catch { return 9 }
  }
}
