import CLIStateDomain
import SwiftUI

struct ToolDetailView: View {
    let tool: Tool
    @Environment(AppModel.self) private var model
    @State private var showsEvidence = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header
                    .padding(DS.Space.s4)
                if let resolution = tool.resolution {
                    section { ResolutionSection(tool: tool, resolution: resolution) }
                }
                section { installationsSection }
                if tool.installations.contains(where: { $0.capabilities.canUpdate }) {
                    section { PolicySection(tool: tool) }
                }
                if !model.timeline.recentChanges(for: tool.id).isEmpty {
                    section { RecentChangesSection(tool: tool) }
                }
                if !configPaths.isEmpty {
                    section { configurationSection }
                }
                section { evidenceSection }
                section { advancedSection }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.Palette.panelPrimary)
        .task(id: model.snapshot?.id) {
            await model.timeline.reload(using: model.actions, snapshotID: model.snapshot?.id)
        }
    }

    /// Sections are separated by hairlines instead of large gaps, so the
    /// inspector reads as one document with a clear order.
    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(DS.Palette.border).frame(height: DS.Stroke.hairline)
            content()
                .padding(DS.Space.s4)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                Text(tool.identity.displayName)
                    .font(DS.Font.toolTitle)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: DS.Space.s2)
                Menu {
                    ToolContextMenu(tool: tool, model: model, placement: .detail)
                } label: {
                    Label(ToolMenuText.moreActions, systemImage: Symbol.moreActions)
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderedButton)
                .modifier(DSGlassButton())
                .menuIndicator(.hidden)
                .fixedSize()
                .help(Text(verbatim: ToolMenuText.moreActions))
            }
            if let summary = tool.identity.localizedSummary {
                Text(summary)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DetailFlowLayout { metaItems }
            DetailFlowLayout {
                if let update = singleUpdate {
                    Button {
                        model.requestUpdate([InstallationRef(toolID: tool.id, installationID: update.id)])
                    } label: {
                        Label(tool.installations.count > 1 ? String(localized: "Update \(update.ownership.provider.displayName) copy") : ToolMenuText.update(to: update.latest?.value.rawValue), systemImage: Symbol.update)
                    }
                    .buttonStyle(.dsPrimary)
                    .disabled(model.isPreparingOperation)
                }
                ExplainWithAIButton(tool: tool)
                if let homepage = tool.identity.homepage {
                    Link(destination: homepage) {
                        Text(verbatim: homepage.host() ?? homepage.absoluteString)
                            .font(DS.Font.mono)
                            .lineLimit(1)
                    }
                    .buttonStyle(.dsSecondary)
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private var metaItems: some View {
        if let installation = tool.primaryInstallation {
            Text(installation.versionText)
                .font(DS.Font.mono)
                .foregroundStyle(DS.Palette.textPrimary)
                .accessibilityLabel(Text("Version \(installation.versionText)"))
        }
        StatusLabel(kind: tool.statusKind, font: DS.Font.caption)
        IconText(symbol: Symbol.category(tool.identity.category), text: tool.identity.category.title, font: DS.Font.caption)

    }

    /// The header's primary button, when exactly one installation can be updated.
    private var singleUpdate: ToolInstallation? {
        let updatable = tool.installations.filter { $0.hasUpdate && ToolActionsAvailable.canUpdate($0) }
        return updatable.count == 1 ? updatable.first : nil
    }

    // MARK: Installations

    private var installationsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            SectionHeader("Installations", subtitle: tool.installations.count > 1 ? String(localized: "\(tool.installations.count) installations found") : nil)
            ForEach(tool.installations) { installation in
                InstallationCard(tool: tool, installation: installation)
            }
        }
    }

    // MARK: Evidence

    private var evidenceSection: some View {
        DisclosureGroup(isExpanded: $showsEvidence) {
            VStack(alignment: .leading, spacing: DS.Space.s3) {
                Text("How CLI State identified the provider of each installation")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                ForEach(tool.installations) { installation in
                    VStack(alignment: .leading, spacing: DS.Space.s1) {
                        HStack(spacing: DS.Space.s2) {
                            InstalledViaLabel(provider: installation.ownership.provider, font: DS.Font.bodyEmphasis)
                            IconText(symbol: installation.ownership.confidence.symbol, text: installation.ownership.confidence.title, tint: installation.ownership.confidence.tint, font: DS.Font.caption)
                        }
                        if installation.ownership.evidence.isEmpty {
                            Text("No evidence recorded.")
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Palette.textTertiary)
                        }
                        ForEach(Array(installation.ownership.evidence.enumerated()), id: \.offset) { _, evidence in
                            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s1) {
                                Image(systemName: evidence.isWeak ? Symbol.info : Symbol.latest)
                                    .font(DS.Font.caption)
                                    .foregroundStyle(evidence.isWeak ? DS.Palette.textTertiary : DS.Palette.success)
                                    .frame(width: DS.IconSize.inline)
                                    .accessibilityHidden(true)
                                Text(abbreviate(evidence.text))
                                    .font(DS.Font.caption)
                                    .foregroundStyle(DS.Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .padding(.top, DS.Space.s2)
        } label: {
            HStack(spacing: DS.Space.s2) {
                Text("Evidence")
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Palette.textPrimary)
                if let confidence = tool.primaryInstallation?.ownership.confidence {
                    IconText(symbol: confidence.symbol, text: confidence.title, tint: confidence.tint, font: DS.Font.caption)
                }
            }
        }
    }

    // MARK: Configuration

    private var configPaths: [String] {
        var seen = Set<String>()
        return tool.installations.flatMap(\.configPaths).filter { seen.insert($0).inserted }
    }

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            SectionHeader("Configuration")
            ForEach(configPaths, id: \.self) { path in
                HStack(spacing: DS.Space.s2) {
                    Image(systemName: Symbol.config)
                        .font(DS.Font.inlineIcon)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .frame(width: DS.IconSize.inline)
                        .accessibilityHidden(true)
                    PathText(path: path)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        Finder.reveal(path)
                    } label: {
                        Label("Reveal in Finder", systemImage: Symbol.reveal)
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.dsSecondary)
                    .help(Text("Reveal in Finder"))
                    .accessibilityLabel(Text("Reveal \((path as NSString).lastPathComponent) in Finder"))
                }
            }
        }
    }

    // MARK: Advanced

    private var advancedSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                KeyValueRow("Tool ID") { Text(tool.id.rawValue).font(DS.Font.mono).textSelection(.enabled) }
                if let registry = tool.identity.registryID {
                    KeyValueRow("Registry ID") { Text(registry).font(DS.Font.mono).textSelection(.enabled) }
                }
                KeyValueRow("Commands") { Text(tool.executableNames.joined(separator: ", ")).font(DS.Font.mono).textSelection(.enabled) }
                KeyValueRow("Last scanned") { Text(tool.lastScannedAt, format: .dateTime) }
                ForEach(tool.installations) { installation in
                    Divider()
                    KeyValueRow("Installation ID") { Text(installation.id.rawValue).font(DS.Font.mono).textSelection(.enabled) }
                    KeyValueRow("Provider ID") { Text(installation.ownership.provider.rawValue).font(DS.Font.mono).textSelection(.enabled) }
                    if let instance = installation.ownership.instance {
                        KeyValueRow("Instance") { Text(instance.rawValue).font(DS.Font.mono).textSelection(.enabled) }
                    }
                    if let source = installation.version.map(\.source) {
                        KeyValueRow("Version source") { Text(source.text).font(DS.Font.mono).textSelection(.enabled) }
                    }
                    if !installation.dependencies.isEmpty {
                        KeyValueRow("Dependencies") { Text(installation.dependencies.joined(separator: ", ")).font(DS.Font.mono).textSelection(.enabled) }
                    }
                }
            }
            .padding(.top, DS.Space.s2)
        } label: {
            Text("Advanced")
                .font(DS.Font.headline)
                .foregroundStyle(DS.Palette.textPrimary)
        }
    }

    @Environment(\.homeDirectory) private var home

    private func abbreviate(_ text: String) -> String {
        text.replacingOccurrences(of: home + "/", with: "~/")
    }
}

