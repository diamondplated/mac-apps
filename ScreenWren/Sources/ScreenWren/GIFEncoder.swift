import Foundation

/// A colour table shared by every frame of one recording. Index 255 is reserved for
/// "unchanged since the previous frame", so a palette holds at most 255 colours.
struct GIFPalette: Equatable, Sendable {
    static let transparentIndex: UInt8 = 255
    static let maximumColors = 255

    /// RGB triplets.
    let rgb: [UInt8]
    var count: Int { rgb.count / 3 }
}

/// Collects a histogram from frames sampled across the whole recording, then splits it by
/// median cut into one palette. One palette for the clip keeps colours from flickering
/// between frames and lets unchanged pixels be recognised exactly.
struct GIFPaletteBuilder: Sendable {
    private static let binCount = 1 << 15
    private var counts = [UInt32](repeating: 0, count: binCount)
    private var sums = [UInt64](repeating: 0, count: binCount * 3)
    private(set) var sampleCount = 0

    /// Adds every `step`th pixel of an RGBX buffer (8 bits per channel, top row first).
    mutating func add(rgbx pixels: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int, step: Int = 1) {
        let step = max(1, step)
        for y in 0..<height {
            let row = pixels + y * bytesPerRow
            var x = (y * 7) % step
            while x < width {
                let pixel = row + x * 4
                let r = Int(pixel[0]), g = Int(pixel[1]), b = Int(pixel[2])
                let bin = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                counts[bin] &+= 1
                sums[bin * 3] &+= UInt64(r)
                sums[bin * 3 + 1] &+= UInt64(g)
                sums[bin * 3 + 2] &+= UInt64(b)
                sampleCount += 1
                x += step
            }
        }
    }

    func build(maximumColors: Int = GIFPalette.maximumColors) -> GIFPalette {
        struct Bin { var r: Int; var g: Int; var b: Int; var count: Int; var sr: UInt64; var sg: UInt64; var sb: UInt64 }
        var bins: [Bin] = []
        for bin in 0..<Self.binCount where counts[bin] > 0 {
            bins.append(Bin(r: bin >> 10, g: (bin >> 5) & 31, b: bin & 31, count: Int(counts[bin]),
                            sr: sums[bin * 3], sg: sums[bin * 3 + 1], sb: sums[bin * 3 + 2]))
        }
        guard !bins.isEmpty else { return GIFPalette(rgb: [0, 0, 0]) }

        // Boxes are index ranges into `bins`. Split the box with the widest populated
        // channel at its weighted median until the palette is full.
        var boxes: [Range<Int>] = [0..<bins.count]
        func extent(_ box: Range<Int>) -> (channel: Int, range: Int) {
            var low = [31, 31, 31], high = [0, 0, 0]
            for bin in bins[box] {
                low[0] = min(low[0], bin.r); high[0] = max(high[0], bin.r)
                low[1] = min(low[1], bin.g); high[1] = max(high[1], bin.g)
                low[2] = min(low[2], bin.b); high[2] = max(high[2], bin.b)
            }
            let ranges = [high[0] - low[0], high[1] - low[1], high[2] - low[2]]
            let channel = ranges.indices.max { ranges[$0] < ranges[$1] } ?? 0
            return (channel, ranges[channel])
        }
        while boxes.count < maximumColors {
            var best: (index: Int, channel: Int, score: Int)?
            for (index, box) in boxes.enumerated() where box.count > 1 {
                let (channel, range) = extent(box)
                guard range > 0 else { continue }
                let population = bins[box].reduce(0) { $0 + $1.count }
                let score = range * Int(Double(population).squareRoot().rounded(.up))
                if best == nil || score > best!.score { best = (index, channel, score) }
            }
            guard let best else { break }
            let box = boxes[best.index]
            let key: (Bin) -> Int = best.channel == 0 ? { $0.r } : best.channel == 1 ? { $0.g } : { $0.b }
            bins[box].sort { key($0) < key($1) }
            let total = bins[box].reduce(0) { $0 + $1.count }
            var running = 0
            var split = box.lowerBound + 1
            for index in box {
                running += bins[index].count
                if running * 2 >= total { split = min(max(index + 1, box.lowerBound + 1), box.upperBound - 1); break }
            }
            boxes[best.index] = box.lowerBound..<split
            boxes.append(split..<box.upperBound)
        }

        var rgb: [UInt8] = []
        rgb.reserveCapacity(boxes.count * 3)
        for box in boxes {
            var count: UInt64 = 0, r: UInt64 = 0, g: UInt64 = 0, b: UInt64 = 0
            for bin in bins[box] { count += UInt64(bin.count); r += bin.sr; g += bin.sg; b += bin.sb }
            let half = count / 2
            rgb += [UInt8((r + half) / count), UInt8((g + half) / count), UInt8((b + half) / count)]
        }
        return GIFPalette(rgb: rgb)
    }
}

