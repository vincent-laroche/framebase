import SwiftUI

struct FoundationSidebar: View {
    @Binding var selection: NavigationTarget?

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("All Assets", systemImage: "photo.on.rectangle.angled")
                    .tag(NavigationTarget.allAssets)
                Label("Inbox", systemImage: "tray")
                    .tag(NavigationTarget.inbox)
                Label("Favorites", systemImage: "heart")
                    .tag(NavigationTarget.favorites)
            }

            Section("Folders") {
                Text("No folders yet")
                    .foregroundStyle(.secondary)
            }

            Section("Albums") {
                Text("Album editing is deferred")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Framebase")
    }
}
