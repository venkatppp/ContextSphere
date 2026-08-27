import SwiftUI

extension LLMProviderType {
    var title: String {
        switch self {
        case .openai: "OpenAI"
        case .ollama: "Ollama"
        case .custom: "Custom"
        }
    }
}

/// Native macOS preferences experience for ContextSphere. Organized by
/// backend-owned settings domains; every control binds to
/// `SettingsViewModel`, which speaks JSON-RPC — the UI never touches
/// the database directly.
struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @State private var category: Category = .general
    @State private var showAPIKey = false

    private enum Category: String, CaseIterable, Identifiable {
        case general, watched, llm, security

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .watched: "Watched Paths"
            case .llm: "LLM"
            case .security: "Security"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .watched: "folder"
            case .llm: "cpu"
            case .security: "lock.shield"
            }
        }
    }

    var body: some View {
        Group {
            switch viewModel.phase {
            case .loading:
                LoadingView(label: "Loading settings…")
            case .failed:
                errorState
            case .loaded:
                content
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .task { await viewModel.refresh() }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.phase != .loaded)
                .help("Reload settings from the core daemon")
                .accessibilityLabel("Refresh settings")
            }
        }
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                categoryPicker
                categoryContent
            }
            .frame(maxWidth: Theme.contentMaxWidth)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
        .safeAreaInset(edge: .top, spacing: 8) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private var header: some View {
        ScreenHeader("Settings",
                     subtitle: "Configuration for \(category.title.lowercased()) · persisted by the core daemon.",
                     symbol: category.symbol)
    }

    private var categoryPicker: some View {
        Picker("Settings Category", selection: $category) {
            ForEach(Category.allCases) { category in
                Label(category.title, systemImage: category.symbol).tag(category)
            }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Settings category")
        .padding(.horizontal, 2)
    }

    private var errorState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Could not load settings").font(.title3.weight(.semibold))
            if case .failed(let message) = viewModel.phase {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Button("Retry") {
                Task { await viewModel.refresh() }
            }
            .accessibilityLabel("Retry loading settings")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch category {
        case .general: generalSection
        case .watched: watchedSection
        case .llm: llmSection
        case .security: securitySection
        }
    }

    // MARK: - General

    private var generalSection: some View {
        Form {
            Section {
                LabeledContent("Session inactivity threshold") {
                    Stepper(value: $viewModel.thresholdSeconds,
                            in: SettingsViewModel.thresholdRange, step: 60) {
                        Text("\(viewModel.thresholdSeconds) s")
                            .monospacedDigit()
                    }
                    .accessibilityLabel("Session inactivity threshold in seconds")
                    .help("A session ends after this long without activity")
                }
                if case .failed(let message) = viewModel.thresholdSave {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    Spacer()
                    if viewModel.thresholdDirty {
                        Button("Revert") { viewModel.revertThreshold() }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Revert session threshold changes")
                    }
                    statusBadge(viewModel.thresholdSave)
                }
            } header: {
                Text("Sessions")
            } footer: {
                Text("A session ends after 1 to 240 minutes without activity. Changes persist through the core daemon.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: viewModel.thresholdSeconds) { _, _ in
            viewModel.scheduleThresholdSave()
        }
    }

    // MARK: - Watched paths

    private var watchedSection: some View {
        Form {
            Section {
                if viewModel.watchedPaths.isEmpty {
                    Text("No watched directories. Add one below to start tracking activity.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.watchedPaths, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.tint)
                            Text(path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            if let error = viewModel.watchPathErrors[path] {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                    .help(error)
                                    .accessibilityLabel(error)
                            }
                            Button {
                                Task { await viewModel.removeWatchPath(path) }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Stop watching this directory")
                            .accessibilityLabel("Remove \(path) from watched paths")
                        }
                    }
                }
            } header: {
                Text("Watched directories")
            } footer: {
                Text("ContextSphere watches these directories for activity. Changes persist immediately.")
            }

            Section {
                HStack(spacing: 8) {
                    TextField("Directory path", text: $viewModel.watchPathInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Directory path to watch")
                        .onSubmit {
                            Task { await viewModel.addWatchPath() }
                        }
                    Button("Browse…") { viewModel.chooseWatchPath() }
                        .accessibilityLabel("Choose a directory to watch")
                    Button("Add") {
                        Task { await viewModel.addWatchPath() }
                    }
                    .disabled(viewModel.watchPathInput
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("Add directory to watched paths")
                }
                if case .failed(let message) = viewModel.watchAddState {
                    Text(message).font(.caption).foregroundStyle(.red)
                } else if case .saved = viewModel.watchAddState {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                }
            } header: {
                Text("Add")
            } footer: {
                Text("The core daemon validates the path before watching it.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - LLM

    private var llmSection: some View {
        Form {
            Section {
                Picker("Provider", selection: $viewModel.llmDraft.provider) {
                    ForEach(LLMProviderType.allCases, id: \.self) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .accessibilityLabel("LLM provider")
                TextField("Base URL", text: $viewModel.llmDraft.baseUrl)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("LLM base URL")
                TextField("Model", text: $viewModel.llmDraft.model)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("LLM model name")
                HStack {
                    Text("API key")
                    Spacer()
                    if showAPIKey {
                        TextField("API key", text: $viewModel.llmDraft.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 240)
                            .accessibilityLabel("LLM API key")
                    } else {
                        SecureField("API key", text: $viewModel.llmDraft.apiKey)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 240)
                            .accessibilityLabel("LLM API key")
                    }
                    Button(showAPIKey ? "Hide" : "Show") { showAPIKey.toggle() }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(showAPIKey ? "Hide API key" : "Show API key")
                }
            } header: {
                Text("Provider")
            } footer: {
                Text("The API key is stored by the core daemon in the system keychain — never by the app UI.")
            }

            Section {
                HStack {
                    Text("Temperature")
                    Slider(value: $viewModel.llmDraft.temperature,
                           in: SettingsViewModel.temperatureRange, step: 0.1)
                        .accessibilityLabel("Temperature")
                    Text(viewModel.llmDraft.temperature,
                         format: .number.precision(.fractionLength(1)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
                LabeledContent("Max tokens") {
                    Stepper(value: $viewModel.llmDraft.maxTokens,
                            in: 1...100_000_000, step: 1000) {
                        Text(viewModel.llmDraft.maxTokens.formatted())
                            .monospacedDigit()
                    }
                    .accessibilityLabel("Max tokens")
                }
                LabeledContent("Context window") {
                    Stepper(value: $viewModel.llmDraft.contextWindow,
                            in: 1...100_000_000, step: 1000) {
                        Text(viewModel.llmDraft.contextWindow.formatted())
                            .monospacedDigit()
                    }
                    .accessibilityLabel("Context window size")
                }
            } header: {
                Text("Generation")
            } footer: {
                Text("Values are validated against the backend before saving.")
            }

            Section {
                HStack {
                    Button("Save") {
                        Task { await viewModel.saveLLM() }
                    }
                    .disabled(!viewModel.llmDirty)
                    .accessibilityLabel("Save LLM settings")
                    Button("Test Connection") {
                        Task { await viewModel.testLLM() }
                    }
                    .accessibilityLabel("Test LLM connection")
                    if viewModel.llmDirty {
                        Button("Revert") { viewModel.revertLLM() }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Revert LLM settings changes")
                    }
                    Spacer()
                    statusBadge(viewModel.llmSave)
                    statusBadge(viewModel.llmTest, savedTitle: "Connected")
                }
                if case .failed(let message) = viewModel.llmSave {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                if case .failed(let message) = viewModel.llmTest {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Apply")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Saving persists the whole provider configuration through the core daemon.")
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text("Memory & Learning capture completed planner executions. Configure a provider to enable planning — file edits alone don’t create memories.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Security

    private var securitySection: some View {
        Form {
            Section {
                securityStepperRow(title: "Monitor interval",
                                   value: $viewModel.monitorIntervalSeconds,
                                   range: SettingsViewModel.monitorRange,
                                   step: 30,
                                   unit: "s",
                                   key: SettingsViewModel.monitorKey,
                                   dirty: viewModel.monitorDirty)
                securityStepperRow(title: "Audit log retention",
                                   value: $viewModel.auditRetentionDays,
                                   range: SettingsViewModel.retentionRange,
                                   step: 1,
                                   unit: "days",
                                   key: SettingsViewModel.auditKey,
                                   dirty: viewModel.auditDirty)
                securityStepperRow(title: "Findings history retention",
                                   value: $viewModel.findingsRetentionDays,
                                   range: SettingsViewModel.retentionRange,
                                   step: 1,
                                   unit: "days",
                                   key: SettingsViewModel.findingsKey,
                                   dirty: viewModel.findingsDirty)
            } header: {
                Text("Policy")
            } footer: {
                Text("Security policy persisted by the core daemon. Unset values use the backend defaults; out-of-band values are rejected.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: viewModel.monitorIntervalSeconds) { _, _ in
            viewModel.scheduleSecuritySave(key: SettingsViewModel.monitorKey,
                                           value: viewModel.monitorIntervalSeconds)
        }
        .onChange(of: viewModel.auditRetentionDays) { _, _ in
            viewModel.scheduleSecuritySave(key: SettingsViewModel.auditKey,
                                           value: viewModel.auditRetentionDays)
        }
        .onChange(of: viewModel.findingsRetentionDays) { _, _ in
            viewModel.scheduleSecuritySave(key: SettingsViewModel.findingsKey,
                                           value: viewModel.findingsRetentionDays)
        }
    }

    private func securityStepperRow(title: String, value: Binding<Int>,
                                    range: ClosedRange<Int>, step: Int,
                                    unit: String, key: String,
                                    dirty: Bool) -> some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Stepper(value: value, in: range, step: step) {
                    Text("\(value.wrappedValue) \(unit)")
                        .monospacedDigit()
                }
                .accessibilityLabel(title)
                if dirty {
                    Button("Revert") { viewModel.revertSecurity(key: key) }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Revert \(title)")
                }
                statusBadge(viewModel.securitySave[key] ?? .idle)
            }
        }
    }

    // MARK: - Shared status feedback

    @ViewBuilder
    private func statusBadge(_ state: SettingsSaveState, savedTitle: String = "Saved") -> some View {
        switch state {
        case .idle:
            EmptyView()
        case .saving:
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text("Working…").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityLabel("Working")
        case .saved:
            Label(savedTitle, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityLabel(savedTitle)
        case .failed(let message):
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .help(message)
                .accessibilityLabel("Failed: \(message)")
        }
    }
}