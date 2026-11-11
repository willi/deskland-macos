import Foundation
import AppKit

struct DesktopItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case file
        case folder
        case application
        case volume
        case alias
        case iCloudPlaceholder(realURL: URL)
    }

    let id: String
    var url: URL
    var displayName: String
    var kind: Kind
    var isICloudItem: Bool
    var isDownloaded: Bool
    var frame: CGRect
    var icon: NSImage

    var openableURL: URL {
        if case .iCloudPlaceholder(let real) = kind { return real }
        return url
    }

    var isICloudPlaceholder: Bool {
        if case .iCloudPlaceholder = kind { return true }
        return false
    }

    static func == (lhs: DesktopItem, rhs: DesktopItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.displayName == rhs.displayName &&
        lhs.kind == rhs.kind &&
        lhs.isDownloaded == rhs.isDownloaded &&
        lhs.frame == rhs.frame
    }
}

struct IconObstacle: Equatable, Sendable {
    var x: Float
    var y: Float
    var w: Float
    var h: Float

    var cx: Float { x + w * 0.5 }
    var cy: Float { y + h * 0.5 }
    var hw: Float { max(8, w * 0.5 - 4) }
    var hh: Float { max(8, h * 0.5 - 2) }

    init(rect: CGRect) {
        self.x = Float(rect.origin.x)
        self.y = Float(rect.origin.y)
        self.w = Float(rect.size.width)
        self.h = Float(rect.size.height)
    }

    init(x: Float, y: Float, w: Float, h: Float) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}
