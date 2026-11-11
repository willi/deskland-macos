import SwiftUI
import AppKit

struct MetalPreviewRepresentable: NSViewRepresentable {
    var appState: AppState

    func makeNSView(context: Context) -> PreviewHostNSView {
        let view = PreviewHostNSView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: PreviewHostNSView, context: Context) {
        nsView.sync(with: appState)
    }
}

@MainActor
final class PreviewHostNSView: NSView {
    let metalView = MetalSceneView(frame: .zero, isPreview: true)
    private var webView: DesklandWebThemeView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        metalView.frame = bounds
        metalView.autoresizingMask = [.width, .height]
        addSubview(metalView)
        installSamplePreviewObstacles()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        installSamplePreviewObstacles()
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let topDownPt = CGPoint(x: pt.x, y: bounds.height - pt.y)
        metalView.triggerInteractionRipple(at: topDownPt, strength: 1.15)
    }

    private func installSamplePreviewObstacles() {
        let w = Float(max(320, bounds.width))
        let h = Float(max(180, bounds.height))
        let sample: [IconObstacle] = [
            IconObstacle(x: w - 68, y: 20, w: 46, h: 50),
            IconObstacle(x: w - 68, y: 76, w: 46, h: 50),
            IconObstacle(x: w - 68, y: 132, w: 46, h: 50),
            IconObstacle(x: w - 122, y: 20, w: 46, h: 50),
            IconObstacle(x: w - 122, y: 76, w: 46, h: 50),
            IconObstacle(x: 34, y: 28, w: 46, h: 50),
            IconObstacle(x: 86, y: 28, w: 46, h: 50),
            IconObstacle(x: 34, y: 84, w: 46, h: 50),
            IconObstacle(x: 138, y: h - 78, w: 46, h: 50)
        ]
        metalView.updateObstacles(sample, liveDrag: false, instant: true)
        webView?.sendObstacles(sample, bottomInset: 24)
    }

    func sync(with appState: AppState) {
        if let theme = appState.selectedTheme, !theme.isBuiltInMetal,
           let extFolder = theme.externalFolderPath, let page = theme.page {
            metalView.isManuallyPaused = true
            metalView.isHidden = true
            if webView == nil {
                let wv = DesklandWebThemeView(frame: bounds, isPreview: true)
                wv.autoresizingMask = [.width, .height]
                addSubview(wv)
                webView = wv
                installSamplePreviewObstacles()
            }
            webView?.loadExternalTheme(folderPath: extFolder, page: page)
            webView?.sendSettings(params: appState.effectiveParams(for: theme.id), seed: appState.seed)
        } else {
            if let wv = webView {
                wv.teardownWebView()
                wv.removeFromSuperview()
                webView = nil
            }
            metalView.isHidden = false
            metalView.isManuallyPaused = false
            metalView.applyConfiguration(
                themeID: appState.selectedThemeID,
                params: appState.effectiveParams(for: appState.selectedThemeID),
                seed: appState.seed,
                timeOfDayMode: appState.timeOfDayMode,
                customHour: appState.customHour,
                ambientCap: .balanced30
            )
        }
    }
}

private struct LiveTelemetryStatusRow: View {
    let telemetry: TelemetryState
    let isManuallyPaused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(telemetry.isIdleOccluded || isManuallyPaused ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
            if isManuallyPaused {
                Text("Paused (0% GPU)")
                    .font(.caption.weight(.medium))
            } else if telemetry.isIdleOccluded {
                Text("Idle — Desktop Covered (0 Hz)")
                    .font(.caption.weight(.medium))
            } else {
                Text("\(telemetry.roundedFPS) fps · Target \(telemetry.targetHz) Hz")
                    .font(.caption.monospacedDigit().weight(.medium))
            }
            Spacer()
        }
    }
}

struct SettingsView: View {
    @Bindable var appState: AppState

    var body: some View {
        NavigationSplitView {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 245, ideal: 265, max: 300)
        } detail: {
            detailContent
        }
        .frame(minWidth: 880, idealWidth: 960, minHeight: 620, idealHeight: 700)
        .sheet(isPresented: $appState.showingSnapshotSheet) {
            SnapshotPreviewSheet(appState: appState)
        }
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Deskland")
                        .font(.headline)
                    Text("Living Metal Desktop")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    appState.onOpenAboutWindow?()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("About Deskland")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    Text(appState.uiText("themes", fallback: "Scenery Themes"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.top, 6)

                    ForEach(appState.themes.filter(\.isReady)) { theme in
                        ThemeCardRow(
                            theme: theme,
                            thumbnail: appState.thumbnailImage(for: theme),
                            isSelected: appState.selectedThemeID == theme.id
                        ) {
                            appState.selectedThemeID = theme.id
                        }
                    }
                }
                .padding(12)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                LiveTelemetryStatusRow(
                    telemetry: appState.telemetry,
                    isManuallyPaused: appState.isManuallyPaused
                )

