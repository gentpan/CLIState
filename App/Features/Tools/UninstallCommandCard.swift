import AppKit
import CLIStateDomain
import SwiftUI

struct UninstallCommandCard: View {
    let tool: Tool
    let installation: ToolInstallation
    @Environment(AppModel.self) private var model
    @State private var command: String?
    @State private var loading = true
    @State private var copied = false

    private var ref: InstallationRef {
        InstallationRef(toolID: tool.id, installationID: installation.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s2) {
            Divider()
            HStack {
                Text("Uninstall command").font(DS.Font.headline)
                Spacer()
                if let command {
                    Button {
                        NSPasteboard.general.clearContents()
                        copied = NSPasteboard.general.setString(command, forType: .string)
                    } label: {
                        Label(copied ? "Copied" : "Copy command", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.dsSecondary)
                }
            }
            if loading {
                ProgressView().controlSize(.small)
            } else if let command {
                Text(verbatim: command)
                    .font(DS.Font.mono)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .dsCard(padding: DS.Space.s2, nested: true)
            } else {
                Text("Command preview unavailable. Use Uninstall to review the operation.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            Text("Removes this installation. Review the confirmation before continuing.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Palette.textSecondary)
            Button(role: .destructive) {
                model.requestUninstall(ref)
            } label: {
                Label("Uninstall…", systemImage: Symbol.uninstall)
            }
            .disabled(model.isPreparingOperation || model.isOperationRunning)
        }
        .task(id: model.snapshot?.id) {
            loading = true
            command = nil
            copied = false
            do {
                let prepared = try await model.actions.planUninstall(ref, leftovers: [])
                guard !Task.isCancelled else { return }
                command = TerminalCommandText.render(prepared.plans.flatMap(\.plan.steps))
            } catch {
                guard !Task.isCancelled else { return }
                command = nil
            }
            loading = false
        }
    }
}
