import SwiftUI
import AppKit

extension LLMProviderType {
    var title: String {
        switch self {
        case .openai: "OpenAI"
        case .ollama: "Ollama"
        case .custom: "Custom"
        }
    }
}

/// Native macOS preferences experience for ContextSphere. Organized as a
/// real settings window: a sidebar of categories, a detail pane for each,
/// every control binds to `SettingsViewModel`, which speaks JSON-RPC — the
/// UI never touches the database directly.
struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @State private var category: Category = .general
    @State private var showAPIKey = false
    @State private var categorySearch: String = ""

    enum Category: String, CaseIterable, Identifiable, Hashable {
        case general, watched, llm, security

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: "General"
            case .watched: "Watched Paths"
            case .llm: "LLM & Copilot"
            case .security: "Security"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .watched: "folder.badge.gearshape"
            case .llm: "cpu"
            case .security: "lock.shield"
            }
        }

        var summary: String {
            switch self {
            case .general: "Session and behavior preferences."
            case .watched: "Folders ContextSphere observes for activity."
            case .llm: "Optional. Pluggable intelligence for planning & explanations."
            case .security: "Background monitoring and audit retention."
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
        .frame(minWidth: 760, minHeight: 540)
        .task { await viewModel.refresh() }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(category.title)
                    .font(.system(size: 13, weight: .semibold))
            }
            ToolbarItem(placement: .primaryAction) {
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

    // MARK: - Content (split layout)

    private var content: some View {
        NavigationSplitView {
            categoryList
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var categoryList: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 6)
            List(selection: $category) {
                Section {
                    ForEach(filteredCategories) { cat in
                        categoryRow(cat)
                            .tag(cat)
                            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                            .listRowSeparator(.hidden)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text("Categories")
                            .font(.csEyebrow(size: 10))
                            .tracking(0.7)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }
                .listSectionSeparator(.hidden)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(.regularMaterial)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search settings", text: $categorySearch)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityLabel("Search settings categories")
            if !categorySearch.isEmpty {
                Button {
                    categorySearch = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var filteredCategories: [Category] {
        let trimmed = categorySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Category.allCases }
        return Category.allCases.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    private func categoryRow(_ cat: Category) -> some View {
        HStack(spacing: 8) {
            Image(systemName: cat.symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 18)
                .foregroundStyle(.tint)
            Text(cat.title)
                .font(.system(size: 13))
            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .accessibilityLabel(cat.title)
    }

    private var detailColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                detailHeader
                detailContent
            }
            .frame(maxWidth: Theme.contentMaxWidth, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollEdgeEffectStyle(.soft, for: .vertical)
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: category.symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.tint)
                Text(category.title)
                    .font(.csScreenTitle)
                    .tracking(-0.4)
            }
            Text(category.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var detailContent: some View {
        switch category {
        case .general: generalSection
        case .watched: watchedSection
        case .llm: llmSection
        case .security: securitySection
        }
    }

    private var errorState: some View {
        EmptyStateView(
            title: "Could not load settings",
            message: viewModel.lastErrorMessage ?? "Unknown error.",
            symbol: "exclamationmark.triangle",
            primaryAction: ("Retry", { Task { await viewModel.refresh() } })
        )
    }

    // MARK: - General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Sessions", subtitle: "When a work session ends",
                         symbol: "clock.arrow.circlepath") {
                LabeledContent("Session inactivity threshold") {
                    Stepper(value: $viewModel.thresholdSeconds,
                            in: SettingsViewModel.thresholdRange, step: 60) {
                        Text(formattedDuration(viewModel.thresholdSeconds))
                            .monospacedDigit()
                    }
                    .accessibilityLabel("Session inactivity threshold")
                    .help("A session ends after this long without activity")
                }
                if case .failed(let message) = viewModel.thresholdSave {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                HStack {
                    if viewModel.thresholdDirty {
                        Button("Revert") { viewModel.revertThreshold() }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Revert session threshold changes")
                    }
                    Spacer()
                    statusBadge(viewModel.thresholdSave)
                }
            }
        }
        .onChange(of: viewModel.thresholdSeconds) { _, _ in
            viewModel.scheduleThresholdSave()
        }
    }

    private func formattedDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    // MARK: - Watched paths

    private var watchedSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Watched directories",
                         subtitle: "Folders ContextSphere observes for activity",
                         symbol: "folder.badge.gearshape") {
                if viewModel.watchedPaths.isEmpty {
                    Text("No watched directories. Add one below to start tracking activity.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.watchedPaths, id: \.self) { path in
                        watchedPathRow(path)
                    }
                }
            }

            SettingsCard(title: "Add a directory",
                         subtitle: "The core daemon validates the path before watching it",
                         symbol: "plus.circle") {
                HStack(spacing: 8) {
                    TextField("/path/to/folder", text: $viewModel.watchPathInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Directory path to watch")
                        .onSubmit {
                            Task { await viewModel.addWatchPath() }
                        }
                    Button("Choose…") { viewModel.chooseWatchPath() }
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
            }
        }
    }

    private func watchedPathRow(_ path: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder.fill")
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
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Stop watching this directory")
            .accessibilityLabel("Remove \(path) from watched paths")
        }
        .padding(.vertical, 2)
    }

    // MARK: - LLM

    private var llmSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Trust banner
            SettingsCard(title: "About this section",
                         subtitle: "Local by default, remote only when you choose",
                         symbol: "lock.shield") {
                Text("ContextSphere runs entirely on this Mac. Configuring a remote LLM here is **optional** and only used when you invoke the planner or ask for an explanation. ContextSphere never sends code or file contents automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard(title: "Provider",
                         subtitle: "Pick a backend for planner and explanations",
                         symbol: "cpu") {
                Picker("Provider", selection: $viewModel.llmDraft.provider) {
                    ForEach(LLMProviderType.allCases, id: \.self) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .accessibilityLabel("LLM provider")
                LabeledContent("Base URL") {
                    TextField("https://api.openai.com/v1", text: $viewModel.llmDraft.baseUrl)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("LLM base URL")
                }
                LabeledContent("Model") {
                    TextField("gpt-4o-mini", text: $viewModel.llmDraft.model)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("LLM model name")
                }
                LabeledContent("API key") {
                    HStack(spacing: 6) {
                        Group {
                            if showAPIKey {
                                TextField("sk-…", text: $viewModel.llmDraft.apiKey)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                SecureField("sk-…", text: $viewModel.llmDraft.apiKey)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        .accessibilityLabel("LLM API key")
                        Button(showAPIKey ? "Hide" : "Show") { showAPIKey.toggle() }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(showAPIKey ? "Hide API key" : "Show API key")
                    }
                }
                Text("The API key is stored in the macOS Keychain by the core daemon. The app UI never persists it.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard(title: "Generation",
                         subtitle: "Validated by the backend before saving",
                         symbol: "slider.horizontal.3") {
                LabeledContent("Temperature") {
                    HStack(spacing: 8) {
                        Slider(value: $viewModel.llmDraft.temperature,
                               in: SettingsViewModel.temperatureRange, step: 0.1)
                            .accessibilityLabel("Temperature")
                        Text(viewModel.llmDraft.temperature,
                             format: .number.precision(.fractionLength(1)))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
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
            }

            SettingsCard(title: "Apply",
                         subtitle: "Save to the core daemon, then test the connection",
                         symbol: "checkmark.seal") {
                HStack(spacing: 8) {
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
                Text("Saving persists the whole provider configuration through the core daemon. Memory & Learning capture completed planner executions — configure a provider to enable planning. File edits alone don't create memories.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Security

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: "Policy",
                         subtitle: "Unset values use the backend defaults",
                         symbol: "lock.shield") {
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
            }
        }
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

// MARK: - Settings card

/// A native settings card: a section title with optional subtitle, a
/// symbol, and a content slot bound to native form-style controls.
struct SettingsCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.tint)
                }
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                if let subtitle {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                .strokeBorder(.separator.opacity(0.4), lineWidth: 0.5)
        )
    }
}

extension SettingsViewModel {
    var lastErrorMessage: String? {
        if case .failed(let msg) = phase { return msg }
        return nil
    }
}
