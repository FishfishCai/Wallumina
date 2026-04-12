import Foundation
import AppKit
import Compression

// MARK: - TEX Format Constants

enum TexFormat: UInt32 {
    case argb8888 = 0
    case rgb888 = 1
    case rgb565 = 2
    case dxt5 = 4
    case dxt3 = 6
    case dxt1 = 7
    case rg88 = 8
    case r8 = 9
    case rg1616f = 10
    case r16f = 11
    case bc7 = 12
    case rgba1010102 = 13
    case rgba16161616f = 14
    case rgb161616f = 15
}

struct TexFlags: OptionSet {
    let rawValue: UInt32
    static let noInterpolation = TexFlags(rawValue: 1)
    static let clampUVs = TexFlags(rawValue: 2)
    static let isGif = TexFlags(rawValue: 4)
    static let clampUVsBorder = TexFlags(rawValue: 8)
}

// MARK: - Parsed Result

struct TexImage {
    let textureWidth: Int
    let textureHeight: Int
    let contentWidth: Int
    let contentHeight: Int
    let format: TexFormat
    let flags: TexFlags
    let mipmaps: [TexMipmap]
    let freeImageFormat: Int32
}

struct TexMipmap {
    let width: Int
    let height: Int
    let data: Data
}

// MARK: - Binary Reader

private struct BinaryReader {
    let bytes: [UInt8]
    var pos: Int = 0

    init(data: Data) {
        self.bytes = [UInt8](data)
    }

    mutating func readUInt32() -> UInt32 {
        guard pos + 4 <= bytes.count else { return 0 }
        let val = UInt32(bytes[pos]) | (UInt32(bytes[pos+1]) << 8) |
                  (UInt32(bytes[pos+2]) << 16) | (UInt32(bytes[pos+3]) << 24)
        pos += 4
        return val
    }

    mutating func readInt32() -> Int32 {
        Int32(bitPattern: readUInt32())
    }

    mutating func readBytes(_ count: Int) -> Data {
        guard count > 0, pos + count <= bytes.count else { return Data() }
        let result = Data(bytes[pos..<pos+count])
        pos += count
        return result
    }

    mutating func readMagic(_ expected: String) -> Bool {
        let expectedBytes = Array(expected.utf8)
        let len = expectedBytes.count + 1 // null terminated
        guard pos + len <= bytes.count else { return false }
        for (i, b) in expectedBytes.enumerated() {
            guard bytes[pos + i] == b else { pos += 0; return false }
        }
        guard bytes[pos + expectedBytes.count] == 0 else { return false }
        pos += len
        return true
    }

    mutating func skipString() {
        while pos < bytes.count {
            if bytes[pos] == 0 { pos += 1; return }
            pos += 1
        }
    }
}

// MARK: - Decoder

func decodeTex(at url: URL) -> TexImage? {
    guard let rawData = try? Data(contentsOf: url) else { return nil }
    return decodeTex(from: rawData)
}

