import Foundation

/// A declarative starter taxonomy for one library space.
///
/// Templates create logical folders and `namespace:value` tags. They do not
/// import assets, move original bytes, or change immutable storage keys.
public protocol LibraryStarterTemplate {
    static var name: String { get }
    static var space: LibrarySpace { get }
    static var folders: [LibraryFolderTemplate] { get }
    static var tagNamespaces: [LibraryTagNamespaceTemplate] { get }
    static var initialCustomTagRawValues: [String] { get }
}

public extension LibraryStarterTemplate {
    static var initialFolders: [LibraryFolderTemplate] {
        folders.filter { $0.provisioning == .initial }
    }

    static var onFirstUseFolderPaths: [String] {
        folders
            .filter { $0.provisioning == .onFirstUse }
            .map { $0.path.joined(separator: "/") }
    }

    static func tagNamespace(named namespace: String) -> LibraryTagNamespaceTemplate? {
        tagNamespaces.first { $0.namespace == namespace }
    }

    static func validates(_ tagName: TagName) -> Bool {
        guard let template = tagNamespace(named: tagName.namespace) else { return true }
        return template.allowsCustomValues || template.allowedValues.contains(tagName.value)
    }

    static func initialTagNames() throws -> [TagName] {
        let controlled = try tagNamespaces.flatMap { namespace in
            try namespace.allowedValues.map { try TagName(namespace: namespace.namespace, value: $0) }
        }
        let explicit = try initialCustomTagRawValues.map(TagName.init)
        return (controlled + explicit).sorted { $0.rawValue < $1.rawValue }
    }
}

extension LibraryFolderTemplate {
    static func initialPath(_ path: String) -> LibraryFolderTemplate {
        LibraryFolderTemplate(
            path: path.split(separator: "/").map(String.init),
            provisioning: .initial
        )
    }
}
