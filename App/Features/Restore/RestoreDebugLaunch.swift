#if DEBUG
import CLIStateDomain
import Foundation

/// Debug-only launch arguments for restore screenshots and QA, with
/// `-CLIStateRoute restore`:
/// `-CLIStateRestoreTab export|import|templates`, `-CLIStateRestoreSample YES`
/// (loads the sample "old Mac" profile into Import), `-CLIStateRestoreTemplate <id>`,
/// `-CLIStateRestoreAction install` (opens the confirmation for the visible source),
/// `install-run` (also confirms every stage, to exercise staged installs),
/// `-CLIStateRestoreSuggest <text>` (runs an AI suggestion).
@MainActor
enum RestoreDebugLaunch {
    private static var didApply = false

    static func apply(restore: RestoreModel, model: AppModel, ai: AIModel) async {
        guard !didApply else { return }
        didApply = true
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "CLIStateRestoreSample") {
            restore.loadProfile(SampleRestore.profile(), fileName: SampleRestore.fileName)
        }
        if let id = defaults.string(forKey: "CLIStateRestoreTemplate") {
            restore.selectedTemplateID = id
            restore.tab = .templates
        }
        switch defaults.string(forKey: "CLIStateRestoreTab") {
        case "export": restore.tab = .export
        case "import": restore.tab = .importFile
        case "templates": restore.tab = .templates
        default: break
        }
        // `-CLIStateRestoreSuggest "Go 后端"` asks the configured AI provider right away.
        if let description = defaults.string(forKey: "CLIStateRestoreSuggest") {
            restore.tab = .templates
            restore.suggestion.description = description
            restore.suggestion.suggest(ai: ai)
        }
        let action = defaults.string(forKey: "CLIStateRestoreAction")
        guard action == "install" || action == "install-run" else { return }
        for _ in 0..<50 where model.snapshot == nil || model.isScanning {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let source = restore.tab == .templates ? restore.activeTemplatesSource : restore.importedSource
        guard let source else { return }
        restore.install(source, model: model)
        guard action == "install-run" else { return }
        model.isActivityExpanded = true
        // Confirm each stage as it appears; later stages are planned after the rescan.
        for _ in 0..<600 {
            if let operation = model.pendingOperation { model.confirm(operation) }
            if restore.stage == nil, model.pendingOperation == nil, !restore.isPreparing, !model.isOperationRunning, !model.isScanning { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}
#endif
