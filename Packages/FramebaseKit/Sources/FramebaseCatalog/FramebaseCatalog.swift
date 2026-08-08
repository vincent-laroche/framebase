import FramebaseDomain
import GRDB

public enum FramebaseCatalogFoundation {
    public static let initialSchemaVersion = 1

    public static func configure(_ configuration: inout Configuration) {
        configuration.foreignKeysEnabled = true
        configuration.label = "Framebase Catalog"
    }
}
