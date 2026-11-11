import Foundation
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

enum DesktopSourcePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case auto = "auto"
    case iCloud = "icloud"
    case local = "local"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto (iCloud if Enabled)"
        case .iCloud: return "iCloud Desktop"
        case .local: return "Local ~/Desktop"
        }
    }
}

enum DesktopSortOrder: String, CaseIterable, Identifiable {
    case none = "none"
    case name = "name"
    case kind = "kind"
    case dateModified = "dateModified"
    case size = "size"

    var id: String { rawValue }
}

extension NSScreen {
    static var primaryDesktop: NSScreen? {
        screens.first ?? main
    }
}

@MainActor
final class DesktopDirectoryResolver {
    private(set) var activeDesktopURL: URL
    private(set) var isUsingICloudDesktop: Bool = false
    private(set) var items: [DesktopItem] = []
    private(set) var finderNativeRects: [CGRect] = []

    var sourcePreference: DesktopSourcePreference = .auto {
        didSet {
            if oldValue != sourcePreference {
                resolveDirectoryAndWatch()
                reloadItems()
            }
        }
    }

    var onItemsChanged: (([DesktopItem]) -> Void)?

    private var customPositions: [String: CGPoint] = [:]
    private let positionsSaveURL: URL
    private var thumbnailCache: [String: (modified: Date?, image: NSImage)] = [:]
    private var pendingThumbnails: Set<String> = []
    private var failedThumbnails: [String: Date?] = [:]

    private var dirSource: DispatchSourceFileSystemObject?
    private var dsStoreSource: DispatchSourceFileSystemObject?
    private var reloadWorkItem: DispatchWorkItem?

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Deskland", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.positionsSaveURL = appSupport.appendingPathComponent("icon-positions.json")
        self.activeDesktopURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")

