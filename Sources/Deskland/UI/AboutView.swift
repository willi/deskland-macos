import SwiftUI
import AppKit
import Metal

struct AboutView: View {
    var appState: AppState

    static let githubURL = URL(string: "https://github.com/willi/deskland-macos")!
    static let inspirationURL = URL(string: "https://github.com/BLEZZ0102/Deskland")!

    @State private var isHoveringButton = false
    @State private var isHoveringLink = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(height: 44)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 132, height: 132)

            Spacer()
                .frame(height: 20)

            Text("Deskland")
                .font(.system(size: 23, weight: .bold))
                .foregroundStyle(.primary)

            Spacer()
                .frame(height: 3)

            Text(versionSubtitle)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)

            Spacer()
                .frame(height: 20)

            Grid(horizontalSpacing: 12, verticalSpacing: 5) {
                specRow(label: "Engine", value: "Native Metal")
                specRow(label: "Chip", value: gpuName)
                specRow(label: "Refresh rate", value: refreshRateSummary)
                specRow(label: "Desktop", value: appState.isUsingICloudDesktop ? "iCloud Desktop" : "Local Desktop")
                specRow(label: "macOS", value: macOSVersionString)
            }

            Spacer()
                .frame(height: 22)

            Button {
                NSWorkspace.shared.open(Self.githubURL)
            } label: {
                Text("GitHub Project…")
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 5.5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(isHoveringButton ? 0.12 : 0.075))
                    )
            }
            .buttonStyle(.plain)
            .pointerStyle(.link)
            .onHover { hovering in
                isHoveringButton = hovering
            }

            Spacer(minLength: 18)

            VStack(spacing: 4) {
                Button {
                    NSWorkspace.shared.open(Self.githubURL)
                } label: {
                    Text("github.com/willi/deskland-macos")
                        .font(.system(size: 11))
                        .underline()
                        .foregroundStyle(isHoveringLink ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .onHover { hovering in
                    isHoveringLink = hovering
                }

                Button {
                    NSWorkspace.shared.open(Self.inspirationURL)
                } label: {
                    Text("Inspired by BLEZZ0102/Deskland")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.85))
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
            }
            .multilineTextAlignment(.center)
            .padding(.bottom, 24)
        }
        .padding(.horizontal, 24)
        .frame(width: 284, height: 484)
        .background(Color(nsColor: Self.windowSurfaceColor))
    }

    @ViewBuilder
    private func specRow(label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(.primary.opacity(0.85))
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(.system(size: 11.5, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .gridColumnAlignment(.leading)
        }
    }

    private var versionSubtitle: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        return "Version \(short)"
    }

    private var gpuName: String {
        MetalSharedResources.shared.device?.name ?? MTLCreateSystemDefaultDevice()?.name ?? "Apple Silicon"
    }

    private var refreshRateSummary: String {
        let maxFPS = NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 120
        return maxFPS >= 120 ? "ProMotion \(maxFPS) Hz" : "Up to \(maxFPS) Hz"
    }

    private var macOSVersionString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        if v.patchVersion > 0 {
            return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        }
        return "\(v.majorVersion).\(v.minorVersion)"
    }

    static var windowSurfaceColor: NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if isDark {
                return NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.16, alpha: 1.0)
            } else {
                return NSColor(calibratedWhite: 0.985, alpha: 1.0)
            }
        }
    }
}