func decodeTex(from rawData: Data) -> TexImage? {
    var reader = BinaryReader(data: rawData)

    // TEXV header
    guard reader.readMagic("TEXV0005") else {
        return nil
    }

    // TEXI header
    guard reader.readMagic("TEXI0001") else {
        return nil
    }

    let format = TexFormat(rawValue: reader.readUInt32()) ?? .argb8888
    let flags = TexFlags(rawValue: reader.readUInt32())
    let textureWidth = Int(reader.readUInt32())
    let textureHeight = Int(reader.readUInt32())
    let contentWidth = Int(reader.readUInt32())
    let contentHeight = Int(reader.readUInt32())
    _ = reader.readUInt32() // padding/ignored

    // TEXB header — detect version
    let texbStart = reader.pos
    var texbVersion = 0
    if reader.readMagic("TEXB0004") { texbVersion = 4 }
    else {
        reader.pos = texbStart
        if reader.readMagic("TEXB0003") { texbVersion = 3 }
        else {
            reader.pos = texbStart
            if reader.readMagic("TEXB0002") { texbVersion = 2 }
            else {
                reader.pos = texbStart
                if reader.readMagic("TEXB0001") { texbVersion = 1 }
                else {
                    return nil
                }
            }
        }
    }

    let imageCount = Int(reader.readUInt32())

    var freeImageFormat: Int32 = -1
    if texbVersion >= 3 {
        freeImageFormat = reader.readInt32()
    }
    if texbVersion >= 4 {
        _ = reader.readUInt32() // isVideoMp4
    }

    // Read mipmaps for first image
    guard imageCount >= 1 else { return nil }
    let mipmapCount = Int(reader.readUInt32())

    // Only decode the largest mipmap (first one in most formats, or find largest)
    var mipmaps: [TexMipmap] = []
    for i in 0..<mipmapCount {
        if texbVersion >= 4 {
            _ = reader.readUInt32()
            _ = reader.readUInt32()
            reader.skipString()
            _ = reader.readUInt32()
        }

        let mipWidth = Int(reader.readUInt32())
        let mipHeight = Int(reader.readUInt32())

        var compressed = false
        var uncompressedSize: Int = 0

        if texbVersion >= 2 {
            compressed = reader.readUInt32() == 1
            uncompressedSize = Int(reader.readInt32())
        }

        let compressedSize = Int(reader.readInt32())

        // Sanity check
        guard compressedSize > 0, compressedSize < rawData.count else {
            break
        }

        let pixelData = reader.readBytes(compressedSize)

        let finalData: Data
        if compressed && uncompressedSize > 0 {
            // LZ4 decompression
            if let decompressed = lz4Decompress(pixelData, outputSize: uncompressedSize) {
                finalData = decompressed
            } else {
                finalData = pixelData
            }
        } else {
            finalData = pixelData
        }

        mipmaps.append(TexMipmap(width: mipWidth, height: mipHeight, data: finalData))
    }

    return TexImage(
        textureWidth: textureWidth, textureHeight: textureHeight,
        contentWidth: contentWidth, contentHeight: contentHeight,
        format: format, flags: flags,
        mipmaps: mipmaps, freeImageFormat: freeImageFormat
    )
}

// MARK: - LZ4 Decompression

private func lz4Decompress(_ input: Data, outputSize: Int) -> Data? {
    var output = Data(count: outputSize)
    let result = output.withUnsafeMutableBytes { dstBuf in
        input.withUnsafeBytes { srcBuf in
            guard let srcPtr = srcBuf.baseAddress,
                  let dstPtr = dstBuf.baseAddress else { return 0 }
            return compression_decode_buffer(
                dstPtr.assumingMemoryBound(to: UInt8.self), outputSize,
                srcPtr.assumingMemoryBound(to: UInt8.self), input.count,
                nil, COMPRESSION_LZ4_RAW
            )
        }
    }
    return result > 0 ? output : nil
}

// MARK: - Convert to CGImage

func texToCGImage(_ tex: TexImage) -> CGImage? {
    guard let mip = tex.mipmaps.first else { return nil }

    // If freeImageFormat is set, data is embedded image (JPEG/PNG/etc.)
    if tex.freeImageFormat >= 0 {
        guard let provider = CGDataProvider(data: mip.data as CFData),
              let image = CGImage(
                  jpegDataProviderSource: provider,
                  decode: nil, shouldInterpolate: true,
                  intent: .defaultIntent
              ) ?? CGImage(
                  pngDataProviderSource: provider,
                  decode: nil, shouldInterpolate: true,
                  intent: .defaultIntent
              )
        else {
            // Try NSImage fallback
            if let nsImage = NSImage(data: mip.data),
               let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return cgImage
            }
            return nil
        }
        return image
    }

    // Raw pixel data — convert based on format
    switch tex.format {
    case .argb8888:
        // WE's "ARGB8888" is actually RGBA byte order
        return cgImageFromRaw(mip.data, width: mip.width, height: mip.height,
                              bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: mip.width * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
    case .rgb888:
        // Pad to RGBA
        var rgba = Data(count: mip.width * mip.height * 4)
        for i in 0..<(mip.width * mip.height) {
            let srcOff = i * 3
            let dstOff = i * 4
            guard srcOff + 2 < mip.data.count else { break }
            rgba[dstOff] = mip.data[srcOff]
            rgba[dstOff+1] = mip.data[srcOff+1]
            rgba[dstOff+2] = mip.data[srcOff+2]
            rgba[dstOff+3] = 255
        }
        return cgImageFromRaw(rgba, width: mip.width, height: mip.height,
                              bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: mip.width * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue))
    case .dxt1, .dxt3, .dxt5, .bc7:
        // Software decode BCn to RGBA
        return decodeBCn(mip.data, width: mip.width, height: mip.height, format: tex.format)
    default:
        return nil
    }
}

