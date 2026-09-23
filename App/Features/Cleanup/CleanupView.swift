import CLIStateDomain
import SwiftUI

struct CleanupView: View {
    @Environment(AppModel.self) private var model
    @State private var isPreviewing = false
    @State private var filter = CleanupFilter.all
    @State private var query = ""

    private var candidates: [CleanupCandidate] { model.snapshot?.cleanupCandidates ?? [] }
    private var actionable: [CleanupCandidate] { candidates.filter { $0.plan != nil } }
    private var busy: Bool { isPreviewing || model.isScanning || model.isPreparingOperation || model.isOperationRunning || model.isRefreshingMetadata }
    private var visible: [CleanupCandidate] {
        candidates.filter { candidate in
            let matchesFilter = filter == .all || (filter == .actionable ? candidate.plan != nil : candidate.plan == nil)
            let text = ([candidate.kind.title(provider: candidate.providerID), candidate.providerID?.displayName ?? ""] + candidate.paths + candidate.items.map(\.name)).joined(separator: " ")
            return matchesFilter && (query.isEmpty || text.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if candidates.isEmpty && isPreviewing {
                ProgressView("Previewing cleanup…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if visible.isEmpty {
                VStack(spacing: DS.Space.s3) {
                    Image(systemName: candidates.isEmpty ? Symbol.good : Symbol.cleanup)
                        .font(DS.Font.standaloneIcon).foregroundStyle(DS.Palette.textSecondary)
                    Text(candidates.isEmpty ? "No cleanup items available" : "No matching cleanup items").font(DS.Font.headline)
                    Text(candidates.isEmpty ? "The current preview has no cleanup items. Environment issues may still need separate handling." : "Refresh the preview or change the filter to see available items.")
                        .font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary)
                    if candidates.isEmpty, !model.issues.isEmpty {
                        Button("Review remaining issues") { model.route = .issues }.buttonStyle(.dsSecondary)
                    }
                }
                .frame(maxWidth: .infinity).padding(DS.Space.s8)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(CleanupGroup.grouping(visible)) { group in
                            if group.candidates.count == 1, let candidate = group.candidates.first {
                                CleanupCard(candidate: candidate)
                            } else {
                                CleanupPathsCard(group: group)
                            }
                            Divider()
                        }
                    }
                    .padding(.horizontal, DS.Space.s6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DS.Palette.background)
        .dsPageTitle(Text("Cleanup"), symbol: Symbol.cleanup)
        .task { await refresh() }
    }

    private var header: some View {
        VStack(spacing: 0) {
            DSWorklistHeader(Text("Cleanup preview"), symbol: Symbol.cleanup) {
                Text("Review what can be removed before making changes.")
            } actions: {
                HStack(spacing: DS.Space.s2) {
                    if isPreviewing { ProgressView().controlSize(.small) }
                    Button("Refresh preview") { Task { await refresh() } }.disabled(busy)
                }
            }
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Space.s6) { metrics }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: DS.Space.s1) { metrics }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Space.s4) { tabs; search }
                    VStack(alignment: .leading, spacing: DS.Space.s2) { tabs; search }
                }
            }
            .padding(.horizontal, DS.Space.s4)
            .padding(.vertical, DS.Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.background)
            .overlay(alignment: .bottom) {
                Rectangle().fill(DS.Palette.border).frame(height: DS.Stroke.hairline)
            }
        }
    }

    private var measuredSpace: String {
        let values = actionable.compactMap(\.reclaimableBytes)
        return values.isEmpty ? String(localized: "Not measured") : values.reduce(0, +).formatted(.byteCount(style: .file))
    }

    @ViewBuilder
    private var metrics: some View {
        metric(String(localized: "Measured reclaimable space"), value: measuredSpace)
        metric(String(localized: "Ready to clean"), value: String(actionable.count))
        metric(String(localized: "Suggestion only"), value: String(candidates.count - actionable.count))
    }

    private func metric(_ title: String, value: String) -> some View {
        HStack(spacing: DS.Space.s1) {
            Text(title).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            Text(value).font(DS.Font.captionEmphasis).monospacedDigit()
                .foregroundStyle(DS.Palette.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    private var tabs: some View {
        DSTabs(selection: $filter, options: CleanupFilter.allCases, title: String(localized: "Cleanup filter")) { $0.title }
    }

    private var search: some View {
        TextField("Search cleanup items or paths", text: $query).textFieldStyle(.dsField)
            .frame(minWidth: DS.Layout.nameColumnMin, maxWidth: DS.Layout.inspectorIdeal)
    }

    private func refresh() async {
        guard !busy else { return }
        isPreviewing = true
        defer { isPreviewing = false }
        await model.refreshCleanupCandidates()
    }
}

private enum CleanupFilter: CaseIterable {
    case all, actionable, suggestions
    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .actionable: String(localized: "Ready to clean")
        case .suggestions: String(localized: "Suggestions")
        }
    }
}

