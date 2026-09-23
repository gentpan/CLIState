import AppKit
import CLIStateDomain
import SwiftUI

struct IssuesView: View {
    @Environment(AppModel.self) private var model
    /// Rows start collapsed to one line; the explanation and actions show on demand.
    @State private var expanded: Set<String> = []
    @State private var showsManualHandling = false

    var body: some View {
        let issues = model.issues
        let eligible = issues.filter { model.cleanupCandidate(for: $0) != nil }
        let manualLinks = issues.filter { $0.type == .brokenSymlink && $0.severity != .info && model.cleanupCandidate(for: $0) == nil }
        Group {
            if issues.isEmpty {
                EmptyStateView("No issues found", symbol: Symbol.good, message: String(localized: "Every command in PATH resolves the way CLI State expects."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.s6) {
                        ForEach([HealthSeverity.critical, .warning, .info], id: \.self) { severity in
                            let group = issues.filter { $0.severity == severity }
                            if !group.isEmpty {
                                issueGroup(group, severity: severity, defaultExpanded: issues.count <= Self.expandAllLimit)
                            }
                        }
                    }
                    .padding(DS.Space.s4)
                }
                .background(DS.Palette.background)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: DS.Space.s2) { headerActionButtons(issues: issues, eligible: eligible, needsManualHandling: !manualLinks.isEmpty) }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .trailing, spacing: DS.Space.s2) { headerActionButtons(issues: issues, eligible: eligible, needsManualHandling: !manualLinks.isEmpty) }
                }
            }
            .padding(.horizontal, DS.Space.s4)
            .padding(.vertical, DS.Space.s3)
            .frame(minHeight: DS.Layout.pageHeaderMinHeight)
            .background(DS.Palette.background)
            .overlay(alignment: .bottom) {
                Rectangle().fill(DS.Palette.border).frame(height: DS.Stroke.hairline)
            }
            .disabled(model.isScanning || model.isPreparingOperation || model.isOperationRunning || model.isRefreshingMetadata)
        }
        .sheet(isPresented: $showsManualHandling) {
            ManualLinkHandling(paths: manualLinks.compactMap { $0.paths.first })
        }
        .dsPageTitle(Text("Issues"), symbol: Symbol.issues, count: issues.count)
    }

    /// A short list is easier to read fully expanded.
    private static let expandAllLimit = 3

    private func issueGroup(_ issues: [HealthIssue], severity: HealthSeverity, defaultExpanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            HStack(spacing: DS.Space.s2) {
                Image(systemName: severity.symbol)
                    .font(DS.Font.inlineIcon)
                    .foregroundStyle(severity.tint)
                    .frame(width: DS.IconSize.inline)
                    .accessibilityHidden(true)
                Text(severity.sectionTitle)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Palette.textPrimary)
                Text(issues.count, format: .number)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .padding(.horizontal, DS.Space.s4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            LazyVStack(spacing: 0) {
                ForEach(Array(issues.enumerated()), id: \.element.id) { index, issue in
                    if index > 0 {
                        Rectangle()
                            .fill(DS.Palette.border)
                            .frame(height: DS.Stroke.hairline)
                            .padding(.leading, DS.Space.s4)
                    }
                    IssueRow(issue: issue, isExpanded: expansionBinding(issue.id, defaultExpanded: defaultExpanded))
                        .padding(.horizontal, DS.Space.s4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Palette.panelPrimary, in: RoundedRectangle(cornerRadius: DS.Radius.base))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.base).strokeBorder(DS.Palette.border, lineWidth: DS.Stroke.hairline))
        }
    }

    @ViewBuilder
    private func headerActionButtons(issues: [HealthIssue], eligible: [HealthIssue], needsManualHandling: Bool) -> some View {
        Button { Task { await model.checkForUpdates() } } label: {
            Label("Recheck issues", systemImage: Symbol.refresh)
        }
        .buttonStyle(.dsSecondary)
        if !eligible.isEmpty {
            Button("Handle eligible issues…") { model.requestIssueCleanup(issues) }
                .buttonStyle(.dsPrimary)
                .help(Text("Batch handling only removes confirmed broken links. Review the suggestions below for configuration and installation conflicts."))
        }
        if needsManualHandling {
            Button("Review manual handling…") { showsManualHandling = true }
                .buttonStyle(.dsSecondary)
        }
    }

    private func expansionBinding(_ id: String, defaultExpanded: Bool) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) != defaultExpanded },
            set: { isOn in
                if isOn != defaultExpanded { expanded.insert(id) } else { expanded.remove(id) }
            }
        )
    }
}

