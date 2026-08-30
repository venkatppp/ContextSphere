import SwiftUI

@main
struct ContextSphereApp: App {
    var body: some Scene {
        WindowGroup(id: "main") {
            LaunchRoot {
                RootEnvironment {
                    AppShell()
                        .environmentObject(AppRouter.shared)
                        .frame(minWidth: 940, minHeight: 640)
                }
            }
        }
        .defaultSize(width: 1280, height: 860)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Divider()
                Button("New Workspace…") {
                    AppRouter.shared.selection = .workspaces
                    AppRouter.shared.newWorkspaceRequest = true
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("Open Command Palette") {
                    AppRouter.shared.showCommandPalette = true
                }
                .keyboardShortcut("k", modifiers: .command)
            }

            CommandMenu("Navigate") {
                ForEach(NavGroup.allCases) { group in
                    Menu(group.title) {
                        ForEach(group.sections) { section in
                            Button {
                                AppRouter.shared.selection = section
                            } label: {
                                Label(section.title, systemImage: section.symbol)
                            }
                            .keyboardShortcut(section.shortcutKey, modifiers: .command)
                        }
                    }
                }
            }
        }

        Settings {
            RootEnvironment {
                SettingsView()
                    .frame(minWidth: 760, minHeight: 540)
            }
        }
    }
}

extension View {
    /// Applies a keyboard shortcut only when a key is provided.
    @ViewBuilder
    func keyboardShortcut(_ key: KeyEquivalent?, modifiers: EventModifiers = .command) -> some View {
        if let key {
            keyboardShortcut(key, modifiers: modifiers)
        } else {
            self
        }
    }
}