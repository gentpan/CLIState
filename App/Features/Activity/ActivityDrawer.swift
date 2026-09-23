import CLIStateDomain
import SwiftUI

/// Bottom panel with streamed output of running and recent operations.
struct ActivityDrawer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedRunID: UUID?

    var body: some View {
        let runs = model.activity
        let run = runs.first { $0.id == selectedRunID } ?? runs.last
        VStack(spacing: 0) {
            Divider()
            if let run {
                bar(run)
                if model.isActivityExpanded {
                    Divider()
                    OutputView(run: run, reduceMotion: reduceMotion)
                        .id(run.id)
                        .frame(height: DS.Layout.drawerHeight)
                        .transition(reduceMotion ? .identity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .background(DS.Palette.panelPrimary)
        .dsAnimation(model.isActivityExpanded, reduceMotion: reduceMotion)
        .onChange(of: runs.last?.id) { _, newValue in
            selectedRunID = newValue
        }
    }

    private func bar(_ run: ActivityRun) -> some View {
        HStack(spacing: DS.Space.s3) {
            Button {
                model.isActivityExpanded.toggle()
            } label: {
                Label(model.isActivityExpanded ? LocalizedStringKey("Hide Activity") : LocalizedStringKey("Show Activity"),
                      systemImage: model.isActivityExpanded ? Symbol.chevronDown : Symbol.chevronUp)
                    .labelStyle(.iconOnly)
                    .frame(width: DS.IconSize.standalone, height: DS.IconSize.standalone)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.dsSecondary)
            .help(model.isActivityExpanded ? Text("Hide Activity") : Text("Show Activity"))

            Text("Activity")
                .font(DS.Font.captionEmphasis)
                .foregroundStyle(DS.Palette.textSecondary)

            if model.activity.count > 1 {
                Picker(selection: Binding(get: { run.id }, set: { selectedRunID = $0 })) {
                    ForEach(model.activity.reversed()) { item in
                        Text(item.title).tag(item.id)
                    }
                } label: {
                    Text("Operation")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            } else {
                Text(run.title)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Palette.textPrimary)
            }

            RunStatus(state: run.state)
                .frame(maxWidth: .infinity, alignment: .leading)

            if case .failed = run.state, !model.isActivityExpanded {
                Button("View Output") {
                    model.isActivityExpanded = true
                }
                .controlSize(.small)
            }
            if !model.isOperationRunning {
                Button {
                    selectedRunID = nil
                    model.clearFinishedActivity()
                } label: {
                    Label("Clear Activity", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.dsSecondary)
                .help(Text("Clear Activity"))
            }
        }
        .padding(.horizontal, DS.Space.s3)
        .padding(.vertical, DS.Space.s2)
    }
}

private struct RunStatus: View {
    let state: ActivityRun.State

    var body: some View {
        switch state {
        case .running:
            HStack(spacing: DS.Space.s2) {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
                Text("Running…")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
            .accessibilityElement(children: .combine)
        case let .succeeded(message):
            IconText(symbol: StatusKind.latest.symbol, text: message, tint: DS.Palette.success, textColor: DS.Palette.textPrimary)
                .help(message)
        case let .attention(message):
            IconText(symbol: StatusKind.needsAttention.symbol, text: message, tint: DS.Palette.warning, textColor: DS.Palette.textPrimary)
                .help(message)
        case let .failed(message):
            // One line in the bar; the full message stays available when a narrow window truncates it.
            IconText(symbol: Symbol.failed, text: message, tint: DS.Palette.error, textColor: DS.Palette.textPrimary)
                .help(message)
        }
    }
}

private struct OutputView: View {
    let run: ActivityRun
    let reduceMotion: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if run.omittedLineCount > 0 {
                        Text("Showing the last \(run.lines.count) lines")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Palette.textTertiary)
                            .padding(.bottom, DS.Space.s1)
                    }
                    ForEach(run.lines) { line in
                        Text(line.text)
                            .font(DS.Font.mono)
                            .foregroundStyle(color(line.kind))
                            .fontWeight(line.kind == .command ? .semibold : .regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                    if run.lines.isEmpty {
                        Group {
                            if run.isRunning {
                                Text("Waiting for output…")
                            } else {
                                Text("No command output was captured.")
                            }
                        }
                            .font(DS.Font.mono)
                            .foregroundStyle(DS.Palette.textTertiary)
                    }
                }
                .padding(DS.Space.s3)
            }
            .background(DS.Palette.panelSecondary)
            .onChange(of: run.lines.last?.id) { _, newValue in
                guard let newValue else { return }
                if reduceMotion {
                    proxy.scrollTo(newValue, anchor: .bottom)
                } else {
                    withAnimation(DS.Motion.standard) { proxy.scrollTo(newValue, anchor: .bottom) }
                }
            }
            .accessibilityLabel(Text("Command output"))
        }
    }

    private func color(_ kind: ActivityLine.Kind) -> Color {
        switch kind {
        case .command: DS.Palette.textPrimary
        case .output: DS.Palette.textSecondary
        case .error: DS.Palette.error
        }
    }
}