                HStack(spacing: 5) {
                    Image(systemName: appState.isUsingICloudDesktop ? "icloud.fill" : "folder.fill")
                        .font(.caption2)
                        .foregroundStyle(appState.isUsingICloudDesktop ? .cyan : .secondary)
                    Text(appState.isUsingICloudDesktop ? "iCloud Desktop (\(appState.desktopItemCount))" : "Local Desktop (\(appState.desktopItemCount))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }

                HStack(spacing: 6) {
                    Button {
                        chooseExternalDesklandFolder()
                    } label: {
                        Label(
                            appState.externalThemeFolder == nil ? "Load Wallpaper Folder…" : "Change Folder…",
                            systemImage: "folder.badge.plus"
                        )
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)

                    if appState.externalThemeFolder != nil {
                        Button(role: .destructive) {
                            appState.externalThemeFolder = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Unload external wallpaper folder")
                    }
                }
            }
            .padding(12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(8)
        }
    }

    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                previewHeroSection
                timeOfDaySection
                desktopAndPerformanceSection
                themeParametersSection
            }
            .padding(20)
        }
    }

    private var previewHeroSection: some View {
        ZStack(alignment: .bottom) {
            MetalPreviewRepresentable(appState: appState)
                .frame(height: 235)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                )

            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    if let theme = appState.selectedTheme {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(theme.name)
                                .font(.headline)
                            Text(theme.desc)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Button {
                        appState.randomizeSeed()
                    } label: {
                        Label(appState.uiText("refresh", fallback: "Refresh"), systemImage: "dice")
                    }
                    .buttonStyle(.glass)

                    Button {
                        appState.capturePrivacySnapshot()
                    } label: {
                        Label(appState.uiText("share", fallback: "Snapshot"), systemImage: "camera.aperture")
                    }
                    .buttonStyle(.glass)

                    Button {
                        appState.isManuallyPaused.toggle()
                    } label: {
                        Label(
                            appState.isManuallyPaused ? "Resume" : "Pause",
                            systemImage: appState.isManuallyPaused ? "play.fill" : "pause.fill"
                        )
                    }
                    .buttonStyle(.glassProminent)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(12)
        }
    }

    private var timeOfDaySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Dynamic Time-of-Day Colors", systemImage: "sun.and.horizon.fill")
                    .font(.headline)
                Spacer()
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    let solar = SolarState.evaluate(mode: appState.timeOfDayMode, customHour: appState.customHour)
                    Text(formatHour(Double(solar.hour)) + " · " + phaseDescription(for: solar.hour))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                timePresetButton("Dynamic", icon: "clock.arrow.2.circlepath", mode: .dynamic)
                timePresetButton("Dawn", icon: "sunrise.fill", mode: .dawn)
                timePresetButton("Day", icon: "sun.max.fill", mode: .day)
                timePresetButton("Sunset", icon: "sunset.fill", mode: .sunset)
                timePresetButton("Night", icon: "moon.stars.fill", mode: .night)
                timePresetButton("Scrub", icon: "slider.horizontal.below.sun.max", mode: .custom)
            }

            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .center) {
                    LinearGradient(
                        stops: [
                            .init(color: Color(red: 0.06, green: 0.14, blue: 0.30), location: 0.00),
                            .init(color: Color(red: 0.92, green: 0.66, blue: 0.58), location: 0.25),
                            .init(color: Color(red: 0.22, green: 0.80, blue: 0.83), location: 0.50),
                            .init(color: Color(red: 0.96, green: 0.46, blue: 0.34), location: 0.76),
                            .init(color: Color(red: 0.14, green: 0.22, blue: 0.44), location: 0.86),
                            .init(color: Color(red: 0.05, green: 0.12, blue: 0.28), location: 1.00)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(height: 8)
                    .clipShape(Capsule())
                    .allowsHitTesting(false)

                    Slider(
                        value: Binding(
                            get: {
                                if appState.timeOfDayMode == .custom {
                                    return appState.customHour
                                }
                                return Double(SolarState.evaluate(mode: appState.timeOfDayMode, customHour: appState.customHour).hour)
                            },
                            set: { newVal in
                                if appState.timeOfDayMode != .custom {
                                    appState.timeOfDayMode = .custom
                                }
                                appState.customHour = newVal
                            }
                        ),
                        in: 0...23.98
                    )
                }

                HStack {
                    Text("00:00 Night")
                    Spacer()
                    Text("06:00 Dawn")
                    Spacer()
                    Text("12:00 Day")
                    Spacer()
                    Text("18:15 Sunset")
                    Spacer()
                    Text("23:59")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func timePresetButton(_ title: String, icon: String, mode: TimeOfDayMode) -> some View {
        let active = (appState.timeOfDayMode == mode)
        let btn = Button {
            appState.timeOfDayMode = mode
        } label: {
            HStack(spacing: 4) {
                if active {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                } else {
                    Image(systemName: icon)
                }
                Text(title)
            }
            .font(.caption.weight(.medium))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        if active {
            btn.buttonStyle(.glassProminent)
        } else {
            btn.buttonStyle(.glass)
        }
    }

    private var desktopAndPerformanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Desktop Icons, iCloud & ProMotion", systemImage: "menubar.dock.rectangle")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Desktop Mode")
                        .foregroundStyle(.secondary)
                    Picker("", selection: $appState.iconMode) {
                        Text("120Hz Interactive Icons (Recommended)").tag(DesktopIconMode.desklandInteractive)
                        Text("Finder Native Icons Underlay").tag(DesktopIconMode.finderUnderlay)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                GridRow {
                    Text("Desktop Folder")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Picker("", selection: $appState.desktopSource) {
                            ForEach(DesktopSourcePreference.allCases) { pref in
                                Text(pref.label).tag(pref)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240)

                        Text(appState.activeDesktopPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                GridRow {
                    Text("Ambient Rate")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Picker("", selection: $appState.ambientCap) {
                            ForEach(AmbientFrameCap.allCases) { cap in
                                Text(cap.label).tag(cap)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 240)

                        Text("Auto-boosts to 120 Hz on drag/morph; 0 Hz when covered")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            HStack(spacing: 16) {
                if appState.iconMode == .desklandInteractive {
                    Toggle("Snap Icons to Grid", isOn: $appState.snapToGrid)
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    Button("Clean Up Icons") {
                        appState.onCleanUpDesktop?(.none)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: FinderIconTracker.isAccessibilityTrusted ? "checkmark.shield.fill" : "hand.raised.circle")
                            .foregroundStyle(FinderIconTracker.isAccessibilityTrusted ? .green : .secondary)
                        Text(
                            FinderIconTracker.isAccessibilityTrusted
                                ? "Live Finder AX drag tracking active"
                                : "Using zero-permission .DS_Store tracking"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if !FinderIconTracker.isAccessibilityTrusted {
                            Button("Enable Live Finder Drag…") {
                                FinderIconTracker.promptForAccessibilityIfNeeded()
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }
                    }
                }

                Spacer()

                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { appState.launchAtLogin },
                        set: { appState.setLaunchAtLogin($0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)

                Picker("Language", selection: $appState.languageCode) {
                    Text("Auto").tag("auto")
                    Text("EN").tag("en")
                    Text("中文").tag("zh-CN")
                }
                .frame(width: 135)
                .controlSize(.small)
            }
        }
        .padding(16)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var themeParametersSection: some View {
        if let theme = appState.selectedTheme, let groups = theme.groups, !groups.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Scenery Parameters — \(theme.name)", systemImage: "slider.horizontal.3")
                        .font(.headline)
                    Spacer()
                    Button(appState.uiText("resetAll", fallback: "Reset Defaults")) {
                        appState.resetAllParams(for: theme.id)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }

                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(group.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(group.params) { param in
                            ParameterRowView(appState: appState, themeID: theme.id, param: param)
                        }
                    }
                    .padding(14)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private func chooseExternalDesklandFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Deskland Wallpaper Folder (containing themes.json)"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            let manifest = url.appendingPathComponent("themes.json")
            let nested = url.appendingPathComponent("prototype/themes.json")
            if FileManager.default.fileExists(atPath: manifest.path) {
                appState.externalThemeFolder = url.path
            } else if FileManager.default.fileExists(atPath: nested.path) {
                appState.externalThemeFolder = url.appendingPathComponent("prototype").path
            } else {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "No Deskland themes found"
                alert.informativeText = "“\(url.lastPathComponent)” doesn’t contain a themes.json (or prototype/themes.json). Choose the Deskland wallpaper folder that includes it."
                alert.runModal()
            }
        }
    }

    private func formatHour(_ h: Double) -> String {
        let wrapped = ((h.truncatingRemainder(dividingBy: 24)) + 24).truncatingRemainder(dividingBy: 24)
        let hr = Int(wrapped)
        let mn = Int(((wrapped - Double(hr)) * 60).rounded()) % 60
        return String(format: "%02d:%02d", hr, mn)
    }

    private func phaseDescription(for h: Float) -> String {
        if h >= 5.0 && h < 7.4 { return "Rose-Gold Dawn" }
        if h >= 7.4 && h < 16.6 { return "Bright Daylight" }
        if h >= 16.6 && h < 19.3 { return "Crimson-Orange Sunset" }
        if h >= 19.3 && h < 20.6 { return "Blue Hour Twilight" }
        return "Moonlit Night"
    }
}

private struct ThemeCardRow: View {
    let theme: ThemeDefinition
    let thumbnail: NSImage?
    let isSelected: Bool
    var isLocked: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        LinearGradient(colors: [.teal.opacity(0.5), .blue.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                    if isLocked {
                        Color.black.opacity(0.35)
                        Image(systemName: "clock")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .frame(width: 66, height: 42)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(theme.name)
                            .font(.subheadline.weight(isSelected ? .semibold : .medium))
                            .lineLimit(1)
                        if theme.isBuiltInMetal {
                            Text("METAL")
                                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.cyan.opacity(0.22), in: Capsule())
                        }
                    }
                    Text(theme.desc)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(7)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.20) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 1.2)
            )
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .opacity(isLocked ? 0.62 : 1.0)
    }
}

private struct ParameterRowView: View {
    var appState: AppState
    let themeID: String
    let param: ThemeParam

    var body: some View {
        let current = appState.paramValue(for: param.key, in: themeID)
        let isModified = abs(current - param.default) > 1e-5

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(param.label)
                    .font(.callout.weight(.medium))
                if let hint = param.hint, !hint.isEmpty {
                    Text("· \(hint)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(param.formattedValue(current))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button {
                    appState.resetParam(param.key, in: themeID)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .opacity(isModified ? 0.9 : 0.2)
                .disabled(!isModified)
                .help("Reset to default (\(param.formattedValue(param.default)))")
            }

            if let opts = param.options, !opts.isEmpty {
                Picker(
                    "",
                    selection: Binding(
                        get: { Int(current.rounded()) },
                        set: { appState.setParam(param.key, value: Double($0), in: themeID) }
                    )
                ) {
                    ForEach(Array(opts.enumerated()), id: \.offset) { idx, label in
                        Text(label).tag(idx)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } else {
                let minV = param.min ?? 0
                let maxV = param.max ?? 100
                let stepV = param.step ?? 1
                Slider(
                    value: Binding(
                        get: { current },
                        set: { raw in
                            let stepped = (raw / stepV).rounded() * stepV
                            appState.setParam(param.key, value: min(maxV, max(minV, stepped)), in: themeID)
                        }
                    ),
                    in: minV...maxV
                )
            }
        }
    }
}

private struct SnapshotPreviewSheet: View {
    var appState: AppState
    @State private var savedBanner: String?

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Privacy-Safe Desktop Snapshot")
                        .font(.headline)
                    Text("Real filenames & thumbnails are replaced with anonymous sample icons.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    appState.showingSnapshotSheet = false
                }
                .buttonStyle(.glass)
            }

            if let img = appState.latestSnapshotImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 380)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(.white.opacity(0.2), lineWidth: 1)
                    )
            }

            HStack(spacing: 12) {
                if let savedBanner {
                    Text(savedBanner)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    appState.copySnapshotToClipboard()
                    savedBanner = "Copied to Clipboard!"
                } label: {
                    Label("Copy Image", systemImage: "doc.on.doc")
                }
                .buttonStyle(.glass)

                Button {
                    if let url = appState.saveSnapshotToPictures() {
                        savedBanner = "Saved to ~/Pictures/Deskland/\(url.lastPathComponent)"
                    }
                } label: {
                    Label("Save PNG", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(width: 680)
    }
}
