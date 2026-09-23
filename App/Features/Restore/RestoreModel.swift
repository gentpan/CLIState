import AppKit
import CLIStateApplication
import CLIStateDomain
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Where the packages on the import side come from.
struct RestoreSource: Hashable {
    enum Kind: Hashable {
        case file(name: String)
        case template(String)
        case suggestion
    }

    var kind: Kind
    var profile: EnvironmentProfile

    /// Keeps a separate checklist per file, template and suggestion.
    var key: String {
        switch kind {
        case let .file(name): "file:\(name)"
        case let .template(id): "template:\(id)"
        case .suggestion: "suggestion"
        }
    }
}

/// State of the environment restore page (Lane N). Lives as long as the app so a
/// staged install keeps going while the user looks at other pages.
@Observable
@MainActor
final class RestoreModel {
    enum Tab: String, CaseIterable, Hashable {
        case export, importFile, templates
    }

    /// A multi-stage install in progress: the next stage is planned after the
    /// current one ran and the rescan finished (npm exists only after Node.js).
    struct Stage: Hashable {
        var sourceKey: String
        var step: Int
        var waitingProviders: [ProviderID]
    }

    var tab: Tab = .export

    // MARK: Export

    private(set) var exportDraft: EnvironmentProfile?
    private(set) var isLoadingExport = false
    /// Unchecked item IDs; everything else is exported.
    var exportExcluded: Set<String> = []
    var profileName = ""
    var profileNote = ""

    var exportSelection: [ProfileItem] {
        exportDraft?.items.filter { !exportExcluded.contains($0.id) } ?? []
    }

    // MARK: Import and templates

    private(set) var importedSource: RestoreSource?
    var selectedTemplateID: String?
    let suggestion = RestoreSuggestionSession()
    /// Unchecked installable item IDs per source; new items start checked.
    private var installExcluded: [String: Set<String>] = [:]
    private(set) var isPreparing = false
    private(set) var stage: Stage?
    private var stageTask: Task<Void, Never>?

    var templateSource: RestoreSource? {
        guard let id = selectedTemplateID, let template = EnvironmentRestore.template(id) else { return nil }
        return RestoreSource(kind: .template(id), profile: template.profile)
    }

    var suggestionSource: RestoreSource? {
        suggestion.profile.map { RestoreSource(kind: .suggestion, profile: $0) }
    }

    /// The Templates tab shows either the chosen template or the AI suggestion.
    var showsSuggestion = false

    var activeTemplatesSource: RestoreSource? {
        showsSuggestion ? (suggestionSource ?? templateSource) : templateSource
    }

    // MARK: Export actions

    func loadExport(model: AppModel) async {
        guard let actions = model.actions as? RestoreActions, !isLoadingExport else { return }
        isLoadingExport = true
        defer { isLoadingExport = false }
        let draft = await actions.exportProfile(name: nil, note: nil)
        if let previous = exportDraft, let draft {
            // Keep the user's choices across rescans; only packages that are gone drop out.
            exportExcluded.formIntersection(Set(draft.items.map(\.id)).intersection(previous.items.map(\.id)))
        }
        exportDraft = draft
    }

    private var profileToSave: EnvironmentProfile? {
        guard var profile = exportDraft else { return nil }
        profile.items = exportSelection
        profile.createdAt = .now
        profile.name = profileName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        profile.note = profileNote.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        return profile
    }

