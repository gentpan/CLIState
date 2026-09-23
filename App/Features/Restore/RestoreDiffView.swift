import AppKit
import CLIStateApplication
import CLIStateDomain
import SwiftUI

/// A scrolling page for one source: its header, the diff, and the install bar.
struct RestoreSourcePage<Header: View>: View {
    let source: RestoreSource
    @ViewBuilder var header: Header

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s4) {
                    header
                    RestoreDiffSections(source: source)
                }
                .padding(DS.Space.s6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            RestoreInstallBar(source: source)
        }
    }
}

/// 已安装 / 版本不同 / 待安装 / 无法安装 for a profile or template.
struct RestoreDiffSections: View {
    let source: RestoreSource
    @Environment(AppModel.self) private var model

    var body: some View {
        if let snapshot = model.snapshot {
            let diff = EnvironmentRestore.diff(source.profile, snapshot: snapshot)
            VStack(alignment: .leading, spacing: DS.Space.s4) {
                summary(diff)
                if !diff.installable.isEmpty {
                    SectionHeader(LocalizedStringKey(String(localized: "To Install", table: "Restore")), subtitle: String(localized: "Homebrew runs first, so runtimes exist before npm, uv, pipx and Cargo need them. Nothing runs until you confirm.", table: "Restore"))
                    ForEach(Self.providerGroups(diff.installable), id: \.provider) { group in
                        InstallableGroupCard(source: source, provider: group.provider, entries: group.entries)
                    }
                }
                if !diff.unavailable.isEmpty {
                    SectionHeader(LocalizedStringKey(String(localized: "Can't Install", table: "Restore")))
                    ForEach(Self.blockerGroups(diff.unavailable), id: \.blocker) { group in
                        UnavailableGroupCard(blocker: group.blocker, entries: group.entries)
                    }
                }
                if !diff.versionDiffers.isEmpty {
                    SectionHeader(LocalizedStringKey(String(localized: "Version Differs", table: "Restore")), subtitle: String(localized: "For your information only. CLI State doesn't upgrade or downgrade these here.", table: "Restore"))
                    EntryListCard(entries: diff.versionDiffers)
                }
                if !diff.installed.isEmpty {
                    InstalledDisclosure(entries: diff.installed)
                }
            }
        }
    }

    private func summary(_ diff: ProfileDiff) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: DS.Layout.statColumnMin), spacing: DS.Space.s3)], alignment: .leading, spacing: DS.Space.s3) {
            SummaryChip(status: .installed(version: nil, provider: .standalone), count: diff.installed.count)
            SummaryChip(status: .versionDiffers(installed: "", expected: "", provider: .standalone), count: diff.versionDiffers.count)
            SummaryChip(status: .pending, count: diff.installable.count)
            SummaryChip(status: .unavailable(.invalidPackageName), count: diff.unavailable.count)
        }
    }

    static func providerGroups(_ entries: [ProfileDiffEntry]) -> [(provider: ProviderID, entries: [ProfileDiffEntry])] {
        let order: [ProviderID] = [.homebrew, .npm, .pnpm, .uv, .pipx, .cargo]
        let grouped = Dictionary(grouping: entries) { $0.item.provider.providerID ?? .standalone }
        return grouped.keys.sorted { (order.firstIndex(of: $0) ?? order.count) < (order.firstIndex(of: $1) ?? order.count) }
            .map { ($0, grouped[$0] ?? []) }
    }

    static func blockerGroups(_ entries: [ProfileDiffEntry]) -> [(blocker: RestoreBlocker, entries: [ProfileDiffEntry])] {
        var order: [RestoreBlocker] = []
        var grouped: [RestoreBlocker: [ProfileDiffEntry]] = [:]
        for entry in entries {
            guard case let .unavailable(blocker) = entry.status else { continue }
            if grouped[blocker] == nil { order.append(blocker) }
            grouped[blocker, default: []].append(entry)
        }
        return order.map { ($0, grouped[$0] ?? []) }
    }
}

private struct SummaryChip: View {
    let status: ProfileItemStatus
    let count: Int

    var body: some View {
        HStack(spacing: DS.Space.s2) {
            IconText(symbol: RestoreText.statusSymbol(status), text: RestoreText.statusTitle(status), tint: RestoreText.statusTint(status), textColor: DS.Palette.textSecondary)
            Text(count, format: .number)
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Palette.textPrimary)
                .monospacedDigit()
        }
        .padding(.horizontal, DS.Space.s3)
        .padding(.vertical, DS.Space.s2)
        .background(DS.Palette.panelPrimary, in: RoundedRectangle(cornerRadius: DS.Radius.base))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.base).strokeBorder(DS.Palette.border, lineWidth: DS.Stroke.hairline))
        .accessibilityElement(children: .combine)
    }
}

private struct InstallableGroupCard: View {
    let source: RestoreSource
    let provider: ProviderID
    let entries: [ProfileDiffEntry]
    @Environment(AppModel.self) private var model
    @Environment(RestoreModel.self) private var restore

