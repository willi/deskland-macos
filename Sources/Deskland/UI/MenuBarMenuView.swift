import SwiftUI
import AppKit

struct MenuBarMenuView: View {
    @Bindable var appState: AppState
    let openSettingsAction: () -> Void
    let openAboutAction: () -> Void

    var body: some View {
        Text(statusSummary)
            .font(.caption)

        Divider()

        Picker("Theme", selection: $appState.selectedThemeID) {
            ForEach(appState.themes.filter(\.isReady)) { theme in
                Text(theme.name).tag(theme.id)
            }
        }

        Picker("Time of Day", selection: $appState.timeOfDayMode) {
            Text("Dynamic (Mac Clock)").tag(TimeOfDayMode.dynamic)
            Divider()
            Text("Dawn (06:00)").tag(TimeOfDayMode.dawn)
            Text("Daylight (12:00)").tag(TimeOfDayMode.day)
            Text("Sunset — Red & Orange (18:15)").tag(TimeOfDayMode.sunset)
            Text("Night — Moonlit Blue (23:00)").tag(TimeOfDayMode.night)
            if appState.timeOfDayMode == .custom {
                Divider()
                Text("Custom Solar Hour").tag(TimeOfDayMode.custom)
            }
        }

        Menu("Desktop Icons Mode") {
            Picker("Desktop Icons Mode", selection: $appState.iconMode) {
                Text("120Hz Interactive Desktop & Icons").tag(DesktopIconMode.desklandInteractive)
                Text("Finder Native Icons Underlay").tag(DesktopIconMode.finderUnderlay)
            }
            .pickerStyle(.inline)
            .labelsHidden()

            if appState.iconMode == .desklandInteractive {
                Divider()
                Toggle("Snap Icons to Grid", isOn: $appState.snapToGrid)
                Button("Clean Up Icons") {
                    appState.onCleanUpDesktop?(.none)
                }
            }
        }

        Divider()

        Button {
            appState.randomizeSeed()
        } label: {
            Label("Refresh Scenery", systemImage: "dice")
        }

        Button {
            appState.isManuallyPaused.toggle()
        } label: {
            Label(
                appState.isManuallyPaused ? "Resume Animation" : "Pause Animation",
                systemImage: appState.isManuallyPaused ? "play.fill" : "pause.fill"
            )
        }

        Button {
            if let img = appState.onCaptureSnapshot?() {
                appState.latestSnapshotImage = img
                appState.copySnapshotToClipboard()
            }
        } label: {
            Label("Copy Privacy Snapshot", systemImage: "camera.aperture")
        }

        Divider()

        Toggle(
            "Launch at Login",
            isOn: Binding(
                get: { appState.launchAtLogin },
                set: { appState.setLaunchAtLogin($0) }
            )
        )

        Button("About Deskland") {
            openAboutAction()
        }

        Button("Deskland Settings…") {
            openSettingsAction()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Deskland") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private var statusSummary: String {
        let desktopKind = appState.isUsingICloudDesktop ? "iCloud Desktop" : "Local Desktop"
        if appState.isManuallyPaused {
            return "Paused · \(desktopKind)"
        }
        let themeName = appState.selectedTheme?.name ?? "Deskland"
        return "\(themeName) · \(desktopKind)"
    }
}