/// Maps 8-bit RGB to the nearest palette entry, remembering answers at 6 bits per channel.
final class GIFColorMapper: @unchecked Sendable {
    let palette: GIFPalette
    private var cache = [UInt16](repeating: .max, count: 1 << 18)

    init(palette: GIFPalette) { self.palette = palette }

    func index(red: UInt8, green: UInt8, blue: UInt8) -> UInt8 {
        let key = Int(red >> 2) << 12 | Int(green >> 2) << 6 | Int(blue >> 2)
        let cached = cache[key]
        if cached != .max { return UInt8(cached) }
        var best = 0
        var bestDistance = Int.max
        let r = Int(red), g = Int(green), b = Int(blue)
        palette.rgb.withUnsafeBufferPointer { colors in
            for entry in 0..<palette.count {
                let dr = Int(colors[entry * 3]) - r
                let dg = Int(colors[entry * 3 + 1]) - g
                let db = Int(colors[entry * 3 + 2]) - b
                let distance = 3 * dr * dr + 4 * dg * dg + 2 * db * db
                if distance < bestDistance {
                    bestDistance = distance
                    best = entry
                    if distance == 0 { break }
                }
            }
        }
        cache[key] = UInt16(best)
        return UInt8(best)
    }

    /// Converts an RGBX buffer (top row first) to palette indices.
    func indices(rgbx pixels: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: width * height)
        output.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                let row = pixels + y * bytesPerRow
                for x in 0..<width {
                    let pixel = row + x * 4
                    out[y * width + x] = index(red: pixel[0], green: pixel[1], blue: pixel[2])
                }
            }
        }
        return output
    }
}

/// Writes an animated GIF89a. Each frame after the first carries only the rectangle that
/// changed, with unchanged pixels inside it left transparent, so a mostly still screen
/// recording costs little more than its first frame. A frame identical to the one before
/// it is not written at all; the earlier frame is simply shown for longer.
final class GIFAnimationWriter {
    let width: Int
    let height: Int
    private let palette: GIFPalette
    private var data = Data()
    /// The palette indices on screen after the frames written so far.
    private(set) var canvas: [UInt8]?
    private var pending: (x: Int, y: Int, width: Int, height: Int, pixels: [UInt8], start: Int)?
    private(set) var writtenFrames = 0

    init(width: Int, height: Int, palette: GIFPalette) {
        precondition(width > 0 && height > 0 && width <= 65_535 && height <= 65_535)
        self.width = width
        self.height = height
        self.palette = palette
        data.append(contentsOf: Array("GIF89a".utf8))
        appendShort(width)
        appendShort(height)
        // Global colour table of 256 entries (size code 7), 8 bits of colour resolution.
        data.append(0b1111_0111)
        data.append(0) // background colour index
        data.append(0) // no aspect ratio
        var table = palette.rgb
        table += [UInt8](repeating: 0, count: 256 * 3 - table.count)
        data.append(contentsOf: table)
        // Loop forever.
        data.append(contentsOf: [0x21, 0xFF, 0x0B])
        data.append(contentsOf: Array("NETSCAPE2.0".utf8))
        data.append(contentsOf: [0x03, 0x01, 0x00, 0x00, 0x00])
    }

    /// Adds a full-canvas frame of palette indices shown from `start` centiseconds.
    func addFrame(_ indices: [UInt8], start: Int) {
        precondition(indices.count == width * height)
        guard let previous = canvas else {
            canvas = indices
            pending = (0, 0, width, height, indices, start)
            return
        }
        var minX = width, minY = height, maxX = -1, maxY = -1
        indices.withUnsafeBufferPointer { new in
            previous.withUnsafeBufferPointer { old in
                for y in 0..<height {
                    let row = y * width
                    var x = 0
                    while x < width {
                        if new[row + x] != old[row + x] {
                            if x < minX { minX = x }
                            if x > maxX { maxX = x }
                            if y < minY { minY = y }
                            maxY = y
                        }
                        x += 1
                    }
                }
            }
        }
        guard maxX >= 0 else { return } // Nothing changed: the pending frame stays up longer.
        let rectWidth = maxX - minX + 1
        let rectHeight = maxY - minY + 1
        var pixels = [UInt8](repeating: GIFPalette.transparentIndex, count: rectWidth * rectHeight)
        var updated = previous
        for y in 0..<rectHeight {
            for x in 0..<rectWidth {
                let source = (minY + y) * width + minX + x
                let value = indices[source]
                if value != previous[source] {
                    pixels[y * rectWidth + x] = value
                    updated[source] = value
                }
            }
        }
        flush(until: start)
        canvas = updated
        pending = (minX, minY, rectWidth, rectHeight, pixels, start)
    }

    /// Writes the last frame, shown until `end` centiseconds, and returns the file.
    func finish(end: Int) -> Data {
        flush(until: end)
        data.append(0x3B)
        return data
    }

