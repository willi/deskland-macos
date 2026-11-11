import SwiftUI
import AppKit

@MainActor
final class DesklandAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let appState = AppState()
    private(set) var desktopController: DesktopWindowController?
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") {
            runSelfTestAndExit()
            return
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        desktopController = DesktopWindowController(appState: appState)
        appState.onOpenSettingsWindow = { [weak self] in
            self?.showSettingsWindow()
        }
        appState.onOpenAboutWindow = { [weak self] in
            self?.showAboutWindow()
        }

        if CommandLine.arguments.contains("--open-settings") {
            showSettingsWindow()
        }
        if CommandLine.arguments.contains("--open-about") {
            showAboutWindow()
        }

        if CommandLine.arguments.contains("--verify-live-window") {
            runLiveWindowVerification()
        }
    }

    private func runLiveWindowVerification() {
        guard desktopController != nil else { exit(1) }
        let savedMode = appState.iconMode
        appState.iconMode = .desklandInteractive
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, let dc = self.desktopController else { exit(1) }
            let f1 = dc.metalSceneView.totalPresentedFrames
            let finderRects = dc.directoryResolver.finderNativeRects
            let maxFinderX = finderRects.map(\.midX).max() ?? 0
            print("LIVE_INTERACTIVE frames=\(f1) finderCount=\(finderRects.count) maxFinderX=\(Int(maxFinderX))")

            self.appState.iconMode = .finderUnderlay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                guard let self, let dc = self.desktopController else { exit(1) }
                let f2 = dc.metalSceneView.totalPresentedFrames - f1
                dc.evaluateOcclusionAndIdleState()
                let coveredNow = dc.isDesktopCoveredByOpaqueWindows()
                let idleNow = dc.metalSceneView.isSystemOccluded
                let fBeforeIdleWait = dc.metalSceneView.totalPresentedFrames
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self, let dc = self.desktopController else { exit(1) }
                    let framesDuringIdle = dc.metalSceneView.totalPresentedFrames - fBeforeIdleWait
                    self.appState.iconMode = savedMode
                    self.appState.flushPendingSave()
                    print("LIVE_FINDER frames=\(f2) coveredNow=\(coveredNow) idleNow=\(idleNow) framesDuringIdle=\(framesDuringIdle)")
                    fflush(stdout)
                    exit(f1 >= 1 && f2 >= 1 ? 0 : 1)
                }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.flushPendingSave()
    }

    func showSettingsWindow() {
        if let win = settingsWindow {
            NSApplication.shared.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Deskland"
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = NSHostingView(rootView: SettingsView(appState: appState))
        self.settingsWindow = win

        NSApplication.shared.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func showAboutWindow() {
        if let win = aboutWindow {
            NSApplication.shared.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 284, height: 484),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "About Deskland"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.backgroundColor = AboutView.windowSurfaceColor
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = NSHostingView(rootView: AboutView(appState: appState))
        self.aboutWindow = win

        NSApplication.shared.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === settingsWindow {
            appState.showingSnapshotSheet = false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.settingsWindow === closing else { return }
                closing.contentView = nil
                self.settingsWindow = nil
            }
        } else if closing === aboutWindow {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.aboutWindow === closing else { return }
                closing.contentView = nil
                self.aboutWindow = nil
            }
        }
    }

    private func runSelfTestAndExit() {
        let shared = MetalSharedResources.shared
        let pipesOK = shared.device != nil &&
            shared.beachPipeline != nil &&
            shared.palmPipeline != nil &&
            shared.meadowPipeline != nil &&
            shared.meadowBoyPipeline != nil &&
            shared.forestPipeline != nil &&
            shared.noiseTex != nil

        let resolver = DesktopDirectoryResolver()
        let primaryScreen = NSScreen.primaryDesktop
        resolver.reloadItems(screen: primaryScreen)

        let snapFrame = primaryScreen?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let testView = MetalSceneView(frame: NSRect(origin: .zero, size: snapFrame.size), isPreview: false)
        if let s = primaryScreen {
            testView.bottomInset = max(24.0, Float(s.visibleFrame.minY - s.frame.minY) + 14.0)
        }
        let widgetObs = primaryScreen.map {
            FinderIconTracker.widgetObstacles(from: FinderIconTracker.queryDesktopWidgetRects(screen: $0))
        } ?? []
        let iconObs = resolver.items.isEmpty
            ? [IconObstacle(x: Float(snapFrame.width) - 160, y: 50, w: 84, h: 90), IconObstacle(x: Float(snapFrame.width) - 160, y: 150, w: 84, h: 90)]
            : resolver.items.map { IconObstacle(rect: $0.frame) }
        testView.updateObstacles(iconObs + widgetObs, liveDrag: false, instant: true)

        var dumpDir: URL?
        if let idx = CommandLine.arguments.firstIndex(of: "--dump-snapshots"), idx + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[idx + 1], isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            dumpDir = url
        }

        var renderedCount = 0
        let cases: [(String, TimeOfDayMode, String)] = [
            ("beach", .day, "beach-day.png"),
            ("beach", .sunset, "beach-sunset.png"),
            ("beach", .night, "beach-night.png"),
            ("meadow", .day, "meadow-day.png"),
            ("forest", .day, "forest-day.png")
        ]
        for (theme, tod, filename) in cases {
            testView.applyConfiguration(
                themeID: theme,
                params: appState.effectiveParams(for: theme),
                seed: 421337,
                timeOfDayMode: tod,
                customHour: 18.15,
                ambientCap: .balanced30
            )
            if let img = testView.renderPrivacySnapshot() {
                renderedCount += 1
                if let dumpDir,
                   let tiff = img.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: dumpDir.appendingPathComponent(filename))
                }
            }
        }

        if let dumpDir {
            appState.isUsingICloudDesktop = resolver.isUsingICloudDesktop
            let renderer = ImageRenderer(
                content: AboutView(appState: appState)
                    .environment(\.colorScheme, .light)
            )
            renderer.scale = 2.0
            if let nsImg = renderer.nsImage,
               let tiff = nsImg.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dumpDir.appendingPathComponent("about-window.png"))
            }
        }

        print("DESKLAND_SELFTEST pipes=\(pipesOK) rendered=\(renderedCount)/5 desktop=\(resolver.activeDesktopURL.path) icloud=\(resolver.isUsingICloudDesktop) items=\(resolver.items.count) themes=\(appState.themes.count)")
        fflush(stdout)
        exit(pipesOK && renderedCount == 5 ? 0 : 1)
    }
}

@main
struct DesklandApp: App {
    @NSApplicationDelegateAdaptor(DesklandAppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Deskland", systemImage: "water.waves") {
            MenuBarMenuView(
                appState: appDelegate.appState,
                openSettingsAction: { appDelegate.showSettingsWindow() },
                openAboutAction: { appDelegate.showAboutWindow() }
            )
        }
    }
}
