import CLIStateDomain
import SwiftUI

/// Shows exactly what will run before any write operation (plan §7).
struct ConfirmationSheet: View {
    let operation: PreparedOperation
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var kind: OperationKind? { operation.plans.first?.plan.kind }
    private var isDestructive: Bool { kind.map(OperationText.isDestructive) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(DS.Space.s6)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.s6) {
                    ForEach(operation.plans) { prepared in
                        PlanSection(prepared: prepared, showsProvider: operation.plans.count > 1)
                    }
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
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Space.s3) {
            Image(systemName: isDestructive ? Symbol.needsAttention : (kind.map(OperationText.symbol) ?? Symbol.update))
                .font(DS.Font.largeTitle)
                .foregroundStyle(isDestructive ? DS.Palette.error : DS.Palette.highlight)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.s1) {
                Text(OperationText.title(for: operation))
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Palette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(OperationText.explanation(for: operation))
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: DS.Space.s3) {
            if operation.isBlocked {
                IconText(symbol: PreflightOutcome.failed.symbol, text: String(localized: "A check failed, so nothing will run."), tint: DS.Palette.error, textColor: DS.Palette.textPrimary)
            } else if operation.plans.contains(where: { $0.plan.requiresNetwork }) {
                IconText(symbol: "network", text: String(localized: "Requires a network connection"), tint: DS.Palette.textSecondary, font: DS.Font.caption)
            }
            Spacer()
            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            confirmButton
        }
    }

    @ViewBuilder
    private var confirmButton: some View {
        let title = OperationText.confirmTitle(for: operation)
        if isDestructive {
            Button(title, role: .destructive) {
                model.confirm(operation)
            }
            .buttonStyle(.dsDestructive)
            .keyboardShortcut(.defaultAction)
            .disabled(operation.isBlocked)
        } else {
            Button(title) {
                model.confirm(operation)
            }
            .buttonStyle(.dsPrimary)
            .keyboardShortcut(.defaultAction)
            .disabled(operation.isBlocked)
        }
    }
}

private struct PlanSection: View {
    let prepared: PreparedPlan
    let showsProvider: Bool

    var body: some View {
        let plan = prepared.plan
        VStack(alignment: .leading, spacing: DS.Space.s3) {
            if showsProvider {
                InstalledViaLabel(provider: plan.providerID, font: DS.Font.headline)
            }
            if !plan.targets.isEmpty, !isTrash(plan.kind) {
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    Text("Changes")
                        .font(DS.Font.captionEmphasis)
                        .foregroundStyle(DS.Palette.textSecondary)
                    ForEach(Array(plan.targets.enumerated()), id: \.offset) { _, target in
                        HStack(spacing: DS.Space.s2) {
                            Text(target.displayName)
                                .font(DS.Font.bodyEmphasis)
                                .foregroundStyle(DS.Palette.textPrimary)
                            if target.packageName != target.displayName {
                                Text(target.packageName)
                                    .font(DS.Font.mono)
                                    .foregroundStyle(DS.Palette.textSecondary)
                            }
                            Spacer()
                            if target.fromVersion != nil || target.toVersion != nil {
                                VersionChange(from: target.fromVersion, to: target.toVersion)
                            }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: DS.Space.s2) {
                Text(plan.steps.count > 1 ? LocalizedStringKey("Commands") : LocalizedStringKey("Command"))
                    .font(DS.Font.captionEmphasis)
                    .foregroundStyle(DS.Palette.textSecondary)
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    ForEach(Array(plan.steps.enumerated()), id: \.offset) { _, step in
                        StepText(step: step)
                    }
                }
                .dsWell()
            }

            if !prepared.checks.isEmpty {
                VStack(alignment: .leading, spacing: DS.Space.s2) {
                    Text("Checks")
                        .font(DS.Font.captionEmphasis)
                        .foregroundStyle(DS.Palette.textSecondary)
                    ForEach(prepared.checks) { check in
                        CheckRow(check: check, provider: plan.providerID)
                    }
                }
            }
        }
    }

    private func isTrash(_ kind: OperationKind) -> Bool {
        kind == .moveToTrash || kind == .cleanup(.brokenSymlink)
    }
}

private struct StepText: View {
    let step: OperationStep
    @Environment(\.homeDirectory) private var home

    var body: some View {
        switch step {
        case let .command(command):
            Text(command.displayString)
                .font(DS.Font.monoBody)
                .foregroundStyle(DS.Palette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .help(PathRedaction.abbreviatingHome(command.fullDisplayString, home: home))
        case let .moveToTrash(path):
            HStack(spacing: DS.Space.s2) {
                Image(systemName: Symbol.trash)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .accessibilityLabel(Text("Move to Trash"))
                PathText(path: path, font: DS.Font.monoBody)
            }
        }
    }
}

private struct CheckRow: View {
    let check: PreflightCheck
    let provider: ProviderID

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s1) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s2) {
                Image(systemName: check.outcome.symbol)
                    .font(DS.Font.inlineIcon)
                    .foregroundStyle(check.outcome.tint)
                    .frame(width: DS.IconSize.inline, height: DS.IconSize.inline)
                    .accessibilityHidden(true)
                Text(check.kind.title(provider: provider, outcome: check.outcome))
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.textPrimary)
                Spacer()
                Text(check.outcome.title)
                    .font(DS.Font.caption)
                    .foregroundStyle(check.outcome.tint)
            }
            .accessibilityElement(children: .combine)
            if let detail = check.detail {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(detail.split(separator: "\n").map(String.init), id: \.self) { line in
                        PathText(path: line, color: DS.Palette.textSecondary)
                    }
                }
                .padding(.leading, DS.IconSize.inline + DS.Space.s2)
            }
            if !check.items.isEmpty {
                DryRunItems(items: check.items)
                    .padding(.leading, DS.IconSize.inline + DS.Space.s2)
            }
        }
    }
}

private struct DryRunItems: View {
    let items: [PreflightItem]

    var body: some View {
        let groups = PreflightItem.Change.displayOrder.compactMap { change -> (PreflightItem.Change, [PreflightItem])? in
            let matching = items.filter { $0.change == change }
            return matching.isEmpty ? nil : (change, matching)
        }
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            ForEach(groups, id: \.0) { change, group in
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    Text("\(change.groupTitle) (\(group.count))")
                        .font(DS.Font.captionEmphasis)
                        .foregroundStyle(DS.Palette.textSecondary)
                    ForEach(Array(group.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: DS.Space.s2) {
                            Text(item.name)
                                .font(DS.Font.mono)
                                .foregroundStyle(DS.Palette.textPrimary)
                            Spacer()
                            if item.fromVersion != nil || item.toVersion != nil {
                                VersionChange(from: item.fromVersion, to: item.toVersion)
                            }
                        }
                    }
                }
            }
        }
        .dsWell(padding: DS.Space.s2)
    }
}

extension PreflightItem.Change {
    static let displayOrder: [PreflightItem.Change] = [.install, .upgrade, .upgradeDependent, .remove, .dependent, .reclaim]
}