    private func flush(until time: Int) {
        guard let frame = pending else { return }
        pending = nil
        let delay = min(65_535, max(1, time - frame.start))
        // Graphic control: leave the frame in place, index 255 is transparent.
        data.append(contentsOf: [0x21, 0xF9, 0x04, 0b0000_0101])
        appendShort(delay)
        data.append(GIFPalette.transparentIndex)
        data.append(0)
        data.append(0x2C)
        appendShort(frame.x)
        appendShort(frame.y)
        appendShort(frame.width)
        appendShort(frame.height)
        data.append(0) // no local colour table, not interlaced
        data.append(8) // LZW minimum code size
        let compressed = frame.pixels.withUnsafeBufferPointer { gifLZWCompress($0) }
        var offset = 0
        while offset < compressed.count {
            let length = min(255, compressed.count - offset)
            data.append(UInt8(length))
            data.append(contentsOf: compressed[offset..<offset + length])
            offset += length
        }
        data.append(0)
        writtenFrames += 1
    }

    private func appendShort(_ value: Int) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }
}

/// Video decoding leaves faint noise on a still screen. A pixel whose new colour is within
/// `tolerance` of the colour already shown keeps the shown index, so it isn't redrawn.
func gifKeepUnchangedPixels(_ indices: inout [UInt8], shown: [UInt8], rgbx pixels: UnsafePointer<UInt8>,
                            width: Int, height: Int, bytesPerRow: Int, palette: GIFPalette, tolerance: Int = 10) {
    precondition(indices.count == width * height && shown.count == indices.count)
    palette.rgb.withUnsafeBufferPointer { colors in
        indices.withUnsafeMutableBufferPointer { indices in
            shown.withUnsafeBufferPointer { shown in
                for y in 0..<height {
                    let row = pixels + y * bytesPerRow
                    for x in 0..<width {
                        let offset = y * width + x
                        let current = Int(shown[offset])
                        guard indices[offset] != shown[offset], current < palette.count else { continue }
                        let pixel = row + x * 4
                        if abs(Int(pixel[0]) - Int(colors[current * 3])) <= tolerance,
                           abs(Int(pixel[1]) - Int(colors[current * 3 + 1])) <= tolerance,
                           abs(Int(pixel[2]) - Int(colors[current * 3 + 2])) <= tolerance {
                            indices[offset] = shown[offset]
                        }
                    }
                }
            }
        }
    }
}

/// GIF's variable-width LZW for 8-bit indices (minimum code size 8, codes up to 12 bits).
func gifLZWCompress(_ pixels: UnsafeBufferPointer<UInt8>) -> [UInt8] {
    let clearCode = 256
    let endCode = 257
    let maximumCode = 4096
    let hashSize = 5003
    var hashKeys = [Int32](repeating: -1, count: hashSize)
    var hashCodes = [Int16](repeating: 0, count: hashSize)
    var output: [UInt8] = []
    output.reserveCapacity(pixels.count / 2 + 16)
    var bitBuffer: UInt32 = 0
    var bitCount = 0
    var codeSize = 9
    var maxCodeForSize = (1 << codeSize) - 1
    var nextCode = endCode + 1
    var clearPending = false

    func write(_ code: Int) {
        bitBuffer |= UInt32(code) << UInt32(bitCount)
        bitCount += codeSize
        while bitCount >= 8 {
            output.append(UInt8(bitBuffer & 0xFF))
            bitBuffer >>= 8
            bitCount -= 8
        }
        // The decoder widens its codes one entry late; this matches it.
        if clearPending {
            codeSize = 9
            maxCodeForSize = (1 << codeSize) - 1
            clearPending = false
        } else if nextCode > maxCodeForSize {
            codeSize += 1
            maxCodeForSize = codeSize == 12 ? maximumCode : (1 << codeSize) - 1
        }
    }

    write(clearCode)
    guard !pixels.isEmpty else {
        write(endCode)
        if bitCount > 0 { output.append(UInt8(bitBuffer & 0xFF)) }
        return output
    }
    var prefix = Int(pixels[0])
    var position = 1
    while position < pixels.count {
        let byte = Int(pixels[position])
        position += 1
        let key = Int32(byte << 12 | prefix)
        var slot = (byte << 4 ^ prefix) % hashSize
        var found = false
        if hashKeys[slot] == key {
            prefix = Int(hashCodes[slot]); found = true
        } else if hashKeys[slot] >= 0 {
            let step = slot == 0 ? 1 : hashSize - slot
            repeat {
                slot -= step
                if slot < 0 { slot += hashSize }
                if hashKeys[slot] == key { prefix = Int(hashCodes[slot]); found = true; break }
            } while hashKeys[slot] >= 0
        }
        if found { continue }
        write(prefix)
        prefix = byte
        if nextCode < maximumCode {
            hashKeys[slot] = key
            hashCodes[slot] = Int16(nextCode)
            nextCode += 1
        } else {
            for index in 0..<hashSize { hashKeys[index] = -1 }
            nextCode = endCode + 1
            clearPending = true
            write(clearCode)
        }
    }
    write(prefix)
    write(endCode)
    if bitCount > 0 { output.append(UInt8(bitBuffer & 0xFF)) }
    return output
}
