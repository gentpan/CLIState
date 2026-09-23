import CLIStateApplication
import CLIStateDomain
import SwiftUI

/// The menu bar extra's window: status, counts, the first few updates and app actions.
struct MenuBarContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let digest = model.environmentDigest
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, DS.Space.s4)
                .padding(.top, DS.Space.s4)
                .padding(.bottom, DS.Space.s3)
            summary(digest)
                .padding(.horizontal, DS.Space.s4)
                .padding(.bottom, DS.Space.s4)
            MenuSeparator()
            updates(digest)
            MenuSeparator()
            footer
                .padding(.horizontal, DS.Space.s2)
                .padding(.vertical, DS.Space.s3)
        }
        .frame(width: MenuBarLayout.width)
        // The menu bar window sizes itself to the content's minimum height, which
        // would squeeze rows with a minimum-height frame; ask for the ideal height.
        .fixedSize(horizontal: false, vertical: true)
        .background(DS.Palette.background)
        .tint(DS.Palette.primary)
    }

    // MARK: Header

    /// Logo and name on one line with the scan status after a status dot, then
    /// force refresh and Settings on the right (user layout).
    private var header: some View {
        HStack(spacing: DS.Space.s2) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: MenuBarLayout.logoSize, height: MenuBarLayout.logoSize)
                .accessibilityHidden(true)
            Text(verbatim: "CLI State")
                .font(DS.Font.headline)
                .foregroundStyle(DS.Palette.textPrimary)
                .fixedSize()
            TimelineView(.periodic(from: .now, by: MenuBarLayout.relativeTimeInterval)) { context in
                HStack(spacing: DS.Space.s2) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: MenuBarLayout.statusDotSize, height: MenuBarLayout.statusDotSize)
                        .accessibilityHidden(true)
                    Text(MenuBarText.status(
                        scanState: model.scanState,
                        isOperationRunning: model.isOperationRunning,
                        capturedAt: model.snapshot?.capturedAt,
                        now: context.date
                    ))
                    .font(DS.Font.caption)
                    .foregroundStyle(model.scanState == .failed ? DS.Palette.warning : DS.Palette.textSecondary)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: DS.Space.s2)
            if model.isScanning || model.isOperationRunning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Scanning…", tableName: "MenuBar"))
            } else {
                IconButton(title: Text("Refresh package info and check for updates", tableName: "MenuBar"), symbol: Symbol.refresh) {
                    Task { await model.forceCheckForUpdates() }
                }
            }
            IconButton(title: Text("Settings…", tableName: "MenuBar"), symbol: Symbol.settings) {
                openSettings.bringToFront()
                dismiss()
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Green when the last scan is fine, blue while working, orange after a failure.
    private var statusDotColor: Color {
        if model.scanState == .failed { return DS.Palette.warning }
        if model.isScanning || model.isOperationRunning { return DS.Palette.highlight }
        return DS.Palette.success
    }

    // MARK: Summary

    private func summary(_ digest: EnvironmentDigest) -> some View {
        HStack(spacing: DS.Space.s2) {
            SummaryTile(
                title: Text("Updates Available", tableName: "MenuBar"),
                symbol: Symbol.updateAvailable,
                tint: digest.updates.isEmpty ? DS.Palette.textSecondary : DS.Palette.highlight,
                count: digest.updates.count,
                detail: nil
            ) {
                open(.updates)
            }
            SummaryTile(
                title: Text("Issues", tableName: "MenuBar"),
                symbol: digest.issues.total == 0 ? Symbol.good : Symbol.needsAttention,
                tint: digest.issues.worst?.menuTint ?? DS.Palette.success,
                count: digest.issues.total,
                detail: digest.issues.breakdown.first.map(MenuBarText.severityCount)
            ) {
                open(.issues)
            }
        }
    }

    // MARK: Updates

    @ViewBuilder
    private func updates(_ digest: EnvironmentDigest) -> some View {
        let top = digest.topUpdates(limit: MenuBarLayout.updateLimit)
        VStack(alignment: .leading, spacing: 0) {
            if model.snapshot == nil {
                IconText(symbol: Symbol.unknown, text: String(localized: "Waiting for the first scan…", table: "MenuBar"), tint: DS.Palette.textSecondary, font: DS.Font.body)
                    .padding(DS.Space.s4)
            } else if top.shown.isEmpty {
                IconText(symbol: Symbol.latest, text: String(localized: "All tools are up to date", table: "MenuBar"), tint: DS.Palette.success, textColor: DS.Palette.textSecondary, font: DS.Font.body)
                    .padding(DS.Space.s4)
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text("Updates", tableName: "MenuBar")
                        .font(DS.Font.captionEmphasis)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if top.remaining > 0 {
                        Button {
                            open(.updates)
                        } label: {
                            Text("Show All \(digest.updates.count)", tableName: "MenuBar")
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Palette.highlight)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, DS.Space.s4)
                .padding(.top, DS.Space.s3)
                .padding(.bottom, DS.Space.s2)
                VStack(spacing: 0) {
                    ForEach(top.shown) { update in
                        UpdateRow(update: update) {
                            open(.tool(update.toolID))
                        }
                    }
                }
                .padding(.horizontal, DS.Space.s2)
                Button {
                    open(.updates)
                    model.requestUpdateAll()
                } label: {
                    Label {
                        Text("Update All…", tableName: "MenuBar")
                    } icon: {
                        Image(systemName: Symbol.update)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.dsPrimary)
                .disabled(!digest.hasUpdatableItems || model.isPreparingOperation)
                .help(Text("Review the updates in CLI State before anything runs", tableName: "MenuBar"))
                .padding(.horizontal, DS.Space.s4)
                .padding(.top, DS.Space.s3)
                .padding(.bottom, DS.Space.s4)
            }
        }
    }

    // MARK: Footer

    /// The panel stays up when another window of this app becomes key, so it closes itself.
    private func open(_ route: AppRoute?) {
        AppServices.shared.showMainWindow(route: route)
        dismiss()
    }

    private var footer: some View {
        HStack(spacing: DS.Space.s1) {
            FooterButton(title: Text("Scan Now", tableName: "MenuBar"), symbol: Symbol.refresh) {
                Task { await model.refresh() }
            }
            .disabled(model.isScanning)
            FooterButton(title: Text("Check for Updates", tableName: "MenuBar"), symbol: Symbol.updates) {
                Task { await model.checkForUpdates() }
            }
            .disabled(model.isScanning)
            Spacer(minLength: DS.Space.s2)
            IconButton(title: Text("Open CLI State", tableName: "MenuBar"), symbol: MenuBarSymbol.open) {
                open(nil)
            }
            IconButton(title: Text("Quit CLI State", tableName: "MenuBar"), symbol: MenuBarSymbol.quit) {
                NSApp.terminate(nil)
            }
        }
    }
}

// MARK: - Rows

private struct MenuSeparator: View {
    var body: some View {
        Rectangle()
            .fill(DS.Palette.border)
            .frame(height: DS.Stroke.hairline)
            .accessibilityHidden(true)
    }
}

/// Full-width plain button with a hover fill, like a menu item.
private struct HoverRow<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            label
        }
        .buttonStyle(MenuRowButtonStyle())
    }
}

private struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRow(configuration: configuration)
    }

    private struct MenuRow: View {
        let configuration: Configuration
        @State private var isHovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .padding(.horizontal, DS.Space.s2)
                .padding(.vertical, DS.Space.s1)
                .frame(minHeight: DS.ControlHeight.regular, alignment: .leading)
                .background(fill, in: RoundedRectangle(cornerRadius: DS.Radius.base))
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : DS.Opacity.disabled)
                .onHover { isHovered = $0 }
        }

        private var fill: Color {
            guard isEnabled else { return .clear }
            if configuration.isPressed { return DS.Palette.border }
            return isHovered ? DS.Palette.panelSecondary : .clear
        }
    }
}

/// Count with a label, e.g. "Updates Available 24"; opens the matching page.
private struct SummaryTile: View {
    let title: Text
    let symbol: String
    let tint: Color
    let count: Int
    let detail: String?
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                HStack(spacing: DS.Space.s1) {
                    Image(systemName: symbol)
                        .font(DS.Font.inlineIcon)
                        .foregroundStyle(tint)
                        .frame(width: DS.IconSize.inline, height: DS.IconSize.inline)
                        .accessibilityHidden(true)
                    title
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .lineLimit(1)
                }
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                    Text(count, format: .number)
                        .font(DS.Font.title)
                        .monospacedDigit()
                        .foregroundStyle(DS.Palette.textPrimary)
                    if let detail {
                        Text(detail)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(DS.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? DS.Palette.panelSecondary : DS.Palette.panelPrimary, in: RoundedRectangle(cornerRadius: DS.Radius.base))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.base).strokeBorder(DS.Palette.border, lineWidth: DS.Stroke.hairline))
            .contentShape(RoundedRectangle(cornerRadius: DS.Radius.base))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
    }
}

/// One line per update: installer icon, name, and the version change.
private struct UpdateRow: View {
    let update: EnvironmentDigest.Update
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: Symbol.provider(update.provider))
                    .font(DS.Font.inlineIcon)
                    .foregroundStyle(DS.Palette.textTertiary)
                    .frame(width: DS.IconSize.inline, height: DS.IconSize.inline)
                    .help(Text("Installed via \(update.provider.displayName)"))
                    .accessibilityLabel(Text("Installed via \(update.provider.displayName)"))
                Text(update.name)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: DS.Space.s3)
                HStack(spacing: DS.Space.s1) {
                    Text(update.installedVersion ?? "—")
                        .foregroundStyle(DS.Palette.textTertiary)
                    Image(systemName: Symbol.arrowRight)
                        .foregroundStyle(DS.Palette.textTertiary)
                        .accessibilityHidden(true)
                    Text(update.latestVersion ?? "—")
                        .foregroundStyle(DS.Palette.highlight)
                }
                .font(DS.Font.mono)
                .lineLimit(1)
                .fixedSize()
            }
            .frame(minHeight: MenuBarLayout.updateRowHeight)
        }
        .help(Text("Show \(update.name) in CLI State", tableName: "MenuBar"))
    }
}

/// Text button in the footer, e.g. "Scan Now".
private struct FooterButton: View {
    let title: Text
    let symbol: String
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) {
            Label {
                title.font(DS.Font.body)
            } icon: {
                Image(systemName: symbol).font(DS.Font.inlineIcon)
            }
            .foregroundStyle(DS.Palette.textPrimary)
            .fixedSize()
        }
        .fixedSize()
    }
}

/// Icon-only button with a tooltip, e.g. Settings and Quit.
private struct IconButton: View {
    let title: Text
    let symbol: String
    let action: () -> Void

    var body: some View {
        HoverRow(action: action) {
            Image(systemName: symbol)
                .font(DS.Font.inlineIcon)
                .foregroundStyle(DS.Palette.textSecondary)
                .frame(width: DS.IconSize.inline, height: DS.IconSize.inline)
        }
        .fixedSize()
        .help(title)
        .accessibilityLabel(title)
    }
}
