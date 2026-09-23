import CLIStateDomain
import SwiftUI

/// What the leftover review sheet is for: uninstalling one installation plus
/// cleanup, or cleanup alone (a tool that stays installed).
struct LeftoverReview: Identifiable, Hashable {
    enum Mode: Hashable {
        case uninstall(InstallationRef)
        case cleanUp
    }

    var toolID: ToolID
    var mode: Mode

    var id: String {
        switch mode {
        case let .uninstall(ref): "uninstall:\(ref.installationID.rawValue)"
        case .cleanUp: "cleanup:\(toolID.rawValue)"
        }
    }
}

extension View {
    /// Presents `AppModel.leftoverReview`. The follow-up confirmation sheet opens
    /// only after this one has fully dismissed.
    func leftoverReviewSheet() -> some View {
        modifier(LeftoverReviewPresenter())
    }
}

private struct LeftoverReviewPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var afterDismiss: (@MainActor () -> Void)?

    func body(content: Content) -> some View {
        @Bindable var model = model
        content.sheet(item: $model.leftoverReview, onDismiss: {
            afterDismiss?()
            afterDismiss = nil
        }) { review in
            LeftoverCleanupSheet(review: review) { action in
                afterDismiss = action
                model.leftoverReview = nil
            }
            .environment(\.homeDirectory, model.homeDirectory)
            .buttonStyle(.dsSecondary)
        }
    }
}

/// Lists a tool's leftover files by kind with sizes and checkboxes, then hands
/// the selection to the normal plan → preflight → confirmation flow.
struct LeftoverCleanupSheet: View {
    let review: LeftoverReview
    /// Closes the sheet and runs the action after it's gone.
    let finish: (@escaping @MainActor () -> Void) -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var items: [LeftoverItem]?
    @State private var selection: Set<String> = []

    private var tool: Tool? { model.snapshot?.tool(review.toolID) }
    private var name: String { tool?.identity.displayName ?? review.toolID.rawValue }

    private var installation: ToolInstallation? {
        guard case let .uninstall(ref) = review.mode else { return nil }
        return tool?.installation(ref.installationID)
    }

    private var selectedItems: [LeftoverItem] {
        (items ?? []).filter { selection.contains($0.path) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(DS.Space.s6)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s6) {
                    if let installation {
                        installationSection(installation)
                    }
                    leftoverSection
                }
                .padding(DS.Space.s6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: DS.Layout.sheetMaxBodyHeight)
            .background(DS.Palette.panelSecondary)
            Divider()
            footer
                .padding(DS.Space.s4)
        }
        .frame(width: DS.Layout.sheetWidth)
        .background(DS.Palette.panelPrimary)
        .task(id: review) {
            let found = await model.leftovers(for: review.toolID)
            selection = Set(found.filter { !$0.containsUserData }.map(\.path))
            items = found
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Space.s3) {
            Image(systemName: installation == nil ? Symbol.cleanup : Symbol.needsAttention)
                .font(DS.Font.largeTitle)
                .foregroundStyle(installation == nil ? DS.Palette.highlight : DS.Palette.error)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                Text(installation == nil ? LeftoverText.cleanUpTitle(name) : LeftoverText.uninstallTitle(name))
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(installation.map { LeftoverText.uninstallExplanation(name: name, provider: $0.ownership.provider.displayName) } ?? LeftoverText.cleanUpExplanation)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func installationSection(_ installation: ToolInstallation) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Text(LeftoverText.installationHeading)
                .font(DS.Font.captionEmphasis)
                .foregroundStyle(DS.Palette.textSecondary)
            HStack(spacing: DS.Space.s2) {
                InstalledViaLabel(provider: installation.ownership.provider, font: DS.Font.bodyEmphasis)
                if let package = installation.ownership.packageName {
                    Text(package)
                        .font(DS.Font.mono)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer()
                Text(installation.versionText)
                    .font(DS.Font.monoBody)
                    .foregroundStyle(DS.Palette.textPrimary)
            }
            .dsWell()
        }
    }

    // MARK: Leftovers