private struct IssueRow: View {
    let issue: HealthIssue
    @Binding var isExpanded: Bool
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let pathLimit = 3
    @State private var showsManualHandling = false

    var body: some View {
        let text = issue.text(in: model.snapshot)
        let resolution = issue.resolution(cleanupCandidate: model.cleanupCandidate(for: issue))
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Button {
                withAnimation(reduceMotion ? nil : DS.Motion.standard) { isExpanded.toggle() }
            } label: {
                summaryLine(text, resolution: resolution)
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text(isExpanded ? "Hides the details" : "Shows the details and actions"))

            if isExpanded {
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    Text(text.message)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)

                    if issue.type == .pathConflict, let tool = issue.toolID.flatMap({ model.snapshot?.tool($0) }), let chain = tool.resolution?.chain, !chain.isEmpty {
                        ResolutionChainView(chain: chain, owner: tool.installation(forExecutablePath:))
                    } else if !issue.paths.isEmpty {
                        paths
                    }
                    resolutionPanel(resolution)
                    actions
                        .disabled(model.isScanning || model.isPreparingOperation || model.isOperationRunning || model.isRefreshingMetadata)
                }
            }
        }
        .sheet(isPresented: $showsManualHandling) { ManualLinkHandling(paths: Array(issue.paths.prefix(1))) }
        .padding(.vertical, DS.Space.s2)
        .accessibilityElement(children: .contain)
    }

    /// Keep the title readable even when the first path is long.
    private func summaryLine(_ text: IssueText, resolution: IssueResolution) -> some View {
        HStack(spacing: DS.Space.s2) {
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                Text(text.title)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .lineLimit(2)
                if let path = issue.paths.first {
                    PathText(path: path, color: DS.Palette.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DS.Space.s2)
            if let status = resolution.status {
                Label(status, systemImage: resolution.symbol)
                    .font(DS.Font.caption)
                    .foregroundStyle(resolution.tint)
                    .lineLimit(1)
            }
            Image(systemName: isExpanded ? Symbol.chevronDown : Symbol.chevronRight)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textTertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: DS.ControlHeight.regular)
        .contentShape(Rectangle())
    }

    private func resolutionPanel(_ resolution: IssueResolution) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Label("Resolution", systemImage: resolution.symbol)
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Palette.textPrimary)
            Text(resolution.reason)
                .font(DS.Font.body)
                .foregroundStyle(DS.Palette.textSecondary)
            Text(resolution.nextStep)
                .font(DS.Font.body)
                .foregroundStyle(DS.Palette.textPrimary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .dsWell(padding: DS.Space.s3)
    }

    @ViewBuilder
    private var paths: some View {
        let visible = Array(issue.paths.prefix(pathLimit))
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            ForEach(visible, id: \.self) { path in
                PathText(path: path)
            }
            if issue.paths.count > pathLimit {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: DS.Space.s1) {
                        ForEach(issue.paths.dropFirst(pathLimit), id: \.self) { path in
                            PathText(path: path)
                        }
                    }
                } label: {
                    Text("\(issue.paths.count - pathLimit) more")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }
        }
        .dsWell(padding: DS.Space.s2)
    }

    @ViewBuilder
    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DS.Space.s2) { actionButtons }
                .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: DS.Space.s2) { actionButtons }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if model.cleanupCandidate(for: issue) != nil {
            Button("Handle this issue…") { model.requestIssueCleanup([issue]) }
        }
        if issue.type == .providerScanFailed {
            Button("Retry scan") { Task { await model.checkForUpdates() } }
        }
        if let action = issue.suggestedAction, let title = action.title, canPerform(action) {
            Button {
                perform(action)
            } label: {
                Label(title, systemImage: action.symbol)
            }
        }
        if issue.type == .brokenSymlink, issue.severity != .info, model.cleanupCandidate(for: issue) == nil {
            Button("How to handle…") { showsManualHandling = true }.buttonStyle(.dsSecondary)
        }
        if issue.type == .brokenSymlink, model.cleanupCandidate(for: issue) != nil {
            Button {
                model.route = .cleanup
            } label: {
                Label("Review in Cleanup", systemImage: Symbol.cleanup)
            }
        }
        if let toolID = issue.toolID, issue.suggestedAction != .openTool(toolID) {
            Button {
                model.show(tool: toolID)
            } label: {
                Label("Show Tool", systemImage: Symbol.tools)
            }
        }
        AskAIAboutIssueButton(issue: issue)
    }

    private func canPerform(_ action: SuggestedAction) -> Bool {
        if case .revealInFinder = action, issue.type == .brokenSymlink, issue.severity == .info {
            return false
        }
        if case let .updateTool(id) = action {
            return model.snapshot?.tool(id)?.installations.contains { $0.hasUpdate && ToolActionsAvailable.canUpdate($0) } == true
        }
        if case let .restartService(name) = action {
            return model.snapshot?.services.contains { $0.name == name } == true
        }
        return true
    }

    private func perform(_ action: SuggestedAction) {
        switch action {
        case .openPathSettings:
            model.route = .path
        case let .revealInFinder(path):
            Finder.reveal(path)
        case let .updateTool(toolID):
            if let tool = model.snapshot?.tool(toolID) {
                model.requestUpdate(tool.installations.filter { $0.hasUpdate && ToolActionsAvailable.canUpdate($0) }.map { InstallationRef(toolID: toolID, installationID: $0.id) })
            }
        case let .openTool(toolID):
            model.show(tool: toolID)
        case let .restartService(name):
            if let service = model.snapshot?.services.first(where: { $0.name == name }) {
                model.requestService(.restart, service: service)
            }
        case .none:
            break
        }
    }
}

