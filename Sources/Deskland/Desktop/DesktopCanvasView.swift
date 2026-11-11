import AppKit
import QuartzCore
@preconcurrency import QuickLookUI
import UniformTypeIdentifiers

@MainActor
final class DesktopCanvasView: NSView,
    NSDraggingSource,
    NSTextFieldDelegate,
    @preconcurrency QLPreviewPanelDataSource,
    QLPreviewPanelDelegate
{
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var itemStore: [DesktopItem] = []

    var items: [DesktopItem] {
        get { itemStore }
        set {
            let oldIDs = Set(itemStore.map(\.id))
            itemStore = newValue
            if case .draggingItems(_, let initialFrames, _) = interaction {
                applyDragOffset(liveDragOffset, initialFrames: initialFrames)
            }
            let newIDs = Set(newValue.map(\.id))
            if newIDs != oldIDs {
                selectedIDs.formIntersection(newIDs)
                if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible {
                    QLPreviewPanel.shared().reloadData()
                }
            }
            needsDisplay = true
        }
    }

    var snapToGrid: Bool = false
    var currentTimeOfDay: TimeOfDayMode = .dynamic
    var currentThemeID: String = "beach"
    var availableThemes: [(id: String, name: String)] = []
    var activeDesktopURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")

    var onLiveDragObstacles: (([IconObstacle], Bool) -> Void)?
    var onCommitItemFrames: (([String: CGRect]) -> Void)?
    var onDesktopRipple: ((CGPoint, Float) -> Void)?
    var onRequestReload: (() -> Void)?
    var onCleanUp: ((DesktopSortOrder) -> Void)?
    var onToggleSnapToGrid: (() -> Void)?
    var onRefreshScenery: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenAbout: (() -> Void)?
    var onSwitchToFinderMode: (() -> Void)?
    var onSelectTimeOfDay: ((TimeOfDayMode) -> Void)?
    var onSelectTheme: ((String) -> Void)?

    private(set) var selectedIDs: Set<String> = []

    private enum InteractionState {
        case idle
        case pendingItemClick(anchorPoint: CGPoint, clickedID: String, initialFrames: [String: CGRect])
        case draggingItems(anchorPoint: CGPoint, initialFrames: [String: CGRect], dropTargetID: String?)
        case marquee(anchorPoint: CGPoint, currentPoint: CGPoint, baseSelection: Set<String>)
    }
    private var interaction: InteractionState = .idle

    var isCurrentlyDraggingItems: Bool {
        if case .draggingItems = interaction { return true }
        return false
    }
    private var liveDragOffset: CGVector = .zero
    private var foreignWindowRectsCache: [CGRect]?
    private var lastContextClickPoint: CGPoint?

    private var renameField: NSTextField?
    private var renamingItemID: String?

    private static let itemDrawOutset: CGFloat = 24

    private static let labelFont = NSFont.systemFont(ofSize: 11.5, weight: .medium)
    private static let labelParagraph: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        paragraph.maximumLineHeight = 14
        paragraph.minimumLineHeight = 14
        return paragraph
    }()
    private static let labelAttributes: [NSAttributedString.Key: Any] = {
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2.6
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.82)
        return [.font: labelFont, .foregroundColor: NSColor.white, .paragraphStyle: labelParagraph, .shadow: shadow]
    }()
    private static let selectedLabelAttributes: [NSAttributedString.Key: Any] = [
        .font: labelFont, .foregroundColor: NSColor.white, .paragraphStyle: labelParagraph
    ]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let dropTargetID: String? = {
            if case .draggingItems(_, _, let target) = interaction { return target }
            return nil
        }()

        for item in itemStore where needsToDraw(item.frame.insetBy(dx: -Self.itemDrawOutset, dy: -Self.itemDrawOutset)) {
            drawDesktopItem(item, in: ctx, isSelected: selectedIDs.contains(item.id), isDropTarget: dropTargetID == item.id)
        }

        if case .marquee(let a, let b, _) = interaction {
            let rect = Self.marqueeRect(a, b)
            ctx.saveGState()
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.16).cgColor)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.62).cgColor)
            ctx.setLineWidth(1.0)
            ctx.fill(rect)
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            ctx.restoreGState()
        }
    }

    private func drawDesktopItem(_ item: DesktopItem, in ctx: CGContext, isSelected: Bool, isDropTarget: Bool) {
        let cell = item.frame
        let iconSize: CGFloat = 54
        let iconRect = CGRect(
            x: round(cell.midX - iconSize * 0.5),
            y: round(cell.minY + 4),
            width: iconSize,
            height: iconSize
        )

        if isSelected || isDropTarget {
            ctx.saveGState()
            let halo = iconRect.insetBy(dx: -5, dy: -4)
            let path = CGPath(roundedRect: halo, cornerWidth: 9, cornerHeight: 9, transform: nil)
            if isDropTarget {
                ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.38).cgColor)
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
                ctx.setLineWidth(1.5)
                ctx.addPath(path)
                ctx.drawPath(using: .fillStroke)
            } else {
                ctx.setFillColor(NSColor.black.withAlphaComponent(0.28).cgColor)
                ctx.addPath(path)
                ctx.fillPath()
            }
            ctx.restoreGState()
        }

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 1.5), blur: 4.0, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        let alpha: CGFloat = item.isDownloaded ? 1.0 : 0.78
        item.icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
        ctx.restoreGState()

        if item.isICloudItem && !item.isDownloaded {
            let badgeRect = CGRect(x: iconRect.maxX - 16, y: iconRect.maxY - 16, width: 16, height: 16)
            ctx.saveGState()
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.fillEllipse(in: badgeRect)
            if let sym = NSImage(systemSymbolName: "icloud.and.arrow.down", accessibilityDescription: nil) {
                let cfg = NSImage.SymbolConfiguration(pointSize: 9.5, weight: .semibold)
                let tinted = sym.withSymbolConfiguration(cfg) ?? sym
                tinted.draw(in: badgeRect.insetBy(dx: 2.5, dy: 2.5), from: .zero, operation: .sourceOver, fraction: 0.95, respectFlipped: true, hints: nil)
            }
            ctx.restoreGState()
        }

        if renamingItemID == item.id { return }

        let maxLabelW = cell.width + 10
        let textBounds = CGRect(x: cell.midX - maxLabelW * 0.5, y: iconRect.maxY + 4, width: maxLabelW, height: 29)

        let attrStr = NSAttributedString(
            string: item.displayName,
            attributes: isSelected ? Self.selectedLabelAttributes : Self.labelAttributes
        )
        let measured = attrStr.boundingRect(
            with: NSSize(width: maxLabelW - 8, height: 28),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        if isSelected {
            let pillW = min(maxLabelW, ceil(measured.width) + 10)
            let pillH = min(29, max(16, ceil(measured.height) + 3))
            let pillRect = CGRect(
                x: round(cell.midX - pillW * 0.5),
                y: round(textBounds.minY),
                width: pillW,
                height: pillH
            )
            ctx.saveGState()
            ctx.setFillColor(NSColor.controlAccentColor.cgColor)
            ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: 4.5, cornerHeight: 4.5, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }

        let drawRect = CGRect(
            x: textBounds.minX + 4,
            y: textBounds.minY + 1.5,
            width: textBounds.width - 8,
            height: min(28, ceil(measured.height) + 2)
        )
        attrStr.draw(with: drawRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private static func marqueeRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func invalidateItemArea(_ frame: CGRect) {
        setNeedsDisplay(frame.insetBy(dx: -Self.itemDrawOutset, dy: -Self.itemDrawOutset))
    }

    private func invalidateItems(withIDs ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for item in itemStore where ids.contains(item.id) {
            invalidateItemArea(item.frame)
        }
    }

    private func hitTestItem(at point: CGPoint) -> DesktopItem? {
        for item in itemStore.reversed() {
            let iconHit = CGRect(x: item.frame.midX - 30, y: item.frame.minY + 2, width: 60, height: 60)
            let labelHit = CGRect(x: item.frame.minX, y: item.frame.minY + 58, width: item.frame.width, height: 32)
            if iconHit.contains(point) || labelHit.contains(point) {
                return item
            }
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitInlineRename()

        let pt = convert(event.locationInWindow, from: nil)
        let cmdOrShift = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift)
        foreignWindowRectsCache = nil
        liveDragOffset = .zero

        if let hit = hitTestItem(at: pt) {
            if cmdOrShift {
                if selectedIDs.contains(hit.id) {
                    selectedIDs.remove(hit.id)
                } else {
                    selectedIDs.insert(hit.id)
                }
            } else if !selectedIDs.contains(hit.id) {
                selectedIDs = [hit.id]
            }
            needsDisplay = true

            if event.clickCount == 2 {
                openSelectedItems()
                interaction = .idle
                return
            }

            var initial: [String: CGRect] = [:]
            for item in itemStore where selectedIDs.contains(item.id) {
                initial[item.id] = item.frame
            }
            interaction = .pendingItemClick(anchorPoint: pt, clickedID: hit.id, initialFrames: initial)
        } else {
            if !cmdOrShift {
                selectedIDs.removeAll()
                needsDisplay = true
            }
            onDesktopRipple?(pt, 1.0)
            interaction = .marquee(anchorPoint: pt, currentPoint: pt, baseSelection: selectedIDs)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)

        switch interaction {
        case .idle:
            break

        case .pendingItemClick(let anchor, _, let initialFrames):
            if hypot(pt.x - anchor.x, pt.y - anchor.y) >= 3.0 {
                if shouldHandOffToExternalDrag(event: event, viewPoint: pt, initialFrames: initialFrames) {
                    return
                }
                interaction = .draggingItems(anchorPoint: anchor, initialFrames: initialFrames, dropTargetID: nil)
                applyLiveItemDrag(currentPoint: pt, anchorPoint: anchor, initialFrames: initialFrames, event: event)
            }

        case .draggingItems(let anchor, let initialFrames, _):
            if shouldHandOffToExternalDrag(event: event, viewPoint: pt, initialFrames: initialFrames) {
                return
            }
            applyLiveItemDrag(currentPoint: pt, anchorPoint: anchor, initialFrames: initialFrames, event: event)

        case .marquee(let anchor, let previousPoint, let base):
            let rect = Self.marqueeRect(anchor, pt)
            var next = base
            for item in itemStore where item.frame.intersects(rect) {
                if base.contains(item.id) {
                    next.remove(item.id)
                } else {
                    next.insert(item.id)
                }
            }
            invalidateItems(withIDs: next.symmetricDifference(selectedIDs))
            setNeedsDisplay(Self.marqueeRect(anchor, previousPoint).union(rect).insetBy(dx: -2, dy: -2))
            selectedIDs = next
            interaction = .marquee(anchorPoint: anchor, currentPoint: pt, baseSelection: base)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)

        switch interaction {
        case .pendingItemClick(_, let clickedID, _):
            if !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift) {
                selectedIDs = [clickedID]
                needsDisplay = true
            }

        case .draggingItems(_, let initialFrames, let dropTargetID):
            finishItemDrag(at: pt, initialFrames: initialFrames, dropTargetID: dropTargetID)

        case .marquee:
            needsDisplay = true

        case .idle:
            break
        }
        interaction = .idle
        foreignWindowRectsCache = nil
    }

    private func applyDragOffset(_ offset: CGVector, initialFrames: [String: CGRect]) {
        guard !initialFrames.isEmpty else { return }
        for i in itemStore.indices {
            guard let orig = initialFrames[itemStore[i].id] else { continue }
            let next = CGRect(
                x: round(orig.origin.x + offset.dx),
                y: round(orig.origin.y + offset.dy),
                width: orig.width,
                height: orig.height
            )
            if next != itemStore[i].frame {
                invalidateItemArea(itemStore[i].frame)
                invalidateItemArea(next)
                itemStore[i].frame = next
            }
        }
    }

    private func restoreInitialFrames(_ initialFrames: [String: CGRect]) {
        for i in itemStore.indices {
            if let orig = initialFrames[itemStore[i].id] {
                itemStore[i].frame = orig
            }
        }
        liveDragOffset = .zero
        needsDisplay = true
    }

    private func applyLiveItemDrag(
        currentPoint: CGPoint,
        anchorPoint: CGPoint,
        initialFrames: [String: CGRect],
        event: NSEvent
    ) {
        let offset = CGVector(dx: currentPoint.x - anchorPoint.x, dy: currentPoint.y - anchorPoint.y)

        var folderTarget: String?
        for item in itemStore where initialFrames[item.id] == nil {
            if item.kind == .folder || item.kind == .application {
                let hit = item.frame.insetBy(dx: 8, dy: 8)
                if hit.contains(currentPoint) {
                    folderTarget = item.id
                    break
                }
            }
        }
        if case .draggingItems(_, _, let previousTarget) = interaction, previousTarget != folderTarget {
            invalidateItems(withIDs: Set([previousTarget, folderTarget].compactMap { $0 }))
        }
        interaction = .draggingItems(anchorPoint: anchorPoint, initialFrames: initialFrames, dropTargetID: folderTarget)

        liveDragOffset = offset
        applyDragOffset(offset, initialFrames: initialFrames)

        let obs = itemStore.map { IconObstacle(rect: $0.frame) }
        onLiveDragObstacles?(obs, true)
    }

    private func finishItemDrag(
        at dropPoint: CGPoint,
        initialFrames: [String: CGRect],
        dropTargetID: String?
    ) {
        if let targetID = dropTargetID,
           let targetItem = itemStore.first(where: { $0.id == targetID }) {
            let draggedItems = itemStore.filter { initialFrames[$0.id] != nil }
            restoreInitialFrames(initialFrames)
            if targetItem.kind == .folder {
                let fm = FileManager.default
                for dragged in draggedItems where dragged.kind != .volume {
                    let dst = uniqueDestinationURL(in: targetItem.url, proposedName: dragged.url.lastPathComponent)
                    do {
                        try fm.moveItem(at: dragged.url, to: dst)
                    } catch {
                        desklandLog.error("Move into folder failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                onRequestReload?()
                return
            } else if targetItem.kind == .application {
                let urls = draggedItems.map(\.openableURL)
                NSWorkspace.shared.open(urls, withApplicationAt: targetItem.url, configuration: NSWorkspace.OpenConfiguration())
                let obs = itemStore.map { IconObstacle(rect: $0.frame) }
                onLiveDragObstacles?(obs, false)
                return
            }
        }

        let screen = window?.screen ?? NSScreen.primaryDesktop
        let screenFrame = screen?.frame ?? bounds
        let visibleFrame = screen?.visibleFrame ?? bounds
        let workArea = DesktopGridMetrics.workAreaTopLeft(screenFrame: screenFrame, visibleFrame: visibleFrame)

        let widgetRects = screen.map { FinderIconTracker.queryDesktopWidgetRects(screen: $0) } ?? []
        var occupied = widgetRects + itemStore.filter { initialFrames[$0.id] == nil }.map(\.frame)
        var updates: [String: CGRect] = [:]

        for i in itemStore.indices where initialFrames[itemStore[i].id] != nil {
            var rect = itemStore[i].frame
            rect.origin.x = min(max(workArea.minX + 4, rect.origin.x), workArea.maxX - rect.width - 4)
            rect.origin.y = min(max(workArea.minY + 4, rect.origin.y), workArea.maxY - rect.height - 4)
            let coveredByWidget = widgetRects.contains { $0.contains(CGPoint(x: rect.midX, y: rect.midY)) }
            if snapToGrid || coveredByWidget {
                rect = DesktopGridMetrics.snapToNearestFreeSlot(
                    proposedOrigin: rect.origin,
                    occupiedRects: occupied,
                    workArea: workArea
                )
            }
            occupied.append(rect)
            itemStore[i].frame = rect
            updates[itemStore[i].id] = rect
        }
        liveDragOffset = .zero

        onDesktopRipple?(dropPoint, 1.25)
        let obs = itemStore.map { IconObstacle(rect: $0.frame) }
        onLiveDragObstacles?(obs, false)
        onCommitItemFrames?(updates)
        needsDisplay = true
    }

    private func shouldHandOffToExternalDrag(
        event: NSEvent,
        viewPoint: CGPoint,
        initialFrames: [String: CGRect]
    ) -> Bool {
        guard let screen = window?.screen ?? NSScreen.primaryDesktop else { return false }
        let workArea = DesktopGridMetrics.workAreaTopLeft(screenFrame: screen.frame, visibleFrame: screen.visibleFrame)
        let enteredDockStrip = viewPoint.y > workArea.maxY + 10
        let holdingOptionForExternalCopy = event.modifierFlags.contains(.option)

        guard enteredDockStrip || holdingOptionForExternalCopy || isPointCoveredByAppWindow(viewPoint, screen: screen) else {
            return false
        }

        restoreInitialFrames(initialFrames)
        let obs = itemStore.map { IconObstacle(rect: $0.frame) }
        onLiveDragObstacles?(obs, false)
        interaction = .idle

        var draggingItems: [NSDraggingItem] = []
        for item in itemStore where initialFrames[item.id] != nil && item.kind != .volume {
            let dragItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let imgFrame = CGRect(x: viewPoint.x - 27, y: viewPoint.y - 27, width: 54, height: 54)
            dragItem.setDraggingFrame(imgFrame, contents: item.icon)
            draggingItems.append(dragItem)
        }
        guard !draggingItems.isEmpty else { return true }
        beginDraggingSession(with: draggingItems, event: event, source: self)
        return true
    }

    private func isPointCoveredByAppWindow(_ topLeftPt: CGPoint, screen: NSScreen) -> Bool {
        let primaryH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let globalTopY = (primaryH - screen.frame.maxY) + topLeftPt.y
        let globalPt = CGPoint(x: topLeftPt.x + screen.frame.minX, y: globalTopY)
        return foreignWindowRects().contains { $0.contains(globalPt) }
    }

    private func foreignWindowRects() -> [CGRect] {
        if let cached = foreignWindowRectsCache { return cached }
        var rects: [CGRect] = []
        if let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
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
                      let alpha = info[kCGWindowAlpha as String] as? Double,
                      alpha >= 0.96,
                      let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: boundsDict) else { continue }
                if let owner = info[kCGWindowOwnerName as String] as? String,
                   DesktopWindowController.ignoredCoverageOwners.contains(owner) {
                    continue
                }
                rects.append(rect.insetBy(dx: 12, dy: 12))
            }
        }
        foreignWindowRectsCache = rects
        return rects
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .every
    }

    nonisolated func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation == .move || operation == .delete {
            Task { @MainActor [weak self] in
                self?.onRequestReload?()
            }
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        proposedDropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        proposedDropOperation(for: sender)
    }

    private func droppedFileURLs(_ sender: any NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
    }

    private func shouldCopy(_ srcURL: URL, sender: any NSDraggingInfo) -> Bool {
        let allowed = sender.draggingSourceOperationMask
        if !allowed.contains(.move) { return true }
        if NSEvent.modifierFlags.contains(.option) && allowed.contains(.copy) { return true }
        return !Self.isOnSameVolume(srcURL, activeDesktopURL) && allowed.contains(.copy)
    }

    private func proposedDropOperation(for sender: any NSDraggingInfo) -> NSDragOperation {
        let urls = droppedFileURLs(sender)
        guard !urls.isEmpty else { return [] }
        let allowed = sender.draggingSourceOperationMask
        let copy = urls.contains { shouldCopy($0, sender: sender) }
        if copy { return allowed.contains(.copy) ? .copy : [] }
        return allowed.contains(.move) ? .move : []
    }

    private static func isOnSameVolume(_ a: URL, _ b: URL) -> Bool {
        func volumeID(_ url: URL) -> NSObject? {
            (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let va = volumeID(a), let vb = volumeID(b) else { return true }
        return va.isEqual(vb)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = droppedFileURLs(sender)
        guard !urls.isEmpty else { return false }

        let dropPt = convert(sender.draggingLocation, from: nil)
        let fm = FileManager.default
        var anyHandled = false

        for (i, srcURL) in urls.enumerated() {
            let copy = shouldCopy(srcURL, sender: sender)
            if srcURL.deletingLastPathComponent().standardizedFileURL == activeDesktopURL.standardizedFileURL && !copy {
                continue
            }
            let dstURL = uniqueDestinationURL(in: activeDesktopURL, proposedName: srcURL.lastPathComponent)
            do {
                if copy {
                    try fm.copyItem(at: srcURL, to: dstURL)
                } else {
                    try fm.moveItem(at: srcURL, to: dstURL)
                }
                let offsetOrigin = CGPoint(x: dropPt.x - 42 + CGFloat(i * 18), y: dropPt.y - 34 + CGFloat(i * 18))
                onCommitItemFrames?([dstURL.path: CGRect(origin: offsetOrigin, size: CGSize(width: DesktopGridMetrics.iconBoxW, height: DesktopGridMetrics.iconBoxH))])
                anyHandled = true
            } catch {
                desklandLog.error("Desktop drop failed for \(srcURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        if anyHandled {
            onDesktopRipple?(dropPt, 1.3)
            onRequestReload?()
        }
        return anyHandled
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        commitInlineRename()
        let pt = convert(event.locationInWindow, from: nil)
        lastContextClickPoint = pt

        if let hit = hitTestItem(at: pt) {
            if !selectedIDs.contains(hit.id) {
                selectedIDs = [hit.id]
                needsDisplay = true
            }
            return buildItemContextMenu(primaryItem: hit)
        } else {
            return buildDesktopBackgroundMenu()
        }
    }

    private func buildItemContextMenu(primaryItem: DesktopItem) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open", action: #selector(menuOpenItems), keyEquivalent: "\r").target = self

        if selectedIDs.count == 1 {
            menu.addItem(withTitle: "Quick Look “\(primaryItem.displayName)”", action: #selector(menuQuickLook), keyEquivalent: " ").target = self
        }

        if primaryItem.isICloudItem && !primaryItem.isDownloaded {
            menu.addItem(withTitle: "Download Now from iCloud", action: #selector(menuDownloadICloud), keyEquivalent: "").target = self
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "Show in Finder", action: #selector(menuRevealInFinder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Get Info", action: #selector(menuGetInfo), keyEquivalent: "i").target = self

        if selectedIDs.count == 1 && primaryItem.kind != .volume {
            menu.addItem(.separator())
            menu.addItem(withTitle: "Rename…", action: #selector(menuRenameItem), keyEquivalent: "").target = self
        }

        if primaryItem.kind != .volume {
            menu.addItem(withTitle: "Copy", action: #selector(menuCopyItems), keyEquivalent: "c").target = self
            menu.addItem(withTitle: "Duplicate", action: #selector(menuDuplicateItems), keyEquivalent: "d").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Move to Trash", action: #selector(menuMoveToTrash), keyEquivalent: "\u{08}").target = self
        }
        return menu
    }

    private func buildDesktopBackgroundMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Folder", action: #selector(menuNewFolder), keyEquivalent: "N").target = self

        if NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            menu.addItem(withTitle: "Paste Item", action: #selector(menuPasteItems), keyEquivalent: "v").target = self
        }

        menu.addItem(.separator())
        let snapItem = NSMenuItem(title: "Snap Icons to Grid", action: #selector(menuToggleSnap), keyEquivalent: "")
        snapItem.target = self
        snapItem.state = snapToGrid ? .on : .off
        menu.addItem(snapItem)

        menu.addItem(withTitle: "Clean Up", action: #selector(menuCleanUp), keyEquivalent: "").target = self

        let sortMenu = NSMenu()
        for (title, order) in [("Name", DesktopSortOrder.name), ("Kind", .kind), ("Date Modified", .dateModified), ("Size", .size)] {
            let mi = NSMenuItem(title: title, action: #selector(menuSortBy(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = order.rawValue
            sortMenu.addItem(mi)
        }
        let sortParent = NSMenuItem(title: "Clean Up By", action: nil, keyEquivalent: "")
        sortParent.submenu = sortMenu
        menu.addItem(sortParent)

        menu.addItem(.separator())

        if !availableThemes.isEmpty {
            let themeMenu = NSMenu()
            for th in availableThemes {
                let mi = NSMenuItem(title: th.name, action: #selector(menuSetTheme(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = th.id
                mi.state = (currentThemeID == th.id) ? .on : .off
                themeMenu.addItem(mi)
            }
            let themeParent = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
            themeParent.submenu = themeMenu
            menu.addItem(themeParent)
        }

        let todMenu = NSMenu()
        for (label, mode) in [
            ("Dynamic (Follows Mac Clock)", TimeOfDayMode.dynamic),
            ("Dawn", .dawn),
            ("Daylight", .day),
            ("Sunset (Red & Orange)", .sunset),
            ("Night (Moonlit Blue)", .night)
        ] {
            let mi = NSMenuItem(title: label, action: #selector(menuSetTimeOfDay(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = mode.rawValue
            mi.state = (currentTimeOfDay == mode) ? .on : .off
            todMenu.addItem(mi)
        }
        let todParent = NSMenuItem(title: "Time of Day", action: nil, keyEquivalent: "")
        todParent.submenu = todMenu
        menu.addItem(todParent)

        let modeMenu = NSMenu()
        let interactiveItem = NSMenuItem(title: "120Hz Interactive Desktop & Icons", action: #selector(menuKeepInteractiveMode), keyEquivalent: "")
        interactiveItem.target = self
        interactiveItem.state = .on
        modeMenu.addItem(interactiveItem)

        let finderItem = NSMenuItem(title: "Finder Native Icons Underlay", action: #selector(menuSwitchToFinder), keyEquivalent: "")
        finderItem.target = self
        finderItem.state = .off
        modeMenu.addItem(finderItem)

        let modeParent = NSMenuItem(title: "Desktop Icons Mode", action: nil, keyEquivalent: "")
        modeParent.submenu = modeMenu
        menu.addItem(modeParent)

        menu.addItem(withTitle: "Refresh Scenery", action: #selector(menuRefreshScenery), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "About Deskland", action: #selector(menuOpenAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Deskland Settings…", action: #selector(menuOpenSettings), keyEquivalent: ",").target = self
        return menu
    }

    override func keyDown(with event: NSEvent) {
        if renamingItemID != nil {
            super.keyDown(with: event)
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let keyCode = event.keyCode
        let key = event.charactersIgnoringModifiers?.lowercased()

        if keyCode == 49 && flags.isEmpty && !selectedIDs.isEmpty {
            toggleQuickLook()
            return
        }
        if (keyCode == 36 || keyCode == 76) && flags.isEmpty && selectedIDs.count == 1 {
            beginInlineRename()
            return
        }
        if flags == .command && (key == "o" || keyCode == 125) {
            openSelectedItems()
            return
        }
        if flags == .command && keyCode == 51 {
            moveSelectedToTrash()
            return
        }
        if flags == .command && key == "d" {
            duplicateSelectedItems()
            return
        }
        if flags == .command && key == "c" {
            copySelectedItems()
            return
        }
        if flags == .command && key == "v" {
            pasteItemsFromPasteboard(at: nil)
            return
        }
        if flags == .command && key == "a" {
            selectedIDs = Set(items.map(\.id))
            needsDisplay = true
            return
        }
        if flags == [.command, .shift] && key == "n" {
            createNewFolder(at: nil)
            return
        }
        if flags == .command && key == "i" {
            menuGetInfo()
            return
        }
        if keyCode == 53 {
            selectedIDs.removeAll()
            needsDisplay = true
            return
        }

        super.keyDown(with: event)
    }

    func openSelectedItems() {
        let selected = items.filter { selectedIDs.contains($0.id) }
        for item in selected {
            if case .iCloudPlaceholder(let realURL) = item.kind {
                try? FileManager.default.startDownloadingUbiquitousItem(at: item.url)
                NSWorkspace.shared.open(realURL)
            } else {
                NSWorkspace.shared.open(item.url)
            }
        }
    }

    private func moveSelectedToTrash() {
        let selected = items.filter { selectedIDs.contains($0.id) && $0.kind != .volume }
        guard !selected.isEmpty else { return }
        NSWorkspace.shared.recycle(selected.map(\.url)) { [weak self] _, error in
            if let error {
                desklandLog.error("Move to Trash failed: \(error.localizedDescription, privacy: .public)")
            }
            Task { @MainActor [weak self] in
                self?.onRequestReload?()
            }
        }
        selectedIDs.removeAll()
        needsDisplay = true
    }

    private func copySelectedItems() {
        let urls = items.filter { selectedIDs.contains($0.id) && $0.kind != .volume }.map { $0.url as NSURL }
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls)
    }

    private func pasteItemsFromPasteboard(at point: CGPoint?) {
        guard let urls = NSPasteboard.general.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else { return }

        let fm = FileManager.default
        var newFrames: [String: CGRect] = [:]
        for (idx, src) in urls.enumerated() {
            let dst = uniqueDestinationURL(in: activeDesktopURL, proposedName: src.lastPathComponent)
            if (try? fm.copyItem(at: src, to: dst)) != nil, let point {
                newFrames[dst.path] = CGRect(
                    x: point.x - 42 + CGFloat(idx * 18),
                    y: point.y - 34 + CGFloat(idx * 18),
                    width: DesktopGridMetrics.iconBoxW,
                    height: DesktopGridMetrics.iconBoxH
                )
            }
        }
        if !newFrames.isEmpty {
            onCommitItemFrames?(newFrames)
        }
        onRequestReload?()
    }

    private func duplicateSelectedItems() {
        let selected = items.filter { selectedIDs.contains($0.id) && $0.kind != .volume }
        guard !selected.isEmpty else { return }
        let fm = FileManager.default
        var newFrames: [String: CGRect] = [:]
        for item in selected {
            let ext = item.url.pathExtension
            let stem = item.url.deletingPathExtension().lastPathComponent
            let baseCopy = ext.isEmpty ? "\(stem) copy" : "\(stem) copy.\(ext)"
            let dst = uniqueDestinationURL(in: activeDesktopURL, proposedName: baseCopy)
            if (try? fm.copyItem(at: item.url, to: dst)) != nil {
                newFrames[dst.path] = item.frame.offsetBy(dx: 22, dy: 22)
            }
        }
        if !newFrames.isEmpty {
            onCommitItemFrames?(newFrames)
        }
        onRequestReload?()
    }

    private func createNewFolder(at point: CGPoint?) {
        let dst = uniqueDestinationURL(in: activeDesktopURL, proposedName: "untitled folder")
        do {
            try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: false)
            if let point {
                let rect = CGRect(
                    x: point.x - DesktopGridMetrics.iconBoxW * 0.5,
                    y: point.y - 34,
                    width: DesktopGridMetrics.iconBoxW,
                    height: DesktopGridMetrics.iconBoxH
                )
                onCommitItemFrames?([dst.path: rect])
                onDesktopRipple?(point, 1.2)
            }
            onRequestReload?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                guard let self else { return }
                self.selectedIDs = [dst.path]
                self.needsDisplay = true
                self.beginInlineRename()
            }
        } catch {}
    }

    private func uniqueDestinationURL(in directory: URL, proposedName: String) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(proposedName)
        if !fm.fileExists(atPath: candidate.path) {
            return candidate
        }
        let ext = (proposedName as NSString).pathExtension
        let stem = (proposedName as NSString).deletingPathExtension
        for n in 2...999 {
            let nextName = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = directory.appendingPathComponent(nextName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return candidate
    }

    private func beginInlineRename() {
        guard selectedIDs.count == 1,
              let id = selectedIDs.first,
              let item = items.first(where: { $0.id == id }),
              item.kind != .volume,
              !item.isICloudPlaceholder else { return }

        commitInlineRename()
        renamingItemID = id

        let tf = NSTextField(string: item.url.lastPathComponent)
        tf.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        tf.alignment = .center
        tf.isBordered = true
        tf.bezelStyle = .roundedBezel
        tf.focusRingType = .exterior
        tf.delegate = self
        tf.frame = CGRect(
            x: item.frame.midX - 56,
            y: item.frame.minY + 60,
            width: 112,
            height: 22
        )
        addSubview(tf)
        renameField = tf
        window?.makeFirstResponder(tf)

        if let editor = tf.currentEditor() {
            let full = item.url.lastPathComponent
            let stemLen = (full as NSString).deletingPathExtension.utf16.count
            editor.selectedRange = NSRange(location: 0, length: stemLen > 0 ? stemLen : full.utf16.count)
        }
        needsDisplay = true
    }

    private func commitInlineRename() {
        guard let tf = renameField, let id = renamingItemID else { return }
        let newName = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Clear state before removeFromSuperview(), which re-enters via controlTextDidEndEditing.
        renameField = nil
        renamingItemID = nil
        tf.delegate = nil
        tf.removeFromSuperview()

        if !newName.isEmpty,
           !newName.contains("/"),
           let item = items.first(where: { $0.id == id }),
           newName != item.url.lastPathComponent {
            let newURL = item.url.deletingLastPathComponent().appendingPathComponent(newName)
            if !FileManager.default.fileExists(atPath: newURL.path) {
                do {
                    try FileManager.default.moveItem(at: item.url, to: newURL)
                    onCommitItemFrames?([newURL.path: item.frame])
                    selectedIDs = [newURL.path]
                    onRequestReload?()
                } catch {
                    desklandLog.error("Rename failed: \(error.localizedDescription, privacy: .public)")
                    NSSound.beep()
                }
            } else {
                NSSound.beep()
            }
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func cancelInlineRename() {
        guard let tf = renameField else { return }
        renameField = nil
        renamingItemID = nil
        tf.delegate = nil
        tf.abortEditing()
        tf.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitInlineRename()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelInlineRename()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitInlineRename()
            return true
        }
        return false
    }

    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        guard let panel else { return }
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        guard let panel else { return }
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        items.filter { selectedIDs.contains($0.id) }.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let selected = items.filter { selectedIDs.contains($0.id) }
        guard index >= 0 && index < selected.count else { return nil }
        return selected[index].openableURL as NSURL
    }

    @objc private func menuOpenItems() { openSelectedItems() }
    @objc private func menuQuickLook() { toggleQuickLook() }
    @objc private func menuDownloadICloud() {
        for item in items where selectedIDs.contains(item.id) {
            try? FileManager.default.startDownloadingUbiquitousItem(at: item.url)
        }
    }
    @objc private func menuRevealInFinder() {
        let urls = items.filter { selectedIDs.contains($0.id) }.map(\.url)
        if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }
    @objc private func menuGetInfo() {
        guard let first = items.first(where: { selectedIDs.contains($0.id) }) else { return }
        let escaped = first.url.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "tell application \"Finder\" to open information window of (POSIX file \"\(escaped)\" as alias)\ntell application \"Finder\" to activate"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err {
            desklandLog.error("Get Info via Finder failed: \(String(describing: err), privacy: .public)")
            NSWorkspace.shared.activateFileViewerSelecting([first.url])
        }
    }
    @objc private func menuRenameItem() { beginInlineRename() }
    @objc private func menuCopyItems() { copySelectedItems() }
    @objc private func menuDuplicateItems() { duplicateSelectedItems() }
    @objc private func menuMoveToTrash() { moveSelectedToTrash() }
    @objc private func menuNewFolder() { createNewFolder(at: lastContextClickPoint) }
    @objc private func menuPasteItems() { pasteItemsFromPasteboard(at: lastContextClickPoint) }
    @objc private func menuToggleSnap() { onToggleSnapToGrid?() }
    @objc private func menuCleanUp() { onCleanUp?(.none) }
    @objc private func menuSortBy(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let order = DesktopSortOrder(rawValue: raw) {
            onCleanUp?(order)
        }
    }
    @objc private func menuSetTheme(_ sender: NSMenuItem) {
        if let tid = sender.representedObject as? String {
            onSelectTheme?(tid)
        }
    }
    @objc private func menuSetTimeOfDay(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = TimeOfDayMode(rawValue: raw) {
            onSelectTimeOfDay?(mode)
        }
    }
    @objc private func menuRefreshScenery() { onRefreshScenery?() }
    @objc private func menuKeepInteractiveMode() {}
    @objc private func menuSwitchToFinder() { onSwitchToFinderMode?() }
    @objc private func menuOpenAbout() { onOpenAbout?() }
    @objc private func menuOpenSettings() { onOpenSettings?() }
}