extension ObservationSource {
    /// Technical provenance label, e.g. `provider:homebrew`.
    var text: String {
        switch self {
        case let .provider(id): "provider:\(id.rawValue)"
        case let .executable(path): "executable:\(path)"
        case .path: "path"
        case .registry: "registry"
        case .filesystem: "filesystem"
        case .cache: "cache"
        case .inferred: "inferred"
        case let .updateSource(id): "update-source:\(id)"
        }
    }
}

// MARK: - Resolution

struct ResolutionSection: View {
    let tool: Tool
    let resolution: CommandResolution

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            SectionHeader("How Terminal resolves \(resolution.command)")
                .help(Text("PATH entries are searched in order; the first match runs."))
            ForEach(resolution.shadows, id: \.self) { shadow in
                IconText(symbol: Symbol.needsAttention, text: String(localized: "\(shadow.kind.title) runs first: \(shadow.detail ?? shadow.name)"), tint: DS.Palette.warning, textColor: DS.Palette.textPrimary)
            }
            if resolution.chain.isEmpty {
                IconText(symbol: StatusKind.notLinked.symbol, text: String(localized: "\(resolution.command) isn't reachable through PATH."), tint: DS.Palette.textSecondary)
            }
            ResolutionChainView(chain: resolution.chain, nested: true, owner: tool.installation(forExecutablePath:))
        }
    }
}

