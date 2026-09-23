import AppKit
import CLIStateDomain
import SwiftUI

struct SettingsView: View {
    enum Pane: String, CaseIterable {
        case general, updates, scanning, ai, about
    }

    /// Remembers the last pane; `-SettingsPane updates` selects one at launch.
    @AppStorage("SettingsPane") private var pane: Pane = .general

    var body: some View {
        VStack(spacing: 0) {
            DSTabs(selection: $pane, options: Pane.allCases, title: String(localized: "Settings")) { pane in
                switch pane {
                case .general: String(localized: "General")
                case .updates: String(localized: "Updates")
                case .scanning: String(localized: "Scanning")
                case .ai: String(localized: "AI", table: "AI")
                case .about: String(localized: "About")
                }
            }
            .padding(DS.Space.s4)
            Divider()
            Group {
                switch pane {
                case .general: GeneralSettings()
                case .updates: UpdateSettings()
                case .scanning: ScanningSettings()
                case .ai: AISettingsView()
                case .about: AboutSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .buttonStyle(.dsSecondary)
        .textFieldStyle(.dsField)
        .background(DS.Palette.background)
        .frame(height: DS.Layout.windowMinHeight)

        .frame(width: DS.Layout.settingsWidth)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var language = AppLanguage.stored()
    @State private var isRelaunching = false

    var body: some View {
        DSForm {
            Section {
                Picker("Appearance", selection: model.displayBinding(\.appearance)) {
                    ForEach(AppAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                Picker("Language", selection: $language) {
                    Text("System").tag(AppLanguage.system)
                    // Each language is named in itself, so it stays recognizable in either UI.
                    Text(verbatim: "简体中文").tag(AppLanguage.simplifiedChinese)
                    Text(verbatim: "English").tag(AppLanguage.english)
                }
                .onChange(of: language) { _, newValue in
                    newValue.store()
                }
                if language.needsRestart {
                    HStack(spacing: DS.Space.s3) {
                        Label {
                            Text("The new language applies after CLI State restarts.")
                                .foregroundStyle(DS.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: Symbol.info)
                                .foregroundStyle(DS.Palette.highlight)
                        }
                        .font(DS.Font.caption)
                        Spacer(minLength: DS.Space.s2)
                        Button("Restart Now") { relaunch() }
                            .buttonStyle(.dsPrimary)
                            .controlSize(.small)
                            .disabled(isRelaunching)
                    }
                }
            }

            Section {
                Toggle("Launch at login", isOn: model.displayBinding(\.launchAtLogin))
                // Menu bar extra; strings live in MenuBar.xcstrings.
                Toggle(isOn: model.displayBinding(\.showInMenuBar)) {
                    Text("Show in menu bar", tableName: "MenuBar")
                    Text("Updates and issues at a glance. CLI State keeps running after you close its window.", tableName: "MenuBar")
                }
            }
        }
        .padding(.bottom, DS.Space.s3)
        .dsScrollBackground()
    }

    private func relaunch() {
        isRelaunching = true
        Task {
            do {
                try await AppRelauncher.relaunch()
            } catch {
                isRelaunching = false
                model.alert = AppAlert(title: String(localized: "Couldn't restart CLI State"), message: error.localizedDescription)
            }
        }
    }

}

// MARK: - Updates

private struct UpdateSettings: View {
    @Environment(AppModel.self) private var model
    private let providers: [ProviderID] = [.homebrew, .npm, .uv, .pipx, .pnpm, .cargo, .native]

    var body: some View {
        DSForm {
            Section {
                Picker("Check for updates", selection: model.preferenceBinding(\.checkInterval)) {
                    ForEach(UpdateCheckInterval.allCases, id: \.self) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                Toggle(isOn: model.preferenceBinding(\.refreshMetadataBeforeCheck)) {
                    Text("Refresh package info before checking for updates")
                    Text("Runs brew update before every check, so newly released versions show up right away. It only updates package information, never installed tools.")
                }
            } header: {
                Text("Checking")
            } footer: {
                Text("Background checks run while CLI State is open, including from the menu bar.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }

            Section {
                DSTabs(selection: model.preferenceBinding(\.defaultPolicy), options: AutoUpdatePolicy.allCases, title: String(localized: "Default policy")) { $0.title }
                Text(model.preferences.defaultPolicy.explanation)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            } footer: {
                Text("A tool's setting overrides its provider's, and a provider's setting overrides the default.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }

            Section("Providers") {
                ForEach(providers, id: \.self) { provider in
                    Picker(selection: providerBinding(provider)) {
                        Text("Use Default (\(model.preferences.defaultPolicy.title))").tag(AutoUpdatePolicy?.none)
                        Divider()
                        ForEach(AutoUpdatePolicy.allCases, id: \.self) { policy in
                            Text(policy.title).tag(AutoUpdatePolicy?.some(policy))
                        }
                    } label: {
                        InstalledViaLabel(provider: provider)
                    }
                }
            }

            Section("Automatic updates") {
                Picker("Install", selection: model.preferenceBinding(\.automaticScope)) {
                    ForEach(AutoUpdateScope.allCases, id: \.self) { scope in
                        Text(scope.title).tag(scope)
                    }
                }
                Picker("Install after", selection: model.preferenceBinding(\.checkHour)) {
                    ForEach(0..<24, id: \.self) { hour in
                        Text(hourLabel(hour)).tag(hour)
                    }
                }
                Toggle("Only when connected to power", isOn: model.preferenceBinding(\.requiresACPower))
                Toggle("Notify me about updates and results", isOn: model.displayBinding(\.notificationsEnabled))
            }
        }
        .dsScrollBackground()
    }

    private func hourLabel(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func providerBinding(_ provider: ProviderID) -> Binding<AutoUpdatePolicy?> {
        Binding(
            get: { model.preferences.providerPolicies[provider] },
            set: { value in model.updatePreferences { $0.providerPolicies[provider] = value } }
        )
    }
}

// MARK: - Scanning

private struct ScanningSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        DSForm {
            Section {
                Toggle(isOn: model.displayBinding(\.showDependencies)) {
                    Text("Show dependencies")
                    Text("Packages installed only because another package needs them.")
                }
                Toggle(isOn: model.displayBinding(\.showUnrecognized)) {
                    Text("Show unrecognized tools")
                    Text("Executables in PATH that CLI State can't match to a package manager or known installer.")
                }
                Toggle(isOn: model.displayBinding(\.showSystemManaged)) {
                    Text("Show system-managed tools")
                    Text("Tools that ship with macOS, such as git and python3 in /usr/bin.")
                }
            }
        }
        .dsScrollBackground()
    }
}

// MARK: - About

private struct AboutSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(AppUpdater.self) private var updater

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        DSForm {
            Section {
                LabeledContent("Version") {
                    Text(version).font(DS.Font.mono).textSelection(.enabled)
                }
                LabeledContent("Feedback") {
                    Link(destination: URL(string: "mailto:feedback@clistate.com")!) {
                        Text(verbatim: "feedback@clistate.com")
                    }
                }
                LabeledContent("Contact & Partnerships") {
                    Link(destination: URL(string: "mailto:hello@clistate.com")!) {
                        Text(verbatim: "hello@clistate.com")
                    }
                }
                LabeledContent("GitHub") {
                    Link(destination: URL(string: "https://github.com/gentpan/CLIState/issues")!) {
                        Text("Report an Issue")
                    }
                }
                LabeledContent("Website") {
                    Link(destination: URL(string: "https://clistate.com")!) {
                        Text(verbatim: "clistate.com")
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: DS.Space.s1) {
                    Text(verbatim: "CLI State")
                        .font(DS.Font.title)
                        .foregroundStyle(DS.Palette.textPrimary)
                    Text("Understand and manage your Mac's command-line environment.")
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
                .padding(.bottom, DS.Space.s2)
            }

            Section {
                Toggle("Automatically check for CLI State updates", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                .disabled(!updater.isConfigured)
                if updater.hasUpdateServer {
                    Picker(selection: Binding(get: { updater.source }, set: { updater.setSource($0) })) {
                        ForEach(AppUpdateSource.allCases, id: \.self) { source in
                            Text(source.title).tag(source)
                        }
                    } label: {
                        Text("Download from")
                        Text("Automatic tries the update server first and uses GitHub when it can't be reached.")
                    }
                }
                Button("Check for CLI State Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            } header: {
                Text("App updates")
            } footer: {
                if !updater.isConfigured {
                    Text("App updates turn on once the first public release is published.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.textSecondary)
                }
            }

            Section {
                Button("Export Diagnostics…") { model.exportDiagnostics() }
            } header: {
                Text("Troubleshooting")
            } footer: {
                Text("Creates a zip with versions, PATH, package managers, issues and recent operations. Your home folder and account name are replaced, and no environment variables or command output are included.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.textSecondary)
            }
        }
        .dsScrollBackground()
    }
}

// MARK: - Opening

extension OpenSettingsAction {
    /// Opens Settings, or brings the already open window to the front.
    @MainActor
    func bringToFront() {
        callAsFunction()
        NSApp.activate()
    }
}

// MARK: - Bindings

extension AppModel {
    func preferenceBinding<Value>(_ keyPath: WritableKeyPath<UpdatePreferences, Value>) -> Binding<Value> {
        Binding(
            get: { self.preferences[keyPath: keyPath] },
            set: { value in self.updatePreferences { $0[keyPath: keyPath] = value } }
        )
    }

    func displayBinding<Value>(_ keyPath: WritableKeyPath<DisplaySettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.displaySettings[keyPath: keyPath] },
            set: { value in self.updateDisplaySettings { $0[keyPath: keyPath] = value } }
        )
    }
}