    func saveProfile(model: AppModel) {
        guard let profile = profileToSave, !profile.items.isEmpty else { return }
        let panel = NSSavePanel()
        let base = profile.name.map(Self.fileSafe) ?? String(localized: "My Mac", table: "Restore")
        panel.nameFieldStringValue = "\(base).\(EnvironmentProfile.fileExtension)"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try profile.encoded().write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            model.alert = AppAlert(title: String(localized: "Couldn't Save the Profile", table: "Restore"), message: error.localizedDescription)
        }
    }

    var canExportBrewfile: Bool {
        exportSelection.contains { $0.provider == .homebrewFormula || $0.provider == .homebrewCask }
    }

    func saveBrewfile(model: AppModel) {
        guard let profile = profileToSave else { return }
        let text = EnvironmentRestore.brewfile(for: profile)
        guard !text.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Brewfile"
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            model.alert = AppAlert(title: String(localized: "Couldn't Save the Brewfile", table: "Restore"), message: error.localizedDescription)
        }
    }

    /// Profile names become file names; path separators and leading dots are dropped.
    private static func fileSafe(_ name: String) -> String {
        let cleaned = name.map { "/:\\".contains($0) ? "-" : $0 }
        return String(String(cleaned).drop { $0 == "." }).nilIfEmpty ?? "Profile"
    }

    // MARK: Import actions

    func openProfile(model: AppModel) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.clistateProfile, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            loadProfile(try EnvironmentProfile.decode(from: data), fileName: url.lastPathComponent)
        } catch {
            model.alert = AppAlert(
                title: String(localized: "Couldn't Open the Profile", table: "Restore"),
                message: String(localized: "\(url.lastPathComponent) isn't a CLI State environment profile.", table: "Restore")
            )
        }
    }

    func loadProfile(_ profile: EnvironmentProfile, fileName: String) {
        importedSource = RestoreSource(kind: .file(name: fileName), profile: profile)
        tab = .importFile
    }

    // MARK: Selection

    func isSelected(_ item: ProfileItem, in source: RestoreSource) -> Bool {
        !(installExcluded[source.key]?.contains(item.id) ?? false)
    }

    func setSelected(_ selected: Bool, _ items: [ProfileItem], in source: RestoreSource) {
        var excluded = installExcluded[source.key] ?? []
        for item in items {
            if selected { excluded.remove(item.id) } else { excluded.insert(item.id) }
        }
        installExcluded[source.key] = excluded
    }

    func selectedInstallable(_ diff: ProfileDiff, in source: RestoreSource) -> [ProfileItem] {
        diff.installable.map(\.item).filter { isSelected($0, in: source) }
    }

    // MARK: Install

    /// Plans every provider that can run now behind one confirmation; the rest
    /// follow in later stages once their package manager exists.
    func install(_ source: RestoreSource, model: AppModel) {
        guard !isPreparing, stage == nil, model.pendingOperation == nil, let snapshot = model.snapshot else { return }
        let selected = selectedInstallable(EnvironmentRestore.diff(source.profile, snapshot: snapshot), in: source)
        prepareStage(source: source, selectedIDs: Set(selected.map(\.id)), step: 1, model: model)
    }

    func cancelStages() {
        stageTask?.cancel()
        stageTask = nil
        stage = nil
    }

    private func prepareStage(source: RestoreSource, selectedIDs: Set<String>, step: Int, model: AppModel) {
        guard let snapshot = model.snapshot, let actions = model.actions as? RestoreActions else {
            stage = nil
            return
        }
        let diff = EnvironmentRestore.diff(source.profile, snapshot: snapshot)
        let items = diff.installable.map(\.item).filter { selectedIDs.contains($0.id) }
        let plan = EnvironmentRestore.stages(for: items, snapshot: snapshot)
        guard !plan.ready.isEmpty else {
            stage = nil
            return
        }
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                let operation = try await actions.planInstall(plan.ready, snapshot: snapshot)
                model.pendingOperation = operation
                if plan.deferred.isEmpty {
                    stage = nil
                } else {
                    stage = Stage(sourceKey: source.key, step: step, waitingProviders: plan.deferred.map(\.provider))
                    continueAfter(operation, source: source, selectedIDs: selectedIDs, step: step, model: model)
                }
            } catch {
                stage = nil
                model.alert = AppAlert(title: String(localized: "Couldn't Prepare the Installation", table: "Restore"), message: error.localizedDescription)
            }
        }
    }

    /// Waits for the confirmation, the runs and the rescan that follows them, then
    /// plans the next stage against the fresh snapshot. Stops if the user cancels
    /// the sheet or a stage fails.
    private func continueAfter(_ operation: PreparedOperation, source: RestoreSource, selectedIDs: Set<String>, step: Int, model: AppModel) {
        stageTask?.cancel()
        let planIDs = Set(operation.plans.map(\.id))
        stageTask = Task { [weak self] in
            let poll = Duration.milliseconds(250)
            while model.pendingOperation?.id == operation.id {
                try? await Task.sleep(for: poll)
                if Task.isCancelled { return }
            }
            guard model.activity.contains(where: { planIDs.contains($0.id) }) else {
                self?.stage = nil
                return
            }

            var sawEveryRun = false
            var finishedAt: Date?
            var waitedForRescan = 0
            while !Task.isCancelled {
                let runs = model.activity.filter { planIDs.contains($0.id) }
                sawEveryRun = sawEveryRun || runs.count == planIDs.count
                if sawEveryRun, !runs.contains(where: \.isRunning) {
                    if runs.contains(where: { if case .succeeded = $0.state { false } else { true } }) {
                        self?.stage = nil
                        return
                    }
                    finishedAt = finishedAt ?? runs.compactMap(\.finishedAt).max() ?? .now
                    if !model.isScanning, let captured = model.snapshot?.capturedAt, let finishedAt, captured >= finishedAt { break }
                    waitedForRescan += 1
                    // The queue's own refresh was skipped (another scan was running): rescan here.
                    if waitedForRescan == 40, !model.isScanning { await model.refresh() }
                }
                try? await Task.sleep(for: poll)
            }
            guard !Task.isCancelled, let self else { return }
            self.prepareStage(source: source, selectedIDs: selectedIDs, step: step + 1, model: model)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