/// Ordered list of PATH matches for one command.
struct ResolutionChainView: View {
    let chain: [ExecutableRef]
    /// `true` inside panels such as the inspector.
    var nested = false
    let owner: (String) -> ToolInstallation?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(chain.enumerated()), id: \.offset) { index, ref in
                let installation = owner(ref.path)
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                        PriorityBadge(priority: ref.pathPriority)
                            .fixedSize()
                        Spacer(minLength: DS.Space.s2)
                        StatusLabel(kind: index == 0 ? .active : .shadowed, font: DS.Font.caption)
                            .fixedSize()
                    }
                    Text(verbatim: ref.path).font(DS.Font.mono).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: DS.Space.s1) {
                        if let resolved = ref.resolvedPath, resolved != ref.path {
                            HStack(spacing: DS.Space.s1) {
                                Image(systemName: Symbol.resolvesTo)
                                    .font(DS.Font.caption)
                                    .foregroundStyle(DS.Palette.textTertiary)
                                    .accessibilityLabel(Text("Resolves to"))
                                Text(verbatim: resolved).font(DS.Font.mono).foregroundStyle(DS.Palette.textSecondary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        DetailFlowLayout {
                            ownerLabels(installation)
                            detailLabels(installation, ref)
                        }
                    }

                }
                .padding(.vertical, DS.Space.s2)
                .accessibilityElement(children: .combine)
                if index < chain.count - 1 { Divider() }
            }
        }
        .dsCard(padding: DS.Space.s3, nested: nested)
    }

    @ViewBuilder
    private func ownerLabels(_ installation: ToolInstallation?) -> some View {
        if let installation {
            InstalledViaLabel(provider: installation.ownership.provider, font: DS.Font.caption)
                .fixedSize()
            Text(installation.versionText)
                .font(DS.Font.mono)
                .foregroundStyle(DS.Palette.textSecondary)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func detailLabels(_ installation: ToolInstallation?, _ ref: ExecutableRef) -> some View {
        if let installation {
            IconText(symbol: installation.ownership.confidence.symbol, text: installation.ownership.confidence.title, tint: installation.ownership.confidence.tint, font: DS.Font.caption)
                .fixedSize()
        }
        if let architecture = ref.architecture {
            Text(architecture.title)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textSecondary)
                .fixedSize()
        }
    }
}

// MARK: - Installation card

private struct InstallationCard: View {
    let tool: Tool
    let installation: ToolInstallation
    @Environment(AppModel.self) private var model

    @State private var showsCommand = false

