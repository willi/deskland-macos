import AppKit
import CoreGraphics

final class DesktopHostWindow: NSWindow {
    var allowsInteractiveFocus: Bool = true

    override var canBecomeKey: Bool { allowsInteractiveFocus }
    override var canBecomeMain: Bool { allowsInteractiveFocus }
}

@MainActor
final class DesktopWindowController {
    let appState: AppState
    let window: DesktopHostWindow
    let containerView: NSView
    let metalSceneView: MetalSceneView
    private var webThemeView: DesklandWebThemeView?
    let desktopCanvasView: DesktopCanvasView

    let directoryResolver = DesktopDirectoryResolver()
    let finderTracker = FinderIconTracker()

    private var isDisplayAsleep = false
    private var isScreenLocked = false
    private var occlusionGraceUntil: CFTimeInterval = CFAbsoluteTimeGetCurrent() + 1.2
    private var interactionWakeUntil: CFTimeInterval = 0
    private var coverageTimer: DispatchSourceTimer?
    private var cachedWidgetObstacles: [IconObstacle] = []

    init(appState: AppState) {
        self.appState = appState

        let screen = NSScreen.primaryDesktop ?? NSScreen.screens[0]
        let frame = screen.frame

        let win = DesktopHostWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = true
        win.hasShadow = false
        win.backgroundColor = .black
        win.isReleasedWhenClosed = false
        win.hidesOnDeactivate = false
        win.acceptsMouseMovedEvents = false
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        self.window = win

        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]
        self.containerView = container

        let metalView = MetalSceneView(frame: container.bounds, isPreview: false)
        metalView.autoresizingMask = [.width, .height]
        self.metalSceneView = metalView

        let canvas = DesktopCanvasView(frame: container.bounds)
        canvas.autoresizingMask = [.width, .height]
        self.desktopCanvasView = canvas

        container.addSubview(metalView)
        container.addSubview(canvas)
        win.contentView = container

        wireCallbacks()
        setupSystemObservers()
        syncScreenGeometry()
        syncFromAppState()

