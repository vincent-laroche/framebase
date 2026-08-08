import SwiftUI

@MainActor
struct LibraryCommandActions {
    let importAssets: () -> Void
    let selectAll: () -> Void
    let toggleInspector: () -> Void
    let canImport: Bool
    let canSelectAll: Bool
}

private struct LibraryCommandActionsKey: FocusedValueKey {
    typealias Value = LibraryCommandActions
}

extension FocusedValues {
    var libraryCommandActions: LibraryCommandActions? {
        get { self[LibraryCommandActionsKey.self] }
        set { self[LibraryCommandActionsKey.self] = newValue }
    }
}

struct FramebaseCommands: Commands {
    @FocusedValue(\.libraryCommandActions) private var actions

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Import Assets…") {
                actions?.importAssets()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(actions?.canImport != true)
        }

        CommandMenu("Assets") {
            Button("Select All") {
                actions?.selectAll()
            }
            .keyboardShortcut("a")
            .disabled(actions?.canSelectAll != true)
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Inspector") {
                actions?.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(actions == nil)
        }
    }
}