        loadSavedPositions()
        resolveDirectoryAndWatch()
        observeVolumeMounts()
    }

    deinit {
        dirSource?.cancel()
        dsStoreSource?.cancel()
    }

    static func resolveDesktopDirectory(preference: DesktopSourcePreference) -> (url: URL, isICloud: Bool) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let localDesktop = home.appendingPathComponent("Desktop", isDirectory: true)
        let cloudDesktop = home
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Desktop", isDirectory: true)

        var cloudDirExists: ObjCBool = false
        let hasCloudDir = fm.fileExists(atPath: cloudDesktop.path, isDirectory: &cloudDirExists) && cloudDirExists.boolValue

        switch preference {
        case .iCloud:
            if hasCloudDir {
                return (cloudDesktop, true)
            }
            return (localDesktop, false)

        case .local:
            return (localDesktop, false)

        case .auto:
            let finderDefaults = UserDefaults(suiteName: "com.apple.finder")
            let fxCloudEnabled = finderDefaults?.object(forKey: "FXICloudDriveDesktop") as? Bool

            if fxCloudEnabled == true && hasCloudDir {
                return (cloudDesktop, true)
            }

            let resolvedLocal = localDesktop.resolvingSymlinksInPath()
            if resolvedLocal.path.contains("com~apple~CloudDocs") {
                return (resolvedLocal, true)
            }
            if let vals = try? localDesktop.resourceValues(forKeys: [.isUbiquitousItemKey]),
               vals.isUbiquitousItem == true {
                return (localDesktop, true)
            }

            if fxCloudEnabled == nil && hasCloudDir {
                let cloudContents = (try? fm.contentsOfDirectory(atPath: cloudDesktop.path))?.filter { !$0.hasPrefix(".") } ?? []
                let localContents = (try? fm.contentsOfDirectory(atPath: localDesktop.path))?.filter { !$0.hasPrefix(".") } ?? []
                if !cloudContents.isEmpty && localContents.isEmpty {
                    return (cloudDesktop, true)
                }
            }

            return (localDesktop, false)
        }
    }

    func resolveDirectoryAndWatch() {
        let resolved = Self.resolveDesktopDirectory(preference: sourcePreference)
        activeDesktopURL = resolved.url
        isUsingICloudDesktop = resolved.isICloud
        startDirectoryWatcher()
    }

    private func startDirectoryWatcher() {
        dirSource?.cancel()
        dirSource = nil
        dsStoreSource?.cancel()
        dsStoreSource = nil

        let fd = open(activeDesktopURL.path, O_EVTONLY)
        if fd >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .rename, .delete, .attrib, .extend],
                queue: .main
            )
            src.setEventHandler { [weak self] in
                guard let self else { return }
                // Finder updates .DS_Store via atomic rename, replacing its inode.
                self.rearmDSStoreWatcher()
                self.scheduleDebouncedReload()
            }
            src.setCancelHandler {
                close(fd)
            }
            src.resume()
            dirSource = src
        }

        rearmDSStoreWatcher()
    }

    private func rearmDSStoreWatcher() {
        dsStoreSource?.cancel()
        dsStoreSource = nil

        let dsURL = activeDesktopURL.appendingPathComponent(".DS_Store")
        let dfd = open(dsURL.path, O_EVTONLY)
        if dfd >= 0 {
            let dsrc = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: dfd,
                eventMask: [.write, .extend, .attrib, .rename, .delete],
                queue: .main
            )
            dsrc.setEventHandler { [weak self, weak dsrc] in
                guard let self else { return }
                let flags = dsrc?.data ?? []
                if flags.contains(.rename) || flags.contains(.delete) {
                    self.rearmDSStoreWatcher()
                }
                self.scheduleDebouncedReload()
            }
            dsrc.setCancelHandler {
                close(dfd)
            }
            dsrc.resume()
            dsStoreSource = dsrc
        }
    }

    private func observeVolumeMounts() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.scheduleDebouncedReload()
                }
            }
        }
    }

    func scheduleDebouncedReload(delay: TimeInterval = 0.14) {
        reloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.reloadItems()
            }
        }
        reloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func reloadItems(screen: NSScreen? = NSScreen.primaryDesktop) {
        let fm = FileManager.default
        let screenFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 70, width: 1512, height: 874)
        let workArea = DesktopGridMetrics.workAreaTopLeft(screenFrame: screenFrame, visibleFrame: visibleFrame)
        let menuBarHeight = workArea.minY

        let parsedDS = DSStoreParser.parseDesktopLocations(
            at: activeDesktopURL.appendingPathComponent(".DS_Store"),
            screenSize: screenFrame.size
        )

        let resourceKeys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isPackageKey,
            .isApplicationKey,
            .isAliasFileKey,
            .isSymbolicLinkKey,
            .isHiddenKey,
            .localizedNameKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .contentModificationDateKey,
            .fileSizeKey
        ]

        var rawURLs = (try? fm.contentsOfDirectory(
            at: activeDesktopURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        )) ?? []

        rawURLs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        let widgetRects = screen.map { FinderIconTracker.queryDesktopWidgetRects(screen: $0) } ?? []
        var builtItems: [DesktopItem] = []
        var occupiedRects: [CGRect] = widgetRects
        var finderOccupiedRects: [CGRect] = widgetRects
        var builtFinderRects: [CGRect] = []

        let finderDefs = UserDefaults(suiteName: "com.apple.finder")
        let showExternal = (finderDefs?.object(forKey: "ShowExternalHardDrivesOnDesktop") as? Bool) ?? true
        let showRemovable = (finderDefs?.object(forKey: "ShowRemovableMediaOnDesktop") as? Bool) ?? true
        let showServers = (finderDefs?.object(forKey: "ShowMountedServersOnDesktop") as? Bool) ?? false

        if showExternal || showRemovable || showServers {
            let volKeys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsLocalKey, .volumeNameKey]
            let mounted = fm.mountedVolumeURLs(includingResourceValuesForKeys: volKeys, options: [.skipHiddenVolumes]) ?? []
            for volURL in mounted where volURL.path != "/" {
                let vals = try? volURL.resourceValues(forKeys: Set(volKeys))
                let isInternal = vals?.volumeIsInternal ?? false
                let isRemovable = vals?.volumeIsRemovable ?? false
                let isLocal = vals?.volumeIsLocal ?? true
                let include = (!isLocal && showServers) || (isRemovable && showRemovable) || (!isInternal && !isRemovable && isLocal && showExternal)
                if !include { continue }

                let name = vals?.volumeName ?? volURL.lastPathComponent
                let key = "volume:\(volURL.path)"
                let icon = NSWorkspace.shared.icon(forFile: volURL.path)
                icon.size = NSSize(width: 64, height: 64)

                let rect = resolveFrame(
                    key: key,
                    fileName: name,
                    parsedDS: parsedDS,
                    menuBarHeight: menuBarHeight,
                    workArea: workArea,
                    allowCustomOverride: true,
                    occupiedRects: &occupiedRects
                )
                occupiedRects.append(rect)
                let fRect = resolveFrame(
                    key: key,
                    fileName: name,
                    parsedDS: parsedDS,
                    menuBarHeight: menuBarHeight,
                    workArea: workArea,
                    allowCustomOverride: false,
                    occupiedRects: &finderOccupiedRects
                )
                finderOccupiedRects.append(fRect)
                builtFinderRects.append(fRect)
                builtItems.append(DesktopItem(
                    id: key,
                    url: volURL,
                    displayName: name,
                    kind: .volume,
                    isICloudItem: false,
                    isDownloaded: true,
                    frame: rect,
                    icon: icon
                ))
            }
        }

        for url in rawURLs {
            let rawName = url.lastPathComponent
            if rawName == ".DS_Store" || rawName == ".localized" { continue }

            if rawName.hasPrefix(".") && rawName.hasSuffix(".icloud") && rawName.count > 8 {
                let start = rawName.index(after: rawName.startIndex)
                let end = rawName.index(rawName.endIndex, offsetBy: -7)
                let realName = String(rawName[start..<end])
                let realURL = activeDesktopURL.appendingPathComponent(realName)
                let key = realURL.path
                let ext = (realName as NSString).pathExtension
                let utType = UTType(filenameExtension: ext) ?? .data
                let icon = NSWorkspace.shared.icon(for: utType)
                icon.size = NSSize(width: 64, height: 64)

                let rect = resolveFrame(
                    key: key,
                    fileName: realName,
                    parsedDS: parsedDS,
                    menuBarHeight: menuBarHeight,
                    workArea: workArea,
                    allowCustomOverride: true,
                    occupiedRects: &occupiedRects
                )
                occupiedRects.append(rect)
                let fRect = resolveFrame(
                    key: key,
                    fileName: realName,
                    parsedDS: parsedDS,
                    menuBarHeight: menuBarHeight,
                    workArea: workArea,
                    allowCustomOverride: false,
                    occupiedRects: &finderOccupiedRects
                )
                finderOccupiedRects.append(fRect)
                builtFinderRects.append(fRect)
                builtItems.append(DesktopItem(
                    id: key,
                    url: url,
                    displayName: realName,
                    kind: .iCloudPlaceholder(realURL: realURL),
                    isICloudItem: true,
                    isDownloaded: false,
                    frame: rect,
                    icon: icon
                ))
                continue
            }

            if rawName.hasPrefix(".") { continue }
            let vals = try? url.resourceValues(forKeys: resourceKeys)
            if vals?.isHidden == true { continue }

            let isApp = vals?.isApplication == true || url.pathExtension.lowercased() == "app"
            let isAlias = vals?.isAliasFile == true || vals?.isSymbolicLink == true
            let isDir = (vals?.isDirectory == true) && (vals?.isPackage != true) && !isApp
            let kind: DesktopItem.Kind = isApp ? .application : (isAlias ? .alias : (isDir ? .folder : .file))

            let isUbiq = (vals?.isUbiquitousItem == true) || isUsingICloudDesktop
            let dlStatus = vals?.ubiquitousItemDownloadingStatus
            let isDownloaded = (dlStatus == nil) || (dlStatus == .current) || (dlStatus == .downloaded)

            let displayName = fm.displayName(atPath: url.path)
            let key = url.path
            let modified = vals?.contentModificationDate

            let icon: NSImage
            if let cached = thumbnailCache[key], cached.modified == modified {
                icon = cached.image
            } else {
                let baseIcon = NSWorkspace.shared.icon(forFile: url.path)
                baseIcon.size = NSSize(width: 64, height: 64)
                icon = baseIcon
                let previouslyFailed = failedThumbnails[key].map { $0 == modified } ?? false
                if kind == .file && isDownloaded && !previouslyFailed && !pendingThumbnails.contains(key) {
                    requestQuickLookThumbnail(for: url, key: key, modified: modified)
                }
            }

            let rect = resolveFrame(
                key: key,
                fileName: rawName,
                parsedDS: parsedDS,
                menuBarHeight: menuBarHeight,
                workArea: workArea,
                allowCustomOverride: true,
                occupiedRects: &occupiedRects
            )
            occupiedRects.append(rect)
            let fRect = resolveFrame(
                key: key,
                fileName: rawName,
                parsedDS: parsedDS,
                menuBarHeight: menuBarHeight,
                workArea: workArea,
                allowCustomOverride: false,
                occupiedRects: &finderOccupiedRects
            )
            finderOccupiedRects.append(fRect)
            builtFinderRects.append(fRect)

            builtItems.append(DesktopItem(
                id: key,
                url: url,
                displayName: displayName,
                kind: kind,
                isICloudItem: isUbiq,
                isDownloaded: isDownloaded,
                frame: rect,
                icon: icon
            ))
        }

        if thumbnailCache.count > 160 || failedThumbnails.count > 160 {
            let validKeys = Set(builtItems.map(\.id))
            thumbnailCache = thumbnailCache.filter { validKeys.contains($0.key) }
            failedThumbnails = failedThumbnails.filter { validKeys.contains($0.key) }
        }

        self.finderNativeRects = builtFinderRects
        self.items = builtItems
        onItemsChanged?(builtItems)
    }

    private func resolveFrame(
        key: String,
        fileName: String,
        parsedDS: DSStoreParser.ParsedLocations,
        menuBarHeight: CGFloat,
        workArea: CGRect,
        allowCustomOverride: Bool,
        occupiedRects: inout [CGRect]
    ) -> CGRect {
        let w = DesktopGridMetrics.iconBoxW
        let h = DesktopGridMetrics.iconBoxH

        if allowCustomOverride, let saved = customPositions[key] {
            let clampedX = min(max(workArea.minX + 4, saved.x), workArea.maxX - w - 4)
            let clampedY = min(max(workArea.minY + 4, saved.y), workArea.maxY - h - 4)
            return CGRect(x: clampedX, y: clampedY, width: w, height: h)
        }

        if let center = parsedDS.centers[fileName] {
            let ox = round(center.x - w * 0.5)
            let topOffset: CGFloat = parsedDS.includesMenuBarOffset ? 0 : menuBarHeight
            let oy = round(topOffset + center.y - 34)
            let clampedX = min(max(workArea.minX + 4, ox), workArea.maxX - w - 4)
            let clampedY = min(max(workArea.minY + 2, oy), workArea.maxY - h - 4)
            return CGRect(x: clampedX, y: clampedY, width: w, height: h)
        }

        let maxRows = max(1, Int(floor((workArea.height - DesktopGridMetrics.marginTop - DesktopGridMetrics.marginBottom) / DesktopGridMetrics.cellH)))
        for idx in 0..<400 {
            let col = idx / maxRows
            let row = idx % maxRows
            let cand = DesktopGridMetrics.slotRect(colFromRight: col, rowFromTop: row, workArea: workArea)
            let collides = occupiedRects.contains {
                abs($0.midX - cand.midX) < DesktopGridMetrics.cellW * 0.45 &&
                abs($0.midY - cand.midY) < DesktopGridMetrics.cellH * 0.45
            }
            if !collides {
                return cand
            }
        }
        return CGRect(x: workArea.maxX - 110, y: workArea.minY + 20, width: w, height: h)
    }

    private func requestQuickLookThumbnail(for url: URL, key: String, modified: Date?) {
        let scale = NSScreen.primaryDesktop?.backingScaleFactor ?? 2.0
        let req = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 64, height: 64),
            scale: scale,
            representationTypes: .thumbnail
        )
        pendingThumbnails.insert(key)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            let nsImg = rep?.nsImage
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pendingThumbnails.remove(key)
                guard let nsImg else {
                    self.failedThumbnails[key] = modified
                    return
                }
                nsImg.size = NSSize(width: 64, height: 64)
                self.thumbnailCache[key] = (modified, nsImg)
                self.failedThumbnails.removeValue(forKey: key)
                if let idx = self.items.firstIndex(where: { $0.id == key }) {
                    self.items[idx].icon = nsImg
                    self.onItemsChanged?(self.items)
                }
            }
        }
    }

    func updateItemFrames(_ updates: [String: CGRect], persist: Bool) {
        var anyChanged = false
        for (id, rect) in updates {
            if let idx = items.firstIndex(where: { $0.id == id }) {
                if items[idx].frame != rect {
                    items[idx].frame = rect
                    anyChanged = true
                }
            }
            if persist {
                customPositions[id] = rect.origin
            }
        }
        if persist {
            savePositions()
        }
        if anyChanged {
            onItemsChanged?(items)
        }
    }

    func cleanUpToGrid(sortBy order: DesktopSortOrder = .none, screen: NSScreen? = NSScreen.primaryDesktop) {
        let screenFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visibleFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 70, width: 1512, height: 874)
        let workArea = DesktopGridMetrics.workAreaTopLeft(screenFrame: screenFrame, visibleFrame: visibleFrame)

        let widgetRects = screen.map { FinderIconTracker.queryDesktopWidgetRects(screen: $0) } ?? []

        if order == .none {
            var occupied: [CGRect] = widgetRects
            var updates: [String: CGRect] = [:]
            for item in items {
                let snapped = DesktopGridMetrics.snapToNearestFreeSlot(
                    proposedOrigin: item.frame.origin,
                    occupiedRects: occupied,
                    workArea: workArea
                )
                occupied.append(snapped)
                updates[item.id] = snapped
            }
            updateItemFrames(updates, persist: true)
            return
        }

        var sorted = items
        switch order {
        case .name:
            sorted.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .kind:
            sorted.sort {
                let extA = ($0.displayName as NSString).pathExtension.lowercased()
                let extB = ($1.displayName as NSString).pathExtension.lowercased()
                if extA != extB { return extA < extB }
                return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
        case .dateModified:
            let dates = Dictionary(items.map {
                ($0.id, (try? $0.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }, uniquingKeysWith: { first, _ in first })
            sorted.sort { (dates[$0.id] ?? .distantPast) > (dates[$1.id] ?? .distantPast) }
        case .size:
            let sizes = Dictionary(items.map {
                ($0.id, (try? $0.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }, uniquingKeysWith: { first, _ in first })
            sorted.sort { (sizes[$0.id] ?? 0) > (sizes[$1.id] ?? 0) }
        case .none:
            break
        }

        let maxRows = max(1, Int(floor((workArea.height - DesktopGridMetrics.marginTop - DesktopGridMetrics.marginBottom) / DesktopGridMetrics.cellH)))
        var updates: [String: CGRect] = [:]
        var slotIdx = 0
        for item in sorted {
            var candidate: CGRect
            repeat {
                let col = slotIdx / maxRows
                let row = slotIdx % maxRows
                candidate = DesktopGridMetrics.slotRect(colFromRight: col, rowFromTop: row, workArea: workArea)
                slotIdx += 1
            } while widgetRects.contains(where: { $0.intersects(candidate) }) && slotIdx < 400
            updates[item.id] = candidate
        }
        updateItemFrames(updates, persist: true)
    }

    func resetToFinderPositions() {
        customPositions.removeAll()
        savePositions()
        reloadItems()
    }

    private func loadSavedPositions() {
        guard let data = try? Data(contentsOf: positionsSaveURL),
              let raw = try? JSONDecoder().decode([String: [Double]].self, from: data) else { return }
        for (k, arr) in raw where arr.count == 2 {
            customPositions[k] = CGPoint(x: arr[0], y: arr[1])
        }
    }

    private func savePositions() {
        var serializable: [String: [Double]] = [:]
        for (k, pt) in customPositions {
            serializable[k] = [Double(pt.x), Double(pt.y)]
        }
        if let data = try? JSONEncoder().encode(serializable) {
            try? data.write(to: positionsSaveURL, options: .atomic)
        }
    }
}