    private var ref: InstallationRef { InstallationRef(toolID: tool.id, installationID: installation.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                InstalledViaLabel(provider: installation.ownership.provider, confidence: installation.ownership.confidence, font: DS.Font.bodyEmphasis)
                Spacer()
                if installation.isSystemManaged {
                    StatusLabel(kind: .systemManaged, font: DS.Font.caption)
                }
                StatusLabel(kind: installation.linkState.statusKind, font: DS.Font.caption)
            }
            HStack(alignment: .top, spacing: DS.Space.s4) {
                DetailField("Installed version") {
                    Text(installation.versionText).font(DS.Font.mono).textSelection(.enabled)
                }
                if let latest = installation.latest?.value.rawValue {
                    DetailField("Latest") {
                        Text(latest).font(DS.Font.mono).foregroundStyle(DS.Palette.highlight).textSelection(.enabled)
                    }
                }
            }
            DetailFlowLayout {
                if let status = installation.versionStatus { StatusLabel(kind: status, font: DS.Font.caption) }
                if let channel = installation.latestChannel {
                    Text("\(channel) channel").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                }
                if let checked = installation.latest?.observedAt, tool.lastScannedAt.timeIntervalSince(checked) > 60 {
                    Text("Checked \(RelativeTime.text(checked))").font(DS.Font.caption).foregroundStyle(DS.Palette.textTertiary)
                }
            }
            if let support = installation.support {
                SupportStatusRow(support: support)
            }
            if installation.isSystemManaged || installation.ownership.provider == .system {
                Text("This macOS installation is maintained through system updates and cannot be uninstalled here.")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            }
            actions
            DisclosureGroup {
                VStack(alignment: .leading, spacing: DS.Space.s3) {
                    if let package = installation.ownership.packageName {
                        DetailField("Package") { Text(package).font(DS.Font.mono).textSelection(.enabled) }
                    }
                    if let location = installation.installPrefix ?? installation.primaryExecutable?.path {
                        DetailField("Location") { Text(verbatim: location).font(DS.Font.mono).textSelection(.enabled) }
                    }
                    if let isDirect = installation.isDirect {
                        DetailField("Installed") { Text(isDirect ? "On request" : "As a dependency") }
                    }
                    if !installation.dependents.isEmpty {
                        DetailField("Used by") { Text(installation.dependents.joined(separator: ", ")).font(DS.Font.mono).textSelection(.enabled) }
                    }
                }.padding(.top, DS.Space.s2)
            } label: {
                Text("Installation details").font(DS.Font.body)
            }
            if installation.capabilities.canUninstall,
               installation.ownership.permitsMutation, !installation.isSystemManaged {
                DisclosureGroup(isExpanded: $showsCommand) {
                    if showsCommand {
                        UninstallCommandCard(tool: tool, installation: installation)
                            .id(installation)
                    }
                } label: {
                    Text("Uninstall command").font(DS.Font.body)
                }
            }
        }
        .dsCard(padding: DS.Space.s3, nested: true)
    }

    @ViewBuilder
    private var actions: some View {
        let caps = installation.capabilities
        let service = tool.service.flatMap { $0.installationID == installation.id ? $0 : nil }
        let hasServiceAction = service != nil && (caps.canStart || caps.canStop || caps.canRestart)
        if (caps.canUpdate && installation.hasUpdate) || hasServiceAction || caps.canUninstall || caps.canMoveToTrash {
            Divider()
            FlowButtons {
                if ToolActionsAvailable.canUpdate(installation), installation.hasUpdate {
                    Button {
                        model.requestUpdate([ref])
                    } label: {
                        Label("Update", systemImage: Symbol.update)
                    }
                    .buttonStyle(.dsPrimary)
                }
                if let service {
                    if caps.canStart {
                        serviceButton(.start, service)
                    }
                    if caps.canStop {
                        serviceButton(.stop, service)
                    }
                    if caps.canRestart {
                        serviceButton(.restart, service)
                    }
                }
                if caps.canUninstall || caps.canMoveToTrash {
                    removalMenu(caps)
                }
            }
            .disabled(model.isPreparingOperation)
        } else if !installation.hasAnyAction {
            Divider()
            IconText(symbol: Symbol.info, text: noActionReason, tint: DS.Palette.textTertiary, textColor: DS.Palette.textSecondary, font: DS.Font.caption)
        }
    }

    /// Destructive actions stay one click further away than Update.
    private func removalMenu(_ caps: ToolCapabilities) -> some View {
        Menu {
            if ToolActionsAvailable.canUninstall(installation) {
                Button(role: .destructive) {
                    model.requestUninstall(ref)
                } label: {
                    Label("Uninstall…", systemImage: Symbol.uninstall)
                }
                Button(role: .destructive) {
                    model.reviewLeftovers(LeftoverReview(toolID: tool.id, mode: .uninstall(ref)))
                } label: {
                    Label(ToolMenuText.uninstallAndCleanUp, systemImage: Symbol.cleanup)
                }
            }
            if caps.canMoveToTrash, let path = installation.primaryExecutable?.path {
                Button(role: .destructive) {
                    model.requestMoveToTrash(paths: [path], toolID: tool.id)
                } label: {
                    Label("Move to Trash…", systemImage: Symbol.trash)
                }
            }
        } label: {
            Label("Remove", systemImage: Symbol.uninstall)
        }
        .menuStyle(.borderedButton)
        .modifier(DSGlassButton())
        .fixedSize()
    }

    private var noActionReason: String {
        if installation.isSystemManaged {
            return String(localized: "Managed by macOS. CLI State doesn't change it.")
        }
        if !installation.ownership.permitsMutation {
            return String(localized: "No actions are available because CLI State can't confirm which package manager owns this installation.")
        }
        return String(localized: "No actions are available for this installation.")
    }

    private func serviceButton(_ action: ServiceAction, _ service: ToolService) -> some View {
        Button {
            model.requestService(action, service: service)
        } label: {
            Label(action.title, systemImage: action.symbol)
        }
        .accessibilityLabel(action.title(for: service.name))
    }
}