        directoryResolver.reloadItems(screen: screen)
        occlusionGraceUntil = CFAbsoluteTimeGetCurrent() + 1.2
        win.orderFrontRegardless()
        metalSceneView.renderImmediateFrame()
    }

    deinit {
        coverageTimer?.cancel()
    }

    private func wireCallbacks() {
        appState.onSyncScene = { [weak self] in
            self?.syncFromAppState()
        }
        appState.onCleanUpDesktop = { [weak self] order in
            self?.directoryResolver.cleanUpToGrid(sortBy: order, screen: self?.window.screen ?? NSScreen.primaryDesktop)
        }
        appState.onCaptureSnapshot = { [weak self] in
            self?.metalSceneView.renderPrivacySnapshot(includeAnonymizedIcons: true)
        }

        directoryResolver.onItemsChanged = { [weak self] items in
            guard let self else { return }
            self.desktopCanvasView.items = items
            self.desktopCanvasView.activeDesktopURL = self.directoryResolver.activeDesktopURL
            self.publishDesktopStatus(itemCount: items.count)

            if self.appState.iconMode == .desklandInteractive {
                if let screen = self.window.screen ?? NSScreen.primaryDesktop {
                    self.cachedWidgetObstacles = FinderIconTracker.widgetObstacles(
                        from: FinderIconTracker.queryDesktopWidgetRects(screen: screen)
                    )
                }
                let obs = items.map { IconObstacle(rect: $0.frame) } + self.cachedWidgetObstacles
                self.pushObstaclesToActiveRenderer(obs, liveDrag: false)
            } else {
                self.finderTracker.refreshObstacles(fallbackRects: self.directoryResolver.finderNativeRects)
            }
        }

        desktopCanvasView.onLiveDragObstacles = { [weak self] obs, isDragging in
            guard let self else { return }
            self.noteDesktopInteraction()
            self.metalSceneView.isDraggingIcons = isDragging
            self.pushObstaclesToActiveRenderer(obs + self.cachedWidgetObstacles, liveDrag: isDragging)
        }
        desktopCanvasView.onCommitItemFrames = { [weak self] updates in
            self?.directoryResolver.updateItemFrames(updates, persist: true)
        }
        desktopCanvasView.onDesktopRipple = { [weak self] pt, strength in
            guard let self else { return }
            self.noteDesktopInteraction()
            self.metalSceneView.triggerInteractionRipple(at: pt, strength: strength)
        }
        desktopCanvasView.onRequestReload = { [weak self] in
            self?.directoryResolver.reloadItems(screen: self?.window.screen ?? NSScreen.primaryDesktop)
        }
        desktopCanvasView.onCleanUp = { [weak self] order in
            self?.directoryResolver.cleanUpToGrid(sortBy: order, screen: self?.window.screen ?? NSScreen.primaryDesktop)
        }
        desktopCanvasView.onToggleSnapToGrid = { [weak self] in
            guard let self else { return }
            self.appState.snapToGrid.toggle()
        }
        desktopCanvasView.onRefreshScenery = { [weak self] in
            self?.appState.randomizeSeed()
        }
        desktopCanvasView.onOpenSettings = { [weak self] in
            self?.appState.onOpenSettingsWindow?()
        }
        desktopCanvasView.onOpenAbout = { [weak self] in
            self?.appState.onOpenAboutWindow?()
        }
        desktopCanvasView.onSwitchToFinderMode = { [weak self] in
            self?.appState.iconMode = .finderUnderlay
        }
        desktopCanvasView.onSelectTimeOfDay = { [weak self] mode in
            self?.appState.timeOfDayMode = mode
        }
        desktopCanvasView.onSelectTheme = { [weak self] tid in
            self?.appState.selectedThemeID = tid
        }

        finderTracker.onObstaclesUpdated = { [weak self] obs, isDragging in
            guard let self else { return }
            if isDragging { self.noteDesktopInteraction() }
            self.pushObstaclesToActiveRenderer(obs, liveDrag: isDragging)
        }
        finderTracker.onDesktopClickRipple = { [weak self] pt in
            guard let self else { return }
            self.noteDesktopInteraction()
            self.metalSceneView.triggerInteractionRipple(at: pt, strength: 1.0)
        }
        finderTracker.onDragStateChanged = { [weak self] dragging in
            guard let self else { return }
            if dragging { self.noteDesktopInteraction() }
            self.metalSceneView.isDraggingIcons = dragging
        }
        finderTracker.onRequestDSStoreResync = { [weak self] in
            self?.directoryResolver.reloadItems(screen: self?.window.screen ?? NSScreen.primaryDesktop)
        }

        metalSceneView.onTelemetryUpdate = { [weak self] fps, targetHz, idle in
            self?.appState.telemetry.update(fps: fps, targetHz: targetHz, idle: idle)
        }
    }

    private func pushObstaclesToActiveRenderer(_ obs: [IconObstacle], liveDrag: Bool) {
        if let webView = webThemeView {
            webView.sendObstacles(obs, bottomInset: metalSceneView.bottomInset)
        } else {
            metalSceneView.updateObstacles(obs, liveDrag: liveDrag)
        }
    }

    private func publishDesktopStatus(itemCount: Int?) {
        if appState.isUsingICloudDesktop != directoryResolver.isUsingICloudDesktop {
            appState.isUsingICloudDesktop = directoryResolver.isUsingICloudDesktop
        }
        let abbrev = (directoryResolver.activeDesktopURL.path as NSString).abbreviatingWithTildeInPath
        if appState.activeDesktopPath != abbrev {
            appState.activeDesktopPath = abbrev
        }
        if let itemCount, appState.desktopItemCount != itemCount {
            appState.desktopItemCount = itemCount
        }
    }

    func syncFromAppState() {
        directoryResolver.sourcePreference = appState.desktopSource
        publishDesktopStatus(itemCount: nil)

        desktopCanvasView.snapToGrid = appState.snapToGrid
        desktopCanvasView.currentTimeOfDay = appState.timeOfDayMode
        desktopCanvasView.currentThemeID = appState.selectedThemeID
        desktopCanvasView.availableThemes = appState.themes.filter(\.isReady).map { (id: $0.id, name: $0.name) }
        desktopCanvasView.activeDesktopURL = directoryResolver.activeDesktopURL

        let interactive = (appState.iconMode == .desklandInteractive)
        let targetLevel: NSWindow.Level = interactive
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)

        if window.level != targetLevel {
            occlusionGraceUntil = CFAbsoluteTimeGetCurrent() + 1.0
            window.level = targetLevel
            window.orderFrontRegardless()
        }
        window.allowsInteractiveFocus = interactive
        window.ignoresMouseEvents = !interactive
        desktopCanvasView.isHidden = !interactive
        finderTracker.isEnabled = !interactive && !isDisplayAsleep && !isScreenLocked

        if let screen = window.screen ?? NSScreen.primaryDesktop {
            cachedWidgetObstacles = FinderIconTracker.widgetObstacles(
                from: FinderIconTracker.queryDesktopWidgetRects(screen: screen)
            )
        }

        if let theme = appState.selectedTheme, !theme.isBuiltInMetal,
           let extFolder = theme.externalFolderPath, let page = theme.page {
            metalSceneView.isManuallyPaused = true
            metalSceneView.isHidden = true
            if webThemeView == nil {
                let wv = DesklandWebThemeView(frame: containerView.bounds, isPreview: false)
                wv.autoresizingMask = [.width, .height]
                containerView.addSubview(wv, positioned: .below, relativeTo: desktopCanvasView)
                webThemeView = wv
            }
            let effParams = appState.effectiveParams(for: theme.id)
            webThemeView?.loadExternalTheme(folderPath: extFolder, page: page)
            webThemeView?.sendSettings(params: effParams, seed: appState.seed)
            webThemeView?.sendPaused(appState.isManuallyPaused || metalSceneView.isSystemOccluded)
            let obs = directoryResolver.items.map { IconObstacle(rect: $0.frame) } + cachedWidgetObstacles
            webThemeView?.sendObstacles(obs, bottomInset: metalSceneView.bottomInset)
        } else {
            if let wv = webThemeView {
                wv.teardownWebView()
                wv.removeFromSuperview()
                webThemeView = nil
            }
            metalSceneView.isHidden = false
            metalSceneView.isManuallyPaused = appState.isManuallyPaused
            let effParams = appState.effectiveParams(for: appState.selectedThemeID)
            metalSceneView.applyConfiguration(
                themeID: appState.selectedThemeID,
                params: effParams,
                seed: appState.seed,
                timeOfDayMode: appState.timeOfDayMode,
                customHour: appState.customHour,
                ambientCap: appState.ambientCap
            )
            if interactive {
                let obs = directoryResolver.items.map { IconObstacle(rect: $0.frame) } + cachedWidgetObstacles
                metalSceneView.updateObstacles(obs, liveDrag: false)
            } else {
                finderTracker.refreshObstacles(fallbackRects: directoryResolver.finderNativeRects)
            }
            metalSceneView.renderImmediateFrame()
        }
    }

    private func syncScreenGeometry() {
        guard let screen = NSScreen.primaryDesktop else { return }
        window.setFrame(screen.frame, display: true)
        let dockBottomInset = max(24.0, Float(screen.visibleFrame.minY - screen.frame.minY) + 14.0)
        metalSceneView.bottomInset = dockBottomInset
        metalSceneView.syncDrawableSize()
    }

    private func setupSystemObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.syncScreenGeometry()
                self.directoryResolver.reloadItems(screen: NSScreen.primaryDesktop)
            }
        }
        nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateOcclusionAndIdleState()
            }
        }

        let wsnc = NSWorkspace.shared.notificationCenter
        wsnc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateOcclusionAndIdleState()
            }
        }
        wsnc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateOcclusionAndIdleState()
            }
        }
        wsnc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isDisplayAsleep = true
                self?.evaluateOcclusionAndIdleState()
            }
        }
        wsnc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isDisplayAsleep = false
                self?.evaluateOcclusionAndIdleState()
                self?.metalSceneView.boostFrameRate(duration: 0.8)
            }
        }

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isScreenLocked = true
                self?.evaluateOcclusionAndIdleState()
            }
        }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isScreenLocked = false
                self?.evaluateOcclusionAndIdleState()
                self?.metalSceneView.boostFrameRate(duration: 0.8)
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.2, repeating: 1.0, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            self?.evaluateOcclusionAndIdleState()
        }
        timer.resume()
        self.coverageTimer = timer
    }

    private func noteDesktopInteraction() {
        interactionWakeUntil = CFAbsoluteTimeGetCurrent() + 6.0
        if metalSceneView.isSystemOccluded {
            evaluateOcclusionAndIdleState()
        }
    }

    func evaluateOcclusionAndIdleState() {
        let now = CFAbsoluteTimeGetCurrent()
        let occluded: Bool
        if isDisplayAsleep || isScreenLocked {
            occluded = true
        } else if now < interactionWakeUntil {
            occluded = false
        } else if now >= occlusionGraceUntil && !window.occlusionState.contains(.visible) {
            occluded = true
        } else {
            occluded = isDesktopCoveredByOpaqueWindows()
        }

        finderTracker.isEnabled = (appState.iconMode == .finderUnderlay) && !isDisplayAsleep && !isScreenLocked

        if metalSceneView.isSystemOccluded != occluded {
            metalSceneView.isSystemOccluded = occluded
            appState.telemetry.isIdleOccluded = occluded
            webThemeView?.sendPaused(appState.isManuallyPaused || occluded)
            if !occluded {
                metalSceneView.renderImmediateFrame()
                metalSceneView.boostFrameRate(duration: 0.5)
            }
        }
    }

    static let ignoredCoverageOwners: Set<String> = [
        "Dock",
        "Window Server",
        "WindowManager",
        "Control Center",
        "Notification Center",
        "SystemUIServer",
        "Spotlight",
        "Wallpaper",
        "loginwindow",
        "ScreenSaverEngine"
    ]

    func isDesktopCoveredByOpaqueWindows() -> Bool {
        guard let screen = window.screen ?? NSScreen.primaryDesktop else { return false }
        let vis = screen.visibleFrame
        let primaryH = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let visTopLeft = CGRect(
            x: vis.minX,
            y: primaryH - vis.maxY,
            width: vis.width,
            height: vis.height
        )
        let targetArea = visTopLeft.width * visTopLeft.height
        guard targetArea > 100 else { return false }

        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let liveWidgets = FinderIconTracker.widgetObstacles(
            from: FinderIconTracker.extractDesktopWidgetRects(from: infoList, screen: screen)
        )
        if liveWidgets != cachedWidgetObstacles {
            cachedWidgetObstacles = liveWidgets
            if appState.iconMode == .desklandInteractive && !desktopCanvasView.isCurrentlyDraggingItems {
                let obs = directoryResolver.items.map { IconObstacle(rect: $0.frame) } + liveWidgets
                pushObstaclesToActiveRenderer(obs, liveDrag: false)
            } else if appState.iconMode == .finderUnderlay {
                finderTracker.refreshObstacles(fallbackRects: directoryResolver.finderNativeRects)
            }
        }

        let gx = 32
        let gy = 20
        var covered = [Bool](repeating: false, count: gx * gy)
        var coveredCount = 0

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
                  alpha >= 0.95,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }
            if let owner = info[kCGWindowOwnerName as String] as? String,
               Self.ignoredCoverageOwners.contains(owner) {
                continue
            }
            let inter = rect.intersection(visTopLeft)
            if inter.isNull { continue }

            if (inter.width * inter.height) >= targetArea * 0.96 {
                return true
            }

            for iy in 0..<gy {
                let py = visTopLeft.minY + (CGFloat(iy) + 0.5) / CGFloat(gy) * visTopLeft.height
                if py < inter.minY || py > inter.maxY { continue }
                let rowBase = iy * gx
                for ix in 0..<gx {
                    let cellIdx = rowBase + ix
                    if covered[cellIdx] { continue }
                    let px = visTopLeft.minX + (CGFloat(ix) + 0.5) / CGFloat(gx) * visTopLeft.width
                    if px >= inter.minX && px <= inter.maxX {
                        covered[cellIdx] = true
                        coveredCount += 1
                    }
                }
            }
            if coveredCount >= Int(Double(gx * gy) * 0.94) {
                return true
            }
        }
        return false
    }
}