    @ViewBuilder
    private var leftoverSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            Text(LeftoverText.filesHeading)
                .font(DS.Font.captionEmphasis)
                .foregroundStyle(DS.Palette.textSecondary)
            if let items {
                if items.isEmpty {
                    IconText(symbol: Symbol.good, text: LeftoverText.nothingFound, tint: DS.Palette.success, textColor: DS.Palette.textPrimary)
                } else {
                    ForEach(LeftoverKind.allCases, id: \.self) { kind in
                        let group = items.filter { $0.kind == kind }
                        if !group.isEmpty {
                            LeftoverGroup(kind: kind, items: group, selection: $selection)
                        }
                    }
                }
            } else {
                HStack(spacing: DS.Space.s2) {
                    ProgressView()
                        .controlSize(.small)
                    Text(LeftoverText.searching)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: DS.Space.s3) {
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                if !selectedItems.isEmpty {
                    Text(LeftoverText.reclaim(LeftoverText.size(selectedItems.reduce(0) { $0 + $1.sizeBytes }, lowerBound: selectedItems.contains(where: \.sizeIsLowerBound))))
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Palette.textPrimary)
                }
                IconText(symbol: Symbol.trash, text: LeftoverText.trashNote, tint: DS.Palette.textSecondary, font: DS.Font.caption)
            }
            Spacer()
            Button(String(localized: "Cancel", table: "Tools"), role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button(String(localized: "Continue", table: "Tools"), role: .destructive) {
                proceed()
            }
            .buttonStyle(.dsDestructive)
            .keyboardShortcut(.defaultAction)
            .disabled(!canContinue)
        }
    }

    private var canContinue: Bool {
        guard items != nil, !model.isPreparingOperation else { return false }
        return installation != nil || !selection.isEmpty
    }

    private func proceed() {
        // Keep the scanner's order; the Application layer re-checks every path.
        let paths = selectedItems.map(\.path)
        let model = self.model
        switch review.mode {
        case let .uninstall(ref):
            finish { model.requestUninstall(ref, leftovers: paths) }
        case .cleanUp:
            let toolID = review.toolID
            finish { model.requestCleanLeftovers(tool: toolID, paths: paths) }
        }
    }
}

private struct LeftoverGroup: View {
    let kind: LeftoverKind
    let items: [LeftoverItem]
    @Binding var selection: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: kind.symbol)
                    .font(DS.Font.inlineIcon)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(width: DS.IconSize.inline, height: DS.IconSize.inline)
                    .accessibilityHidden(true)
                Text(kind.title)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Palette.textPrimary)
                Spacer()
                Text(LeftoverText.size(items.reduce(0) { $0 + $1.sizeBytes }, lowerBound: items.contains(where: \.sizeIsLowerBound)))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            if kind.containsUserData {
                IconText(symbol: Symbol.needsAttention, text: LeftoverText.userDataWarning, tint: DS.Palette.warning, textColor: DS.Palette.textPrimary, font: DS.Font.caption)
            }
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                ForEach(items) { item in
                    HStack(spacing: DS.Space.s2) {
                        Toggle(isOn: binding(for: item.path)) {
                            PathText(path: item.path, font: DS.Font.monoBody)
                                .help(item.path)
                        }
                        .toggleStyle(.checkbox)
                        Spacer(minLength: DS.Space.s2)
                        Text(LeftoverText.size(item.sizeBytes, lowerBound: item.sizeIsLowerBound))
                            .font(DS.Font.mono)
                            .foregroundStyle(DS.Palette.textSecondary)
                            .fixedSize()
                    }
                }
            }
            .dsWell()
        }
    }

    private func binding(for path: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(path) },
            set: { isOn in
                if isOn { selection.insert(path) } else { selection.remove(path) }
            }
        )
    }
}

extension LeftoverKind {
    var title: String {
        switch self {
        case .cache: String(localized: "Caches", table: "Tools")
        case .logs: String(localized: "Logs", table: "Tools")
        case .state: String(localized: "State", table: "Tools")
        case .config: String(localized: "Settings", table: "Tools")
        case .data: String(localized: "Data and History", table: "Tools")
        }
    }

    var symbol: String {
        switch self {
        case .cache: "internaldrive"
        case .logs: "doc.plaintext"
        case .state: "clock"
        case .config: Symbol.config
        case .data: "person.crop.circle"
        }
    }
}

enum LeftoverText {
    static var installationHeading: String { String(localized: "Uninstall", table: "Tools") }
    static var filesHeading: String { String(localized: "Leftover files", table: "Tools") }
    static var searching: String { String(localized: "Looking for leftover files…", table: "Tools") }
    static var nothingFound: String { String(localized: "No leftover files found.", table: "Tools") }
    static var userDataWarning: String { String(localized: "Contains your settings or history", table: "Tools") }
    static var trashNote: String { String(localized: "Files are moved to the Trash, so you can put them back.", table: "Tools") }
    static var cleanUpExplanation: String {
        String(localized: "Files this tool left in your home folder. Caches and logs are selected; settings and history are not.", table: "Tools")
    }

    static func uninstallTitle(_ name: String) -> String {
        String(localized: "Uninstall and Clean Up \(name)", table: "Tools")
    }

    static func cleanUpTitle(_ name: String) -> String {
        String(localized: "Clean Up \(name) Leftovers", table: "Tools")
    }

    static func uninstallExplanation(name: String, provider: String) -> String {
        String(localized: "\(provider) uninstalls \(name) first, then the files you select are moved to the Trash.", table: "Tools")
    }

    static func reclaim(_ size: String) -> String {
        String(localized: "Frees \(size)", table: "Tools")
    }

    static func size(_ bytes: Int64, lowerBound: Bool) -> String {
        let text = bytes.formatted(.byteCount(style: .file))
        return lowerBound ? String(localized: "At least \(text)", table: "Tools") : text
    }
}
