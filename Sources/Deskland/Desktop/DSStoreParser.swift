import Foundation
import CoreGraphics

enum DSStoreParser {
    struct ParsedLocations {
        let centers: [String: CGPoint]
        let includesMenuBarOffset: Bool
    }

    static func parseDesktopLocations(at dsStoreURL: URL, screenSize: CGSize) -> ParsedLocations {
        guard let data = try? Data(contentsOf: dsStoreURL, options: [.mappedIfSafe]),
              data.count > 36 else {
            return ParsedLocations(centers: [:], includesMenuBarOffset: true)
        }

        let dilcMarker = Array("dilcblob".utf8)
        let ilocMarker = Array("Ilocblob".utf8)
        var dilcResult: [String: CGPoint] = [:]
        var ilocResult: [String: CGPoint] = [:]

        data.withUnsafeBytes { raw in
            guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = data.count
            var idx = 4

            while idx + 28 <= count {
                let b0 = bytes[idx]
                // dilcblob offsets +28/+32 store X/Y in 1/100_000 of screen size
                if b0 == 0x64, idx + 44 <= count,
                   bytes[idx + 1] == dilcMarker[1],
                   bytes[idx + 2] == dilcMarker[2],
                   bytes[idx + 3] == dilcMarker[3],
                   bytes[idx + 4] == dilcMarker[4],
                   bytes[idx + 5] == dilcMarker[5],
                   bytes[idx + 6] == dilcMarker[6],
                   bytes[idx + 7] == dilcMarker[7] {
                    let blobLen = readUInt32BE(bytes, idx + 8)
                    if blobLen == 32 {
                        let rawFX = Int32(bitPattern: readUInt32BE(bytes, idx + 28))
                        let rawFY = Int32(bitPattern: readUInt32BE(bytes, idx + 32))
                        if rawFX >= 0 && rawFX <= 105_000 && rawFY >= 0 && rawFY <= 105_000,
                           let filename = extractPrecedingUTF16Filename(bytes: bytes, markerIndex: idx) {
                            let cx = (CGFloat(rawFX) / 100_000.0) * screenSize.width
                            let cy = (CGFloat(rawFY) / 100_000.0) * screenSize.height
                            dilcResult[filename] = CGPoint(x: cx, y: cy)
                        }
                        idx += 44
                        continue
                    }
                }

                if b0 == 0x49,
                   bytes[idx + 1] == ilocMarker[1],
                   bytes[idx + 2] == ilocMarker[2],
                   bytes[idx + 3] == ilocMarker[3],
                   bytes[idx + 4] == ilocMarker[4],
                   bytes[idx + 5] == ilocMarker[5],
                   bytes[idx + 6] == ilocMarker[6],
                   bytes[idx + 7] == ilocMarker[7] {
                    let blobLen = readUInt32BE(bytes, idx + 8)
                    if blobLen == 16 {
                        let x = readUInt32BE(bytes, idx + 12)
                        let y = readUInt32BE(bytes, idx + 16)
                        if x < 16_384 && y < 16_384,
                           let filename = extractPrecedingUTF16Filename(bytes: bytes, markerIndex: idx) {
                            ilocResult[filename] = CGPoint(x: CGFloat(x), y: CGFloat(y))
                        }
                        idx += 28
                        continue
                    }
                }
                idx += 1
            }
        }

        if !dilcResult.isEmpty {
            return ParsedLocations(centers: dilcResult, includesMenuBarOffset: true)
        }
        return ParsedLocations(centers: ilocResult, includesMenuBarOffset: false)
    }

    @inline(__always)
    private static func readUInt32BE(_ ptr: UnsafePointer<UInt8>, _ offset: Int) -> UInt32 {
        (UInt32(ptr[offset]) << 24) |
        (UInt32(ptr[offset + 1]) << 16) |
        (UInt32(ptr[offset + 2]) << 8) |
        UInt32(ptr[offset + 3])
    }

    private static func extractPrecedingUTF16Filename(bytes: UnsafePointer<UInt8>, markerIndex: Int) -> String? {
        // Record header before blob marker: [charLen: UInt32 BE][UTF-16BE filename]
        let maxChars = min(255, (markerIndex - 4) / 2)
        guard maxChars >= 1 else { return nil }

        for charLen in 1...maxChars {
            let lenOffset = markerIndex - charLen * 2 - 4
            if lenOffset < 0 { break }
            let declaredLen = Int(readUInt32BE(bytes, lenOffset))
            if declaredLen == charLen {
                var utf16 = [UInt16]()
                utf16.reserveCapacity(charLen)
                var valid = true
                let strStart = lenOffset + 4
                for c in 0..<charLen {
                    let u = (UInt16(bytes[strStart + c * 2]) << 8) | UInt16(bytes[strStart + c * 2 + 1])
                    if u < 0x20 || u == 0x2F {
                        valid = false
                        break
                    }
                    utf16.append(u)
                }
                if valid {
                    return String(utf16CodeUnits: utf16, count: utf16.count)
                }
            }
        }
        return nil
    }
}

enum DesktopGridMetrics {
    static let cellW: CGFloat = 92
    static let cellH: CGFloat = 98
    static let iconBoxW: CGFloat = 84
    static let iconBoxH: CGFloat = 90
    static let marginRight: CGFloat = 18
    static let marginTop: CGFloat = 16
    static let marginBottom: CGFloat = 16
    static let marginLeft: CGFloat = 18

    static func workAreaTopLeft(screenFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        let topInset = max(24, screenFrame.maxY - visibleFrame.maxY)
        let leftInset = max(0, visibleFrame.minX - screenFrame.minX)
        return CGRect(
            x: leftInset,
            y: topInset,
            width: visibleFrame.width,
            height: visibleFrame.height
        )
    }

    static func slotRect(colFromRight: Int, rowFromTop: Int, workArea: CGRect) -> CGRect {
        let x = workArea.maxX - marginRight - iconBoxW - CGFloat(colFromRight) * cellW
        let y = workArea.minY + marginTop + CGFloat(rowFromTop) * cellH
        return CGRect(x: round(x), y: round(y), width: iconBoxW, height: iconBoxH)
    }

    static func snapToNearestFreeSlot(
        proposedOrigin: CGPoint,
        occupiedRects: [CGRect],
        workArea: CGRect
    ) -> CGRect {
        let maxRows = max(1, Int(floor((workArea.height - marginTop - marginBottom) / cellH)))
        let maxCols = max(1, Int(floor((workArea.width - marginLeft - marginRight) / cellW)))

        var bestRect = CGRect(x: proposedOrigin.x, y: proposedOrigin.y, width: iconBoxW, height: iconBoxH)
        var bestDist: CGFloat = .greatestFiniteMagnitude

        for c in 0..<maxCols {
            for r in 0..<maxRows {
                let cand = slotRect(colFromRight: c, rowFromTop: r, workArea: workArea)
                let taken = occupiedRects.contains {
                    abs($0.midX - cand.midX) < cellW * 0.45 && abs($0.midY - cand.midY) < cellH * 0.45
                }
                if taken { continue }
                let d = hypot(cand.origin.x - proposedOrigin.x, cand.origin.y - proposedOrigin.y)
                if d < bestDist {
                    bestDist = d
                    bestRect = cand
                }
            }
        }
        return bestRect
    }
}
