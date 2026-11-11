import Foundation
import AppKit
import ApplicationServices

@MainActor
final class FinderIconTracker {
    var isEnabled: Bool = false {
        didSet {
            if oldValue != isEnabled {
                updateMonitors()
            }
        }
    }

    var includeDesktopWidgets: Bool = true
    var onObstaclesUpdated: (([IconObstacle], Bool) -> Void)?
    var onDesktopClickRipple: ((CGPoint) -> Void)?
    var onDragStateChanged: ((Bool) -> Void)?
    var onRequestDSStoreResync: (() -> Void)?

    private var globalMouseMonitor: Any?
    private var isMouseDraggingOnDesktop: Bool = false
    private var dragAnchorPoint: CGPoint = .zero
    private var draggedObstacleIndex: Int?
    private var draggedOriginalObstacle: IconObstacle?
    private var trackedIconObstacles: [IconObstacle] = []
    private var cachedWidgetObstacles: [IconObstacle] = []
    private var lastDragPollTime: CFAbsoluteTime = 0

    isolated deinit {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func updateMonitors() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        guard isEnabled else {
            if isMouseDraggingOnDesktop {
                isMouseDraggingOnDesktop = false
                onDragStateChanged?(false)
            }
            return
        }

        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleGlobalMouseEvent(event)
            }
        }
    }

    private var widgetObstacles: [IconObstacle] {
        includeDesktopWidgets ? cachedWidgetObstacles : []
    }

    private func handleGlobalMouseEvent(_ event: NSEvent) {
        guard isEnabled, let screen = NSScreen.primaryDesktop else { return }
        let mouseCocoa = NSEvent.mouseLocation
        guard screen.frame.contains(mouseCocoa) else { return }

        let topLeftPt = CGPoint(
            x: mouseCocoa.x - screen.frame.minX,
            y: screen.frame.maxY - mouseCocoa.y
        )

        switch event.type {
        case .leftMouseDown:
            if isPointExposedOnDesktop(topLeftPt, screen: screen) {
                isMouseDraggingOnDesktop = true
                dragAnchorPoint = topLeftPt
                if includeDesktopWidgets {
                    cachedWidgetObstacles = queryDesktopWidgetObstacles(screen: screen)
                }
                draggedObstacleIndex = hitTestTrackedObstacle(at: topLeftPt)
                draggedOriginalObstacle = draggedObstacleIndex.map { trackedIconObstacles[$0] }
                onDesktopClickRipple?(topLeftPt)
            } else {
                isMouseDraggingOnDesktop = false
                draggedObstacleIndex = nil
                draggedOriginalObstacle = nil
            }

        case .leftMouseDragged:
            guard isMouseDraggingOnDesktop else { return }
            let dx = Float(topLeftPt.x - dragAnchorPoint.x)
            let dy = Float(topLeftPt.y - dragAnchorPoint.y)
            guard hypot(dx, dy) >= 3.0 else { return }

            onDragStateChanged?(true)
            let now = CFAbsoluteTimeGetCurrent()
            if AXIsProcessTrusted() && (now - lastDragPollTime) >= (1.0 / 30.0) {
                lastDragPollTime = now
                if let liveObs = queryAXFinderDesktopIcons(screen: screen), !liveObs.isEmpty {
                    trackedIconObstacles = liveObs
                    let combined = liveObs + widgetObstacles
                    onObstaclesUpdated?(combined, true)
                    return
                }
            }
            if let idx = draggedObstacleIndex,
               let orig = draggedOriginalObstacle,
               idx < trackedIconObstacles.count {
                trackedIconObstacles[idx] = IconObstacle(
                    x: orig.x + dx,
                    y: orig.y + dy,
                    w: orig.w,
                    h: orig.h
                )
                let combined = trackedIconObstacles + widgetObstacles
                onObstaclesUpdated?(combined, true)
            }

        case .leftMouseUp:
            if isMouseDraggingOnDesktop {
                isMouseDraggingOnDesktop = false
                let didDragIcon = (draggedObstacleIndex != nil) &&
                    hypot(topLeftPt.x - dragAnchorPoint.x, topLeftPt.y - dragAnchorPoint.y) >= 4.0
                draggedObstacleIndex = nil
                draggedOriginalObstacle = nil
                onDragStateChanged?(false)

                if didDragIcon {
                    let combined = trackedIconObstacles + widgetObstacles
                    onObstaclesUpdated?(combined, false)
                    for delay in [0.25, 1.5, 4.5] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            self?.onRequestDSStoreResync?()
                        }
                    }
                }
            }

        default:
            break
        }
    }

    private func hitTestTrackedObstacle(at point: CGPoint) -> Int? {
        for (i, ob) in trackedIconObstacles.enumerated().reversed() {
            let r = CGRect(x: CGFloat(ob.x), y: CGFloat(ob.y), width: CGFloat(ob.w), height: CGFloat(ob.h))
                .insetBy(dx: -6, dy: -6)
            if r.contains(point) {
                return i
            }
        }
        return nil
    }

    func refreshObstacles(fallbackRects: [CGRect]?) {
        guard let screen = NSScreen.primaryDesktop else { return }
        var icons: [IconObstacle] = []

        if AXIsProcessTrusted(), let axObs = queryAXFinderDesktopIcons(screen: screen), !axObs.isEmpty {
            icons = axObs
        } else if let fallbackRects {
            icons = fallbackRects.map { IconObstacle(rect: $0) }
        } else {
            icons = trackedIconObstacles
        }

        if !icons.isEmpty || fallbackRects != nil {
            trackedIconObstacles = icons
        }

        cachedWidgetObstacles = includeDesktopWidgets ? queryDesktopWidgetObstacles(screen: screen) : []
        let combined = trackedIconObstacles + cachedWidgetObstacles

        if !combined.isEmpty || fallbackRects != nil {
            onObstaclesUpdated?(combined, false)
        }
    }

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    static func promptForAccessibilityIfNeeded() {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private func queryAXFinderDesktopIcons(screen: NSScreen) -> [IconObstacle]? {
        guard let finderApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return nil
        }
        let appElem = AXUIElementCreateApplication(finderApp.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        let screenOrigin = screen.frame.origin
        for win in windows {
            if let icons = extractIconRects(from: win, screenOrigin: screenOrigin), !icons.isEmpty {
                return icons
            }
        }
        return nil
    }

    private func extractIconRects(from element: AXUIElement, screenOrigin: CGPoint, depth: Int = 0) -> [IconObstacle]? {
        guard depth < 5 else { return nil }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = (roleRef as? String) ?? ""

        if depth == 0 {
            var subroleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
            let subrole = (subroleRef as? String) ?? ""
            if subrole == "AXStandardWindow" || subrole == "AXDialog" || subrole == "AXSystemDialog" {
                return nil
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement], !children.isEmpty else {
            return nil
        }

        if role == "AXGroup" || role == "AXScrollArea" {
            var obstacles: [IconObstacle] = []
            for child in children {
                var posRef: CFTypeRef?
                var sizeRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef) == .success,
                   AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef) == .success,
                   let posVal = posRef, let sizeVal = sizeRef,
                   CFGetTypeID(posVal) == AXValueGetTypeID(),
                   CFGetTypeID(sizeVal) == AXValueGetTypeID() {
                    var pt = CGPoint.zero
                    var sz = CGSize.zero
                    AXValueGetValue(posVal as! AXValue, .cgPoint, &pt)
                    AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz)
                    if sz.width > 16 && sz.width < 320 && sz.height > 16 && sz.height < 320 {
                        obstacles.append(IconObstacle(
                            x: Float(pt.x - screenOrigin.x),
                            y: Float(pt.y),
                            w: Float(sz.width),
                            h: Float(sz.height)
                        ))
                    }
                }
            }
            if !obstacles.isEmpty {
                return obstacles
            }
        }

        for child in children {
            if let nested = extractIconRects(from: child, screenOrigin: screenOrigin, depth: depth + 1),
               !nested.isEmpty {
                return nested
            }
        }
        return nil
    }

    // Caller must omit .excludeDesktopElements or Notification Center widget windows are stripped.
    static func extractDesktopWidgetRects(from infoList: [[String: Any]], screen: NSScreen) -> [CGRect] {
        let iconLayer = Int(CGWindowLevelForKey(.desktopIconWindow))
        let primaryH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let screenGlobal = CGRect(
            x: screen.frame.minX,
            y: primaryH - screen.frame.maxY,
            width: screen.frame.width,
            height: screen.frame.height
        )

        var rects: [CGRect] = []
        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer > iconLayer && layer < 0,
                  let owner = info[kCGWindowOwnerName as String] as? String,
                  owner.contains("Notification") || owner.contains("Widget") || owner.contains("Chrono"),
                  let alpha = info[kCGWindowAlpha as String] as? Double,
                  alpha > 0.1,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict),
                  rect.width > 40, rect.height > 40,
                  rect.width < screen.frame.width * 0.9,
                  rect.intersects(screenGlobal) else {
                continue
            }
            rects.append(CGRect(
                x: rect.minX - screenGlobal.minX,
                y: rect.minY - screenGlobal.minY,
                width: rect.width,
                height: rect.height
            ))
        }
        return rects
    }

    static func queryDesktopWidgetRects(screen: NSScreen) -> [CGRect] {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return extractDesktopWidgetRects(from: infoList, screen: screen)
    }

    static func widgetObstacles(from widgetRects: [CGRect]) -> [IconObstacle] {
        widgetRects.map { rect in
            let card = rect.width > 64 && rect.height > 64 ? rect.insetBy(dx: 8, dy: 8) : rect
            return IconObstacle(rect: card)
        }
    }

    func queryDesktopWidgetObstacles(screen: NSScreen) -> [IconObstacle] {
        Self.widgetObstacles(from: Self.queryDesktopWidgetRects(screen: screen))
    }

    private func isPointExposedOnDesktop(_ topLeftPt: CGPoint, screen: NSScreen) -> Bool {
        let primaryH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let globalTopY = (primaryH - screen.frame.maxY) + topLeftPt.y
        let globalPt = CGPoint(x: topLeftPt.x + screen.frame.minX, y: globalTopY)
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return true
        }
        let normalLayer = Int(CGWindowLevelForKey(.normalWindow))
        let myPID = ProcessInfo.processInfo.processIdentifier
        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == normalLayer,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid != myPID,
                  let isOnscreen = info[kCGWindowIsOnscreen as String] as? Bool,
                  isOnscreen,
                  let storeType = info[kCGWindowStoreType as String] as? Int,
                  storeType != 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0.15,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }
            if let owner = info[kCGWindowOwnerName as String] as? String,
               DesktopWindowController.ignoredCoverageOwners.contains(owner) {
                continue
            }
            if rect.contains(globalPt) {
                return false
            }
        }
        return true
    }
}
