import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Payment-bill screenshots are re-encoded locally before leaving the device:
// downscaled, JPEG-compressed, and stripped of any metadata the source file carried.
struct BillImage: Sendable, Equatable {
    static let maximumSourceBytes = 32 * 1024 * 1024
    static let maximumPixelSize = 1280
    static let maximumTransferBytes = 3 * 1024 * 1024

    let jpeg: Data
    let pixelWidth: Int
    let pixelHeight: Int

    var dataURL: String { "data:image/jpeg;base64," + jpeg.base64EncodedString() }
    var transferredBytes: Int { dataURL.utf8.count }
    var sizeDescription: String { "\(pixelWidth)×\(pixelHeight)，压缩后约 \(max(1, transferredBytes / 1024)) KB" }

    static func read(url: URL) throws -> BillImage {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Bound the read itself, including when the source changes after selection.
        let data = try handle.read(upToCount: maximumSourceBytes + 1) ?? Data()
        return try prepare(data)
    }

    static func prepare(_ source: Data) throws -> BillImage {
        guard !source.isEmpty, source.count <= maximumSourceBytes else {
            throw LedgerError.invalid("图片过大，请选择 32 MiB 以内的截图。")
        }
        guard let imageSource = CGImageSourceCreateWithData(source as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(imageSource) > 0 else {
            throw LedgerError.invalid("无法读取所选图片，请换一张账单截图。")
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions) else {
            throw LedgerError.invalid("无法读取所选图片，请换一张账单截图。")
        }
        for quality in [0.75, 0.6, 0.45] {
            if let jpeg = encodeJPEG(image, quality: quality), jpeg.count <= maximumTransferBytes {
                return BillImage(jpeg: jpeg, pixelWidth: image.width, pixelHeight: image.height)
            }
        }
        throw LedgerError.invalid("截图压缩后仍超过发送上限，请裁剪后重试。")
    }

    private static func encodeJPEG(_ image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
