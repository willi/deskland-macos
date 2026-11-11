import Foundation
import AppKit
import Observation
import ServiceManagement
import os

let desklandLog = Logger(subsystem: "com.withsundae.deskland", category: "app")

struct PersistedSettings: Codable {
    var theme: String = "beach"
    var lang: String = "auto"
    var iconMode: DesktopIconMode = .desklandInteractive
    var desktopSource: DesktopSourcePreference = .auto
    var snapToGrid: Bool = false
    var timeOfDayMode: TimeOfDayMode = .dynamic
    var customHour: Double = 18.1
    var ambientCap: AmbientFrameCap = .balanced30
    var paused: Bool = false
    var seed: Int = 421337
    var params: [String: [String: Double]] = [:]
    var externalThemeFolder: String?
}

@Observable
@MainActor
final class TelemetryState {
    var roundedFPS: Int = 30
    var targetHz: Int = 30
    var isIdleOccluded: Bool = false

    func update(fps: Double, targetHz: Int, idle: Bool) {
        let r = Int(fps.rounded())
        if roundedFPS != r { roundedFPS = r }
        if self.targetHz != targetHz { self.targetHz = targetHz }
        if isIdleOccluded != idle { isIdleOccluded = idle }
    }
}

@Observable
@MainActor
final class AppState {
    var selectedThemeID: String = "beach" { didSet { saveAndSync() } }
    var languageCode: String = "auto" {
        didSet {
            guard !isInitializing else { return }
            reloadLocalization()
            scheduleSave()
        }
    }
    var iconMode: DesktopIconMode = .desklandInteractive { didSet { saveAndSync() } }
    var desktopSource: DesktopSourcePreference = .auto { didSet { saveAndSync() } }
    var snapToGrid: Bool = false { didSet { saveAndSync() } }
    var timeOfDayMode: TimeOfDayMode = .dynamic { didSet { saveAndSync() } }
    var customHour: Double = 18.1 { didSet { saveAndSync() } }
    var ambientCap: AmbientFrameCap = .balanced30 { didSet { saveAndSync() } }
    var isManuallyPaused: Bool = false { didSet { saveAndSync() } }
    var seed: Int = 421337 { didSet { saveAndSync() } }
    var themeParams: [String: [String: Double]] = [:]
    var externalThemeFolder: String? {
        didSet {
            guard !isInitializing else { return }
            reloadThemes()
            saveAndSync()
        }
    }

    private(set) var themes: [ThemeDefinition] = []
    private(set) var i18n = DesklandI18n()

    var activeDesktopPath: String = "~/Desktop"
    var isUsingICloudDesktop: Bool = false
    var desktopItemCount: Int = 0
    let telemetry = TelemetryState()
    var launchAtLogin: Bool = false

    var latestSnapshotImage: NSImage?
    var showingSnapshotSheet: Bool = false

    var onSyncScene: (() -> Void)?
    var onCleanUpDesktop: ((DesktopSortOrder) -> Void)?
    var onCaptureSnapshot: (() -> NSImage?)?
    var onOpenSettingsWindow: (() -> Void)?
    var onOpenAboutWindow: (() -> Void)?

    private let settingsURL: URL
    @ObservationIgnored private var isInitializing = true
    @ObservationIgnored private var pendingSaveWork: DispatchWorkItem?
    @ObservationIgnored private var thumbnailCache: [String: NSImage] = [:]

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Deskland", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        self.settingsURL = appSupport.appendingPathComponent("settings.json")