    var body: some View {
        let items = entries.map(\.item)
        let allSelected = items.allSatisfy { restore.isSelected($0, in: source) }
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            HStack(spacing: DS.Space.s2) {
                InstalledViaLabel(provider: provider, font: DS.Font.headline)
                if case let .pendingAfter(_, enabledBy)? = entries.first?.status {
                    IconText(symbol: RestoreSymbol.waiting, text: RestoreText.statusDetail(.pendingAfter(provider: provider, enabledBy: enabledBy), snapshot: model.snapshot) ?? "", font: DS.Font.caption)
                }
                Spacer()
                Button {
                    restore.setSelected(!allSelected, items, in: source)
                } label: {
                    allSelected ? Text("Deselect All", tableName: "Restore") : Text("Select All", tableName: "Restore")
                }
                .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                ForEach(entries) { entry in
                    Toggle(isOn: Binding(
                        get: { restore.isSelected(entry.item, in: source) },
                        set: { restore.setSelected($0, [entry.item], in: source) }
                    )) {
                        RestoreItemLabel(item: entry.item, snapshot: model.snapshot) {
                            IconText(symbol: RestoreText.statusSymbol(entry.status), text: RestoreText.statusTitle(entry.status), tint: RestoreText.statusTint(entry.status), font: DS.Font.caption)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
        .dsCard()
    }
}

private struct UnavailableGroupCard: View {
    let blocker: RestoreBlocker
    let entries: [ProfileDiffEntry]
    @Environment(AppModel.self) private var model
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            IconText(symbol: RestoreSymbol.unavailable, text: RestoreText.blockerText(blocker), tint: DS.Palette.warning, textColor: DS.Palette.textPrimary, font: DS.Font.bodyEmphasis)
            if case let .providerMissing(provider) = blocker {
                Text(RestoreText.markdown(RestoreText.missingProviderHint(provider)))
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if provider == .homebrew {
                    HStack(alignment: .top, spacing: DS.Space.s2) {
                        Text(verbatim: EnvironmentRestore.homebrewInstallCommand)
                            .font(DS.Font.monoBody)
                            .foregroundStyle(DS.Palette.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(EnvironmentRestore.homebrewInstallCommand, forType: .string)
                            didCopy = true
                        } label: {
                            Label {
                                didCopy ? Text("Copied", tableName: "Restore") : Text("Copy", tableName: "Restore")
                            } icon: {
                                Image(systemName: didCopy ? Symbol.latest : Symbol.copy)
                            }
                        }
                        .controlSize(.small)
                    }
                    .dsWell()
                }
            }
            VStack(alignment: .leading, spacing: DS.Space.s2) {
                ForEach(entries) { entry in
                    RestoreItemLabel(item: entry.item, snapshot: model.snapshot) {
                        Text(verbatim: RestoreText.providerTitle(entry.item.provider))
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                }
            }
        }
        .dsCard()
    }
}

private struct EntryListCard: View {
    let entries: [ProfileDiffEntry]
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            ForEach(entries) { entry in
                RestoreItemLabel(item: entry.item, snapshot: model.snapshot) {
                    VStack(alignment: .trailing, spacing: 0) {
                        IconText(symbol: RestoreText.statusSymbol(entry.status), text: RestoreText.statusTitle(entry.status), tint: RestoreText.statusTint(entry.status), font: DS.Font.caption)
                        if let detail = RestoreText.statusDetail(entry.status, snapshot: model.snapshot) {
                            Text(verbatim: detail)
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Palette.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .dsCard()
    }
}

private struct InstalledDisclosure: View {
    let entries: [ProfileDiffEntry]
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            EntryListCard(entries: entries)
                .padding(.top, DS.Space.s2)
        } label: {
            let count = entries.count
            Text("Already installed (\(count))", tableName: "Restore")
                .font(DS.Font.headline)
                .foregroundStyle(DS.Palette.textPrimary)
        }
    }
}

/// Selection count and the one install button; shows staged progress.
struct RestoreInstallBar: View {
    let source: RestoreSource
    @Environment(AppModel.self) private var model
    @Environment(RestoreModel.self) private var restore

    var body: some View {
        let selected = model.snapshot.map { restore.selectedInstallable(EnvironmentRestore.diff(source.profile, snapshot: $0), in: source) } ?? []
        HStack(spacing: DS.Space.s3) {
            if let stage = restore.stage {
                IconText(symbol: RestoreSymbol.waiting, text: stageText(stage), tint: DS.Palette.highlight, textColor: DS.Palette.textPrimary)
                Button {
                    restore.cancelStages()
                } label: {
                    Text("Stop After This Step", tableName: "Restore")
                }
                .controlSize(.small)
            } else {
                let count = selected.count
                Text("\(count) selected to install", tableName: "Restore")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .monospacedDigit()
            }
            Spacer()
            if restore.isPreparing {
                ProgressView().controlSize(.small)
            }
            Button {
                restore.install(source, model: model)
            } label: {
                Label {
                    Text("Install Selected…", tableName: "Restore")
                } icon: {
                    Image(systemName: RestoreSymbol.install)
                }
            }
            .buttonStyle(.dsPrimary)
            .disabled(selected.isEmpty || restore.isPreparing || restore.stage != nil || model.pendingOperation != nil || model.isOperationRunning || model.isScanning)
        }
        .padding(DS.Space.s4)
        .background(DS.Palette.panelPrimary)
    }

    private func stageText(_ stage: RestoreModel.Stage) -> String {
        let step = stage.step
        let providers = stage.waitingProviders.map(\.displayName).formatted(.list(type: .and))
        return String(localized: "Step \(step) is running. CLI State continues with \(providers) after the rescan.", table: "Restore")
    }
}