private struct CleanupCard: View {
    let candidate: CleanupCandidate
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            HStack(alignment: .top, spacing: DS.Space.s3) {
                Image(systemName: candidate.kind.symbol)
                    .font(DS.Font.standaloneIcon)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(width: DS.IconSize.standalone, height: DS.IconSize.standalone)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                        Text(title)
                            .font(DS.Font.headline)
                            .foregroundStyle(DS.Palette.textPrimary)
                        if let provider = candidate.providerID {
                            InstalledViaLabel(provider: provider, font: DS.Font.caption)
                        }
                    }
                    Text(candidate.kind.explanation)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: DS.Space.s1) {
                    if let bytes = candidate.reclaimableBytes {
                        Text(bytes, format: .byteCount(style: .file))
                            .font(DS.Font.headline)
                            .foregroundStyle(DS.Palette.textPrimary)
                            .monospacedDigit()
                    } else {
                        Text("Not measured").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    }
                    IconText(symbol: candidate.risk.symbol, text: candidate.risk.title, tint: candidate.risk.tint, font: DS.Font.caption)
                    actions
                        .padding(.top, DS.Space.s1)
                }
            }

            if !candidate.items.isEmpty || candidate.paths.count > 1 {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: DS.Space.s1) {
                        ForEach(Array(candidate.items.enumerated()), id: \.offset) { _, item in
                            HStack(spacing: DS.Space.s2) {
                                Text(item.name)
                                    .font(DS.Font.mono)
                                    .foregroundStyle(DS.Palette.textPrimary)
                                Spacer()
                                if let version = item.fromVersion {
                                    Text(version)
                                        .font(DS.Font.mono)
                                        .foregroundStyle(DS.Palette.textSecondary)
                                }
                            }
                        }
                        if candidate.items.isEmpty {
                            ForEach(candidate.paths, id: \.self) { path in
                                PathText(path: path)
                            }
                        }
                    }
                    .dsWell(padding: DS.Space.s2)
                } label: {
                    Text(itemCountText)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            } else if let path = candidate.paths.first {
                PathText(path: path, color: DS.Palette.textSecondary)
            }
        }
        .padding(.vertical, DS.Space.s4)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: DS.Space.s2) {
            if candidate.plan != nil {
                Button(role: .destructive) {
                    model.requestCleanup(candidate)
                } label: {
                    Label(candidate.kind == .brokenSymlink ? String(localized: "Move to Trash…") : String(localized: "Clean Up…"), systemImage: candidate.kind == .brokenSymlink ? Symbol.trash : Symbol.cleanup)
                }
                .disabled(model.isPreparingOperation || model.isScanning || model.isOperationRunning || model.isRefreshingMetadata)
            } else {
                IconText(symbol: Symbol.info, text: String(localized: "Suggestion only"), tint: DS.Palette.textSecondary, font: DS.Font.caption)
                if let toolID = suggestedToolID {
                    Button("Show Tool") { model.show(tool: toolID) }
                        .controlSize(.small)
                }
            }
        }
    }

    private var title: String {
        if candidate.kind == .unusedRuntime, let item = candidate.items.first {
            return String(localized: "Unused runtime: \(item.name)")
        }
        return candidate.kind.title(provider: candidate.providerID)
    }

    private var itemCountText: String {
        let count = candidate.items.isEmpty ? candidate.paths.count : candidate.items.count
        return String(localized: "\(count) items")
    }

    /// Unused runtime suggestions link to the tool that owns the package.
    private var suggestedToolID: ToolID? {
        guard let name = candidate.items.first?.name else { return nil }
        return model.snapshot?.tools.first { tool in
            tool.installations.contains { $0.ownership.packageName == name }
        }?.id
    }
}

