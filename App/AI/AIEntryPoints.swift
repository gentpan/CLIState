import CLIStateDomain
import SwiftUI

/// "Explain with AI…" in the Tools table's context menu.
struct ExplainWithAIMenuItem: View {
    let tool: Tool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(value: AIExplanationTarget.tool(tool.id))
        } label: {
            Label {
                Text("Explain with AI…", tableName: "AI")
            } icon: {
                Image(systemName: AISymbol.explain)
            }
        }
    }
}

/// Button for the Tool Detail header.
struct ExplainWithAIButton: View {
    let tool: Tool
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(value: AIExplanationTarget.tool(tool.id))
        } label: {
            Label {
                Text("Explain with AI", tableName: "AI")
            } icon: {
                Image(systemName: AISymbol.explain)
            }
        }
        .help(Text("Ask AI what \(tool.identity.displayName) is and whether you need it", tableName: "AI"))
    }
}

/// Button for an issue row.
struct AskAIAboutIssueButton: View {
    let issue: HealthIssue
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            openWindow(value: AIExplanationTarget.issue(issue.id))
        } label: {
            Label {
                Text("Ask AI about this issue", tableName: "AI")
            } icon: {
                Image(systemName: AISymbol.explain)
            }
        }
    }
}

/// The explanation window scene. Added once in `CLIStateApp`.
struct AIExplanationScene: Scene {
    let model: AppModel
    let ai: AIModel

    var body: some Scene {
        WindowGroup(for: AIExplanationTarget.self) { $target in
            AIExplanationWindow(target: target)
                .environment(model)
                .environment(ai)
        }
        .defaultSize(width: AILayout.windowDefaultWidth, height: AILayout.windowDefaultHeight)
        .restorationBehavior(.disabled)
        .commandsRemoved()
    }
}

#if DEBUG
/// `-CLIStateAIExplain node` or `-CLIStateAIExplain issue:pathConflict:node` opens an
/// explanation at launch (screenshots, manual QA).
struct AIDebugLaunchModifier: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            guard let value = UserDefaults.standard.string(forKey: "CLIStateAIExplain") else { return }
            // Opening a second scene in the same launch pass is occasionally dropped.
            try? await Task.sleep(for: .seconds(1))
            if value.hasPrefix("issue:") {
                openWindow(value: AIExplanationTarget.issue(String(value.dropFirst("issue:".count))))
            } else {
                openWindow(value: AIExplanationTarget.tool(ToolID(value)))
            }
        }
    }
}
#endif

extension View {
    /// Debug-only launch hooks for AI explanations; no-op in Release.
    func aiLaunchOptions() -> some View {
        #if DEBUG
        modifier(AIDebugLaunchModifier())
        #else
        self
        #endif
    }
}