/// Wraps buttons onto new lines in narrow inspectors.
private struct FlowButtons<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        DetailFlowLayout { content }
        .controlSize(.small)
    }
}

// MARK: - Policy

private struct PolicySection: View {
    let tool: Tool
    @Environment(AppModel.self) private var model

    var body: some View {
        let override = model.preferences.toolPolicies[tool.id]
        let effective = model.effectivePolicy(for: tool)
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            SectionHeader("Automatic updates")
            DSTabs(selection: Binding(get: { effective }, set: { model.setPolicy($0, for: tool.id) }), options: AutoUpdatePolicy.allCases, title: String(localized: "Auto-update policy")) { $0.title }
            Text(effective.explanation)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if effective == .automatic, model.preferences.automaticScope == .patchAndMinor {
                IconText(symbol: Symbol.info, text: String(localized: "Major updates still need your approval."), tint: DS.Palette.textTertiary, textColor: DS.Palette.textSecondary, font: DS.Font.caption)
            }
            if override != nil {
                Button("Use Default Setting") { model.setPolicy(nil, for: tool.id) }
                    .buttonStyle(.dsSecondary)
                    .font(DS.Font.caption)
            } else {
                Text("Uses the default setting.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textTertiary)
            }
        }
    }
}

/// Full-width values keep technical paths and long support text readable in an inspector.
private struct DetailField<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var content: Content
    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            Text(title).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            content.font(DS.Font.body).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Wrap individual controls instead of switching the entire group into one tall column.
private struct DetailFlowLayout: Layout {
    private let spacing = DS.Space.s2
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews, width: bounds.width)
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + result.origins[index].x, y: bounds.minY + result.origins[index].y), anchor: .topLeading,
                       proposal: ProposedViewSize(width: min(view.sizeThatFits(.unspecified).width, bounds.width), height: nil))
        }
    }
    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: min(view.sizeThatFits(.unspecified).width, width), height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width.isFinite ? width : usedWidth, height: y + rowHeight), origins)
    }
}