/// Candidates of the same kind and provider, e.g. every broken link in PATH, shown
/// as one card instead of one card per path.
struct CleanupGroup: Identifiable {
    let kind: CleanupKind
    let providerID: ProviderID?
    let candidates: [CleanupCandidate]

    var id: String { "\(kind.rawValue):\(providerID?.rawValue ?? "")" }

    /// Keeps the order candidates first appear in.
    static func grouping(_ candidates: [CleanupCandidate]) -> [CleanupGroup] {
        var order: [String] = []
        var members: [String: [CleanupCandidate]] = [:]
        for candidate in candidates {
            let key = "\(candidate.kind.rawValue):\(candidate.providerID?.rawValue ?? "")"
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(candidate)
        }
        return order.compactMap { key in
            guard let group = members[key], let first = group.first else { return nil }
            // Unused-runtime suggestions each name a different package; keep them apart.
            if first.kind == .unusedRuntime { return nil }
            return CleanupGroup(kind: first.kind, providerID: first.providerID, candidates: group)
        } + candidates.filter { $0.kind == .unusedRuntime }.map { CleanupGroup(kind: $0.kind, providerID: $0.providerID, candidates: [$0]) }
    }
}

/// One card for many single-path candidates (broken links): a checklist of paths
/// and one button that moves the selected ones to the Trash.
private struct CleanupPathsCard: View {
    let group: CleanupGroup
    @Environment(AppModel.self) private var model
    @State private var deselected: Set<String> = []

    private var paths: [String] { group.candidates.flatMap(\.paths) }
    private var selected: [String] { paths.filter { !deselected.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            HStack(alignment: .top, spacing: DS.Space.s3) {
                Image(systemName: group.kind.symbol)
                    .font(DS.Font.standaloneIcon)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .frame(width: DS.IconSize.standalone, height: DS.IconSize.standalone)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                        Text(group.kind.title(provider: group.providerID))
                            .font(DS.Font.headline)
                            .foregroundStyle(DS.Palette.textPrimary)
                        Text("\(paths.count) items")
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Palette.textSecondary)
                    }
                    Text(group.kind.explanation)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let risk = group.candidates.first?.risk {
                    IconText(symbol: risk.symbol, text: risk.title, tint: risk.tint, font: DS.Font.caption)
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(paths, id: \.self) { path in
                    Toggle(isOn: Binding(
                        get: { !deselected.contains(path) },
                        set: { isOn in if isOn { deselected.remove(path) } else { deselected.insert(path) } }
                    )) {
                        VStack(alignment: .leading, spacing: 0) {
                            PathText(path: path)
                            if let destination = destination(of: path) {
                                HStack(spacing: DS.Space.s1) {
                                    Image(systemName: Symbol.resolvesTo)
                                        .foregroundStyle(DS.Palette.textTertiary)
                                        .accessibilityLabel(Text("Resolves to"))
                                    PathText(path: destination, color: DS.Palette.textTertiary)
                                }
                                .font(DS.Font.caption)
                            }
                        }
                        .padding(.vertical, DS.Space.s1)
                    }
                    .toggleStyle(.checkbox)
                    if path != paths.last { Divider() }
                }
            }
            .dsWell(padding: DS.Space.s2)

            HStack(spacing: DS.Space.s3) {
                Text("\(selected.count) of \(paths.count) selected")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                Spacer()
                if group.candidates.allSatisfy({ $0.plan != nil }) {
                    Button(role: .destructive) {
                        model.requestMoveToTrash(paths: selected, toolID: nil)
                    } label: {
                        Label(String(localized: "Move to Trash…"), systemImage: Symbol.trash)
                    }
                    .disabled(selected.isEmpty || model.isPreparingOperation || model.isScanning || model.isOperationRunning || model.isRefreshingMetadata)
                }
            }
        }
        .padding(.vertical, DS.Space.s4)
    }

    private func destination(of path: String) -> String? {
        model.snapshot?.brokenSymlinks.first { $0.path == path }?.absoluteDestination
    }
}
