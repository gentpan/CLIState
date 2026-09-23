import CLIStateDomain
import SwiftUI

/// Live scan results stay on the overview; counts use the entire detected inventory.
struct EnvironmentCheckCard: View {
    let snapshot: EnvironmentSnapshot
    @Environment(AppModel.self) private var model
    @State private var showsHandling = false
    @State private var showsDetails = false
    @State private var cleanBrokenLinks = true
    @State private var installUpdates = false
    @State private var selected: Category = .path

    private enum Category: String, CaseIterable, Identifiable {
        case path, issues, updates, providers, services
        var id: Self { self }
        var title: String {
            switch self {
            case .path: "PATH"
            case .issues: String(localized: "Issues")
            case .updates: String(localized: "Updates")
            case .providers: String(localized: "Installed via")
            case .services: String(localized: "Services")
            }
        }
        var symbol: String {
            switch self {
            case .path: "list.number"
            case .issues: "exclamationmark.triangle"
            case .updates: "arrow.down.circle"
            case .providers: "shippingbox"
            case .services: "server.rack"
            }
        }
    }

    private var pathProblems: [PATHEntry] { snapshot.pathEntries.filter { $0.status != .ok } }
    private var updates: [Tool] { snapshot.tools.filter(\.hasUpdate) }
    private var freshProviders: Int {
        snapshot.providers.count { if case .fresh = $0.freshness { return true }; return false }
    }
    private func count(_ category: Category) -> Int {
        switch category {
        case .path: pathProblems.count
        case .issues: snapshot.issues.count
        case .updates: updates.count
        case .providers: freshProviders
        case .services: snapshot.services.count { $0.status == .running }
        }
    }
    private func total(_ category: Category) -> Int {
        switch category {
        case .path: snapshot.pathEntries.count
        case .issues, .updates: snapshot.tools.count
        case .providers: snapshot.providers.count
        case .services: snapshot.services.count
        }
    }
    private func caption(_ category: Category) -> String {
        switch category {
        case .path: String(localized: "Entries to review")
        case .issues: String(localized: "Detected issues")
        case .updates: String(localized: "Tools with updates")
        case .providers: String(localized: "Sources checked successfully")
        case .services: String(localized: "Running services")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s4) {
            HStack {
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    Label(snapshot.health.title, systemImage: snapshot.health.symbol)
                        .font(DS.Font.title)
                    Text(snapshot.health.summary).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                }
                Spacer()
                Button {
                    showsHandling.toggle()
                } label: {
                    Label("Handle issues", systemImage: "wrench.and.screwdriver")
                }
                .modifier(DSGlassButton())
                .disabled(model.isScanning || model.isOperationRunning || model.isPreparingOperation)
                Button {
                    Task { await model.checkForUpdates(); showsDetails = true }
                } label: {
                    Label(model.isScanning ? "Checking environment…" : "Check now", systemImage: model.isScanning ? "hourglass" : "arrow.clockwise")
                }
                .modifier(DSGlassButton())
                .disabled(model.isScanning || model.isOperationRunning)
            }
            if showsHandling {
                VStack(alignment: .leading, spacing: DS.Space.s3) {
                    Text("Choose actions to review").font(DS.Font.headline)
                    Toggle("Move verified broken links to Trash", isOn: $cleanBrokenLinks)
                    Toggle("Also install eligible updates from the current tool list", isOn: $installUpdates)
                    Text("Updates follow your tool visibility settings. Cleanup rechecks broken links before preparing the actions. You can review every command and path before confirming.")
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    Label("PATH configuration, missing apps and installation conflicts require individual review. This action does not uninstall tools or restart services.", systemImage: "info.circle")
                        .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                    HStack {
                        Button {
                            model.requestEnvironmentHandling(cleanBrokenLinks: cleanBrokenLinks, installUpdates: installUpdates)
                        } label: {
                            Label(model.isPreparingOperation ? "Preparing actions…" : "Review selected actions", systemImage: "checklist")
                        }
                        .disabled((!cleanBrokenLinks && !installUpdates) || model.isScanning || model.isPreparingOperation || model.isOperationRunning)
                        Button("Cancel") { showsHandling = false }
                    }
                }
                .dsCard(padding: DS.Space.s3, nested: true)
            }
            Text("Last results: \(snapshot.capturedAt.formatted(date: .abbreviated, time: .shortened)) · \(snapshot.tools.count) tools including dependencies")
                .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            if model.isScanning {
                Label("Checking… Previous results remain visible until the scan finishes.", systemImage: "hourglass")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.highlight)
            } else if case .failed = model.scanState {
                Label("Check failed. The results below are from the previous scan.", systemImage: "exclamationmark.triangle")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.warning)
            }
            DisclosureGroup(isExpanded: $showsDetails) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: DS.Layout.statColumnMin), spacing: DS.Space.s3)], spacing: DS.Space.s3) {
                    ForEach(Category.allCases) { category in
                        Button { selected = category } label: {
                            VStack(alignment: .leading, spacing: DS.Space.s2) {
                                Label(category.title, systemImage: category.symbol).font(DS.Font.bodyEmphasis)
                                Text(count(category), format: .number).font(DS.Font.title).monospacedDigit()
                                Text(caption(category)).font(DS.Font.caption)
                                if category != .issues {
                                    Text("\(total(category)) total").font(DS.Font.caption)
                                }
                            }
                            .foregroundStyle(selected == category ? DS.Palette.highlight : DS.Palette.textPrimary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .dsCard(padding: DS.Space.s3, nested: true)
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.base).stroke(selected == category ? DS.Palette.primary : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected == category ? [.isSelected] : [])
                    }
                }
                Divider()
                HStack {
                    Label(selected.title, systemImage: selected.symbol).font(DS.Font.headline)
                    Spacer()
                    if selected == .path { Button("Show PATH") { model.route = .path }.buttonStyle(.dsSecondary) }
                    if selected == .issues { Button("Show all issues") { model.route = .issues }.buttonStyle(.dsSecondary) }
                    if selected == .updates { Button("Updates") { model.route = .updates }.buttonStyle(.dsSecondary) }
                }
                details
                Text("Supported CLI environment only. Missing data is not a successful check; stopped services are not necessarily problems.")
                    .font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
            } label: {
                Label("Detailed check results", systemImage: "checklist")
                    .font(DS.Font.bodyEmphasis)
            }

        }
        .dsCard()
    }

    @ViewBuilder private var details: some View {
        switch selected {
        case .path:
            if snapshot.shell.source == .fallback {
                statusRow(String(localized: "Login shell unavailable; showing fallback PATH."), value: String(localized: "Needs Attention"), warning: true)
            }
            if pathProblems.isEmpty { empty }
            ForEach(pathProblems) { entry in
                HStack {
                    Image(systemName: entry.status.symbol).foregroundStyle(entry.status.tint)
                    PathText(path: entry.rawValue, font: DS.Font.mono)
                    Spacer()
                    Text(entry.status.title).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
                }
            }
        case .issues:
            if snapshot.issues.isEmpty { empty }
            ForEach(snapshot.issues.sorted { $0.severity > $1.severity }.prefix(8)) { issue in
                let text = issue.text(in: snapshot)
                DisclosureGroup {
                    Text(text.message).font(DS.Font.body).frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label(text.title, systemImage: "exclamationmark.triangle").font(DS.Font.body)
                }
            }
            if snapshot.issues.count > 8 { Text("Showing the first 8 issues. Open all issues for the complete list.").font(DS.Font.caption) }
        case .updates:
            if updates.isEmpty { empty }
            ForEach(updates) { tool in
                Button { model.show(tool: tool.id) } label: {
                    HStack {
                        Text(tool.identity.displayName).font(DS.Font.toolName)
                        Spacer()
                        Text("Review installation").font(DS.Font.caption)
                        Image(systemName: "chevron.right")
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        case .providers:
            ForEach(snapshot.providers, id: \.providerID) { provider in
                let fresh = { if case .fresh = provider.freshness { return true }; return false }()
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    statusRow(provider.providerID.displayName, value: providerState(provider.freshness), warning: !fresh)
                    if let error = provider.lastError { Text(error).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
                    ForEach(provider.warnings, id: \.self) { Text($0).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary) }
                }
            }
        case .services:
            if snapshot.services.isEmpty { Text("No services detected.").font(DS.Font.body) }
            ForEach(snapshot.services) { service in
                statusRow(service.name, value: service.status.title, warning: service.status == .error || service.status == .unknown)
            }
        }
    }
    private var empty: some View {
        Label("No matching items in this scan.", systemImage: "checkmark.circle")
            .font(DS.Font.body).foregroundStyle(DS.Palette.textSecondary)
    }
    private func statusRow(_ title: String, value: String, warning: Bool) -> some View {
        HStack {
            Image(systemName: warning ? "exclamationmark.circle" : "circle.fill")
                .foregroundStyle(warning ? DS.Palette.warning : DS.Palette.textSecondary)
            Text(title).font(DS.Font.body)
            Spacer()
            Text(value).font(DS.Font.caption).foregroundStyle(DS.Palette.textSecondary)
        }
    }
    private func providerState(_ freshness: Freshness) -> String {
        switch freshness {
        case .fresh: String(localized: "Fresh")
        case .stale: String(localized: "Stale data")
        case .unavailable: String(localized: "Unavailable")
        case .unknown: String(localized: "Unknown")
        }
    }
}