        loadSettings()
        reloadLocalization()
        reloadThemes()
        refreshLaunchAtLoginStatus()
        isInitializing = false
    }

    var selectedTheme: ThemeDefinition? {
        themes.first(where: { $0.id == selectedThemeID }) ?? themes.first
    }

    func effectiveParams(for themeID: String) -> [String: Double] {
        var result: [String: Double] = [:]
        if let def = themes.first(where: { $0.id == themeID }), let groups = def.groups {
            for g in groups {
                for p in g.params {
                    result[p.key] = p.default
                }
            }
        }
        if let overrides = themeParams[themeID] {
            for (k, v) in overrides {
                result[k] = v
            }
        }
        return result
    }

    func paramValue(for key: String, in themeID: String? = nil) -> Double {
        let tid = themeID ?? selectedThemeID
        if let v = themeParams[tid]?[key] {
            return v
        }
        if let def = themes.first(where: { $0.id == tid }),
           let groups = def.groups {
            for g in groups {
                if let p = g.params.first(where: { $0.key == key }) {
                    return p.default
                }
            }
        }
        return 0
    }

    func setParam(_ key: String, value: Double, in themeID: String? = nil) {
        let tid = themeID ?? selectedThemeID
        var dict = themeParams[tid] ?? [:]
        dict[key] = value
        themeParams[tid] = dict
        saveAndSync()
    }

    func resetParam(_ key: String, in themeID: String? = nil) {
        let tid = themeID ?? selectedThemeID
        themeParams[tid]?.removeValue(forKey: key)
        saveAndSync()
    }

    func resetAllParams(for themeID: String? = nil) {
        let tid = themeID ?? selectedThemeID
        themeParams.removeValue(forKey: tid)
        saveAndSync()
    }

    func randomizeSeed() {
        seed = Int.random(in: 100_000...999_999)
    }

    var resolvedLanguageCode: String {
        if languageCode != "auto" { return languageCode }
        let preferred = Locale.preferredLanguages.first ?? "en"
        return preferred.lowercased().hasPrefix("zh") ? "zh-CN" : "en"
    }

    func uiText(_ key: String, fallback: String) -> String {
        i18n.ui[key] ?? i18n.host[key] ?? fallback
    }

    func reloadLocalization() {
        let code = resolvedLanguageCode
        if let url = SpriteTextureLoader.resourceURL("i18n/\(code).json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(DesklandI18n.self, from: data) {
            self.i18n = decoded
        } else {
            self.i18n = DesklandI18n()
        }
        if !themes.isEmpty {
            reloadThemes()
        }
    }

    private static let externalThemeSuffix = " (HTML)"

    func reloadThemes() {
        var loaded: [ThemeDefinition] = []
        if let url = SpriteTextureLoader.resourceURL("themes.json"),
           let data = try? Data(contentsOf: url),
           let reg = try? JSONDecoder().decode(ThemeRegistry.self, from: data) {
            loaded = reg.themes
        }

        if let extFolder = externalThemeFolder {
            let extURL = URL(fileURLWithPath: extFolder).appendingPathComponent("themes.json")
            if let data = try? Data(contentsOf: extURL),
               let extReg = try? JSONDecoder().decode(ThemeRegistry.self, from: data) {
                for extTheme in extReg.themes where extTheme.status == "ready" {
                    let externalID = "ext:\(extTheme.id)"
                    let copy = ThemeDefinition(
                        id: externalID,
                        adaptive: extTheme.adaptive,
                        name: "\(extTheme.name)\(Self.externalThemeSuffix)",
                        desc: extTheme.desc,
                        page: extTheme.page,
                        renderer: "web",
                        status: "ready",
                        product: extTheme.product,
                        locked: false,
                        thumb: extTheme.thumb,
                        groups: extTheme.groups,
                        externalFolderPath: extFolder
                    )
                    loaded.insert(copy, at: min(3, loaded.count))
                }
            }
        }

        for idx in loaded.indices {
            let rawID = loaded[idx].externalFolderPath != nil
                ? String(loaded[idx].id.dropFirst("ext:".count))
                : loaded[idx].id
            guard let tr = i18n.themes[rawID] else { continue }
            if let name = tr.name {
                loaded[idx].name = loaded[idx].externalFolderPath != nil ? "\(name)\(Self.externalThemeSuffix)" : name
            }
            if let desc = tr.desc { loaded[idx].desc = desc }
            if var groups = loaded[idx].groups {
                for gIdx in groups.indices {
                    if let gNames = tr.groups, gIdx < gNames.count {
                        groups[gIdx].name = gNames[gIdx]
                    }
                    for pIdx in groups[gIdx].params.indices {
                        let pKey = groups[gIdx].params[pIdx].key
                        if let ptr = tr.params?[pKey] {
                            if let lbl = ptr.label { groups[gIdx].params[pIdx].label = lbl }
                            if let hnt = ptr.hint { groups[gIdx].params[pIdx].hint = hnt }
                            if let unt = ptr.unit { groups[gIdx].params[pIdx].unit = unt }
                            if let opts = ptr.options { groups[gIdx].params[pIdx].options = opts }
                        }
                    }
                }
                loaded[idx].groups = groups
            }
        }

        self.themes = loaded
        if !loaded.contains(where: { $0.id == selectedThemeID && $0.isReady }) {
            selectedThemeID = "beach"
        }
    }

    func thumbnailImage(for theme: ThemeDefinition) -> NSImage? {
        guard let thumb = theme.thumb else { return nil }
        let cacheKey = "\(theme.externalFolderPath ?? "<bundle>")|\(thumb)"
        if let cached = thumbnailCache[cacheKey] { return cached }

        var image: NSImage?
        if let extFolder = theme.externalFolderPath {
            let extURL = URL(fileURLWithPath: extFolder).appendingPathComponent(thumb)
            image = NSImage(contentsOf: extURL)
        }
        if image == nil, let url = SpriteTextureLoader.resourceURL(thumb) {
            image = NSImage(contentsOf: url)
        }
        if let image {
            thumbnailCache[cacheKey] = image
        }
        return image
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            desklandLog.error("Launch at Login update failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshLaunchAtLoginStatus()
    }

    func capturePrivacySnapshot() {
        guard let img = onCaptureSnapshot?() else { return }
        latestSnapshotImage = img
        showingSnapshotSheet = true
    }

    func copySnapshotToClipboard() {
        guard let img = latestSnapshotImage else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
    }

    @discardableResult
    func saveSnapshotToPictures() -> URL? {
        guard let img = latestSnapshotImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Deskland", isDirectory: true)
        try? FileManager.default.createDirectory(at: pics, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let safeThemeID = selectedThemeID.replacingOccurrences(of: ":", with: "-")
        let dst = pics.appendingPathComponent("Deskland-\(safeThemeID)-\(formatter.string(from: Date())).png")
        do {
            try png.write(to: dst, options: .atomic)
            return dst
        } catch {
            desklandLog.error("Saving snapshot failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func loadSettings() {
        guard let data = try? Data(contentsOf: settingsURL),
              let s = try? JSONDecoder().decode(PersistedSettings.self, from: data) else { return }
        selectedThemeID = s.theme
        languageCode = s.lang
        iconMode = s.iconMode
        desktopSource = s.desktopSource
        snapToGrid = s.snapToGrid
        timeOfDayMode = s.timeOfDayMode
        customHour = s.customHour
        ambientCap = s.ambientCap
        isManuallyPaused = s.paused
        seed = s.seed
        themeParams = s.params
        externalThemeFolder = s.externalThemeFolder
    }

    private func saveAndSync() {
        guard !isInitializing else { return }
        scheduleSave()
        onSyncScene?()
    }

    private func scheduleSave() {
        guard !isInitializing else { return }
        pendingSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.saveSettings()
            }
        }
        pendingSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func flushPendingSave() {
        guard pendingSaveWork != nil else { return }
        saveSettings()
    }

    func saveSettings() {
        guard !isInitializing else { return }
        pendingSaveWork?.cancel()
        pendingSaveWork = nil
        let s = PersistedSettings(
            theme: selectedThemeID,
            lang: languageCode,
            iconMode: iconMode,
            desktopSource: desktopSource,
            snapToGrid: snapToGrid,
            timeOfDayMode: timeOfDayMode,
            customHour: customHour,
            ambientCap: ambientCap,
            paused: isManuallyPaused,
            seed: seed,
            params: themeParams,
            externalThemeFolder: externalThemeFolder
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(s) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }
}