/// Guidance for links the app cannot safely mutate, without issuing privileged commands.
private struct ManualLinkHandling: View {
    let paths: [String]
    @Environment(\.dismiss) private var dismiss

    private func isProtected(_ path: String) -> Bool {
        ["/System", "/bin", "/sbin", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec"].contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    private var selectablePaths: [String] { paths.filter { !isProtected($0) } }

    private var sharedApplication: String? {
        let names = selectablePaths.compactMap { path -> String? in
            guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
                  let component = URL(fileURLWithPath: target).pathComponents.first(where: { $0.hasSuffix(".app") }) else { return nil }
            return String(component.dropLast(4))
        }
        return names.count == selectablePaths.count && Set(names).count == 1 ? names.first : nil
    }

    private var sharedUnwritableDirectory: String? {
        let directories = Set(selectablePaths.map { ($0 as NSString).deletingLastPathComponent })
        guard directories.count == 1, let directory = directories.first,
              !FileManager.default.isWritableFile(atPath: directory) else { return nil }
        return directory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            Text("Handle broken links").font(DS.Font.title)
            Text("A broken link is a shortcut whose target is missing. Removing the link does not uninstall another working copy of the tool.")
                .font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary)
            if let application = sharedApplication {
                Text("These links point to the removed \(application) app.")
                    .font(DS.Font.bodyEmphasis).foregroundStyle(DS.Palette.textPrimary)
            }
            if let directory = sharedUnwritableDirectory {
                Text("CLI State cannot move these links because your account cannot write to \(directory). Finder may ask for administrator authorization.")
                    .font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary)
            }
            Text("If you still need the original app, reinstall it. Otherwise, move only the broken links to the Trash in Finder, authorizing the change if macOS asks.")
                .font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary)
            if selectablePaths.count > 1 {
                Button("Select all links in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(selectablePaths.map { URL(fileURLWithPath: $0) })
                }
                .buttonStyle(.dsSecondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s4) {
                    ForEach(Array(Set(paths)).sorted(), id: \.self) { path in
                        VStack(alignment: .leading, spacing: DS.Space.s2) {
                            Text(verbatim: path).font(DS.Font.mono).textSelection(.enabled)
                            if FileManager.default.fileExists(atPath: path) {
                                Text("The target exists now. Run the check again; no removal is needed.").font(DS.Font.body)
                            } else if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
                                Text("Original target").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                                Text(verbatim: target).font(DS.Font.mono).textSelection(.enabled)
                                if isProtected(path) {
                                    Text("This is a system location. Do not delete it manually; use macOS updates or the component's installer to repair it.")
                                        .font(DS.Font.body)
                                } else {
                                    Button("Reveal link in Finder") { Finder.reveal(path) }.buttonStyle(.dsSecondary)
                                }
                            } else {
                                Text("This path is no longer a symbolic link. Run the check again before taking action.").font(DS.Font.body)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).dsCard()
                    }
                }
            }
            Text("After handling the links, run Check again to update the issue list.").font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            HStack { Spacer(); Button("Done") { dismiss() }.buttonStyle(.dsPrimary) }
        }
        .padding(DS.Space.s6)
        .frame(width: DS.Layout.tabsMaxWidth, height: DS.Layout.tabsMaxWidth)
    }
}