private func cgImageFromRaw(_ data: Data, width: Int, height: Int,
                             bitsPerComponent: Int, bitsPerPixel: Int,
                             bytesPerRow: Int, space: CGColorSpace,
                             bitmapInfo: CGBitmapInfo) -> CGImage? {
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    return CGImage(width: width, height: height,
                   bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerPixel,
                   bytesPerRow: bytesPerRow, space: space,
                   bitmapInfo: bitmapInfo, provider: provider,
                   decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

// MARK: - BCn (DXT) Software Decoder

private func decodeBCn(_ data: Data, width: Int, height: Int, format: TexFormat) -> CGImage? {
    let blockW = (width + 3) / 4
    let blockH = (height + 3) / 4
    let blockSize = format == .dxt1 ? 8 : 16
    let expectedSize = blockW * blockH * blockSize

    guard data.count >= expectedSize else { return nil }

    var output = [UInt8](repeating: 0, count: width * height * 4)

    data.withUnsafeBytes { src in
        let ptr = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
        var blockOffset = 0
        var block = [UInt8](repeating: 0, count: 64) // reuse across blocks

        for by in 0..<blockH {
            for bx in 0..<blockW {
                for i in 0..<64 { block[i] = 0 }

                switch format {
                case .dxt1:
                    decodeDXT1Block(ptr + blockOffset, &block)
                case .dxt3:
                    decodeDXT3Block(ptr + blockOffset, &block)
                case .dxt5:
                    decodeDXT5Block(ptr + blockOffset, &block)
                default:
                    break
                }

                // Copy 4x4 block to output
                for py in 0..<4 {
                    for px in 0..<4 {
                        let ox = bx * 4 + px, oy = by * 4 + py
                        guard ox < width, oy < height else { continue }
                        let dstOff = (oy * width + ox) * 4
                        let srcOff = (py * 4 + px) * 4
                        output[dstOff] = block[srcOff]
                        output[dstOff+1] = block[srcOff+1]
                        output[dstOff+2] = block[srcOff+2]
                        output[dstOff+3] = block[srcOff+3]
                    }
                }
                blockOffset += blockSize
            }
        }
    }

    let outData = Data(output)
    return cgImageFromRaw(outData, width: width, height: height,
                          bitsPerComponent: 8, bitsPerPixel: 32,
                          bytesPerRow: width * 4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
}

// DXT1 block: 2 x 16-bit colors + 4x4 2-bit lookup table
private func decodeDXT1Block(_ src: UnsafePointer<UInt8>, _ out: inout [UInt8]) {
    let c0 = UInt16(src[0]) | (UInt16(src[1]) << 8)
    let c1 = UInt16(src[2]) | (UInt16(src[3]) << 8)

    var colors = [[UInt8]](repeating: [0,0,0,255], count: 4)
    colors[0] = unpackRGB565(c0)
    colors[1] = unpackRGB565(c1)

    if c0 > c1 {
        colors[2] = mixColors(colors[0], colors[1], 2, 1)
        colors[3] = mixColors(colors[0], colors[1], 1, 2)
    } else {
        colors[2] = mixColors(colors[0], colors[1], 1, 1)
        colors[3] = [0, 0, 0, 0] // transparent
    }

    for i in 0..<4 {
        let row = src[4 + i]
        for j in 0..<4 {
            let idx = Int((row >> (j * 2)) & 0x03)
            let off = (i * 4 + j) * 4
            out[off] = colors[idx][0]
            out[off+1] = colors[idx][1]
            out[off+2] = colors[idx][2]
            out[off+3] = colors[idx][3]
        }
    }
}

// DXT3: explicit 4-bit alpha + DXT1 color
private func decodeDXT3Block(_ src: UnsafePointer<UInt8>, _ out: inout [UInt8]) {
    // First 8 bytes: alpha (4 bits per pixel, row-major)
    var alphas = [UInt8](repeating: 255, count: 16)
    for i in 0..<4 {
        let lo = src[i * 2]
        let hi = src[i * 2 + 1]
        alphas[i * 4 + 0] = (lo & 0x0F) * 17
        alphas[i * 4 + 1] = ((lo >> 4) & 0x0F) * 17
        alphas[i * 4 + 2] = (hi & 0x0F) * 17
        alphas[i * 4 + 3] = ((hi >> 4) & 0x0F) * 17
    }
    decodeDXT1Block(src + 8, &out)
    for i in 0..<16 { out[i * 4 + 3] = alphas[i] }
}

// DXT5: interpolated alpha + DXT1 color
private func decodeDXT5Block(_ src: UnsafePointer<UInt8>, _ out: inout [UInt8]) {
    let a0 = src[0], a1 = src[1]
    var alphaTable = [UInt8](repeating: 0, count: 8)
    alphaTable[0] = a0; alphaTable[1] = a1

    if a0 > a1 {
        for i in 2..<8 {
            alphaTable[i] = UInt8((Int(a0) * (8 - i) + Int(a1) * (i - 1)) / 7)
        }
    } else {
        for i in 2..<6 {
            alphaTable[i] = UInt8((Int(a0) * (6 - i) + Int(a1) * (i - 1)) / 5)
        }
        alphaTable[6] = 0; alphaTable[7] = 255
    }

    // 48-bit alpha index (3 bits per pixel)
    var alphaIdx: UInt64 = 0
    for i in 0..<6 {
        alphaIdx |= UInt64(src[2 + i]) << (i * 8)
    }

    var alphas = [UInt8](repeating: 255, count: 16)
    for i in 0..<16 {
        let idx = Int((alphaIdx >> (i * 3)) & 0x07)
        alphas[i] = alphaTable[idx]
    }

    decodeDXT1Block(src + 8, &out)
    for i in 0..<16 { out[i * 4 + 3] = alphas[i] }
}

private func unpackRGB565(_ c: UInt16) -> [UInt8] {
    let r = UInt8((c >> 11) & 0x1F) * 255 / 31
    let g = UInt8((c >> 5) & 0x3F) * 255 / 63
    let b = UInt8(c & 0x1F) * 255 / 31
    return [r, g, b, 255]
}

private func mixColors(_ a: [UInt8], _ b: [UInt8], _ wa: Int, _ wb: Int) -> [UInt8] {
    let d = wa + wb
    return [
        UInt8((Int(a[0]) * wa + Int(b[0]) * wb) / d),
        UInt8((Int(a[1]) * wa + Int(b[1]) * wb) / d),
        UInt8((Int(a[2]) * wa + Int(b[2]) * wb) / d),
        255
    ]
}

// MARK: - Save to PNG

func texToImageFile(_ tex: TexImage, destination: URL) -> Bool {
    guard let cgImage = texToCGImage(tex) else { return false }

    // Crop to content dimensions if different from texture dimensions
    let finalImage: CGImage
    if tex.contentWidth < tex.textureWidth || tex.contentHeight < tex.textureHeight {
        if let cropped = cgImage.cropping(to: CGRect(x: 0, y: 0,
                                                      width: tex.contentWidth,
                                                      height: tex.contentHeight)) {
            finalImage = cropped
        } else {
            finalImage = cgImage
        }
    } else {
        finalImage = cgImage
    }

    let rep = NSBitmapImageRep(cgImage: finalImage)
    guard let pngData = rep.representation(using: .png, properties: [:]) else { return false }
    do {
        try pngData.write(to: destination)
        return true
    } catch {
        return false
    }
}
