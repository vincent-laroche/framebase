/// A declarative, non-destructive starter taxonomy for Hair Solutions Co.
///
/// This is catalog vocabulary only: consumers must create logical folders
/// through `FolderRepository`, never as filesystem paths. Tags are specified
/// here for the Phase 4 tag model; this Phase 3 addition does not persist or
/// assign tags to any library.
public struct LibraryFolderTemplate: Hashable, Sendable {
    public enum Provisioning: String, Hashable, Sendable {
        /// Create this logical folder when the template is applied.
        case initial
        /// Show this as available vocabulary, but create it only with a first asset.
        case onFirstUse
    }

    public let path: [String]
    public let provisioning: Provisioning

    public init(path: [String], provisioning: Provisioning) {
        self.path = path
        self.provisioning = provisioning
    }
}

public struct LibraryTagNamespaceTemplate: Hashable, Sendable {
    public let namespace: String
    public let allowedValues: [String]
    public let allowsCustomValues: Bool
    public let allowsMultipleValuesPerAsset: Bool

    public init(
        namespace: String,
        allowedValues: [String] = [],
        allowsCustomValues: Bool,
        allowsMultipleValuesPerAsset: Bool
    ) {
        self.namespace = namespace
        self.allowedValues = allowedValues
        self.allowsCustomValues = allowsCustomValues
        self.allowsMultipleValuesPerAsset = allowsMultipleValuesPerAsset
    }
}

/// The stable folder and cross-cutting-tag vocabulary supplied for the Hair
/// Solutions asset library. Folder names capture durable facts; mutable review
/// state belongs in `status:*` tags instead.
public enum HairSolutionsLibraryTemplate {
    public static let name = "Hair Solutions library"

    public static let folders: [LibraryFolderTemplate] = [
        initial("00_inbox"),
        initial("01_products"), initial("01_products/hair-systems"), initial("01_products/hair-systems/thin-skin-pro"),
        initial("01_products/hair-systems/thin-skin-pro/gallery"), initial("01_products/hair-systems/thin-skin-pro/raw"),
        onFirstUse("01_products/hair-systems/thin-skin-pro/renders"),
        initial("01_products/maintenance"), initial("01_products/maintenance/prohair-labs"),
        initial("01_products/maintenance/prohair-labs/gallery"), initial("01_products/maintenance/prohair-labs/raw"),
        initial("02_specs"), initial("02_specs/swatches"), initial("02_specs/swatches/curl-pattern"),
        initial("02_specs/swatches/base-material"), initial("02_specs/swatches/hairline-shape"),
        initial("02_specs/swatches/hair-direction"), initial("02_specs/swatches/hair-color"),
        initial("02_specs/swatches/density"), onFirstUse("02_specs/swatches/base-size"),
        onFirstUse("02_specs/swatches/grey-percentage"), initial("02_specs/icons"), initial("02_specs/diagrams"),
        initial("02_specs/guides"), initial("02_specs/guides/measuring"), initial("02_specs/guides/option-help"),
        initial("03_people"), initial("03_people/models"),
        initial("03_people/models/vincent"), initial("03_people/models/barry"), initial("03_people/models/serge"),
        initial("03_people/models/kevin"), initial("03_people/models/salem"), initial("03_people/models/danny"),
        initial("03_people/models/declan"), initial("03_people/models/kyle"), initial("03_people/models/alex"),
        initial("03_people/models/yago"), initial("03_people/founder"), initial("03_people/before-after"),
        initial("03_people/before-after/studio"), onFirstUse("03_people/before-after/customer-submitted"),
        initial("03_people/customers"), initial("03_people/customers/testimonials"), onFirstUse("03_people/customers/ugc"),
        initial("03_people/details"), initial("04_lifestyle"), initial("04_lifestyle/barber-salon"),
        initial("04_lifestyle/grooming"), initial("04_lifestyle/everyday"), onFirstUse("04_lifestyle/active"),
        onFirstUse("04_lifestyle/work"), onFirstUse("04_lifestyle/social"), initial("05_education"),
        initial("05_education/application"), onFirstUse("05_education/removal"), onFirstUse("05_education/care"),
        onFirstUse("05_education/styling"), initial("06_web"), initial("06_web/home"), initial("06_web/home/hero"),
        initial("06_web/home/process"), initial("06_web/home/featured"), initial("06_web/home/testimonials"),
        initial("06_web/about"), initial("06_web/about/hero"), initial("06_web/about/story"), initial("06_web/about/testimonials"),
        initial("06_web/contact"), initial("06_web/help-center"), initial("06_web/help-center/article-covers"),
        initial("06_web/help-center/category-covers"), initial("06_web/help-center/home"), initial("06_web/product-template"),
        initial("06_web/collections"), initial("06_web/collections/banners"), initial("06_web/portal"), initial("06_web/blog"),
        initial("06_web/blog/hair-systems-for-men"), initial("06_web/blog/maintenance-application-care"),
        initial("06_web/blog/product-comparisons-reviews"), initial("06_web/blog/style-lifestyle"),
        initial("06_web/blog/professionals-salons"), initial("06_web/blog/shared"), initial("06_web/global"),
        initial("06_web/global/promo-banners"), initial("06_web/global/parallax"), initial("06_web/global/og"),
        initial("07_brand"), initial("07_brand/logos"), initial("07_brand/logos/primary"),
        onFirstUse("07_brand/logos/variants"), initial("07_brand/logos/third-party"), initial("07_brand/ui"),
        initial("07_brand/ui/elements"), initial("07_brand/ui/icons"), initial("07_brand/ui/backgrounds"),
        initial("08_marketing"), initial("08_marketing/email"), initial("08_marketing/email/banners"),
        initial("08_marketing/campaigns"), initial("08_marketing/campaigns/2026-09-relaunch"),
        onFirstUse("08_marketing/social"), onFirstUse("08_marketing/ads"), initial("09_reference"),
        initial("09_reference/competitors"), initial("09_reference/ops-screenshots"), initial("09_reference/vendors"),
        onFirstUse("09_reference/inspiration"), initial("10_private"), initial("10_private/personal"), initial("10_private/sensitive")
    ]

    /// Values are always stored as lowercase `namespace:value` slugs. Do not
    /// duplicate the primary folder placement with a tag.
    public static let tagNamespaces: [LibraryTagNamespaceTemplate] = [
        .init(namespace: "status", allowedValues: ["review", "retouch", "approved", "archived"], allowsCustomValues: false, allowsMultipleValuesPerAsset: false),
        .init(namespace: "source", allowedValues: ["ai", "vendor", "studio", "customer", "stock", "partner"], allowsCustomValues: false, allowsMultipleValuesPerAsset: false),
        .init(namespace: "product", allowsCustomValues: true, allowsMultipleValuesPerAsset: true),
        .init(namespace: "article", allowsCustomValues: true, allowsMultipleValuesPerAsset: true),
        .init(namespace: "campaign", allowsCustomValues: true, allowsMultipleValuesPerAsset: true),
        .init(namespace: "channel", allowedValues: ["meta", "google", "instagram", "email"], allowsCustomValues: false, allowsMultipleValuesPerAsset: true),
        .init(namespace: "rights", allowedValues: ["internal-only", "vendor-provided", "licensed", "customer-consented"], allowsCustomValues: false, allowsMultipleValuesPerAsset: false)
    ]

    public static var initialFolders: [LibraryFolderTemplate] {
        folders.filter { $0.provisioning == .initial }
    }

    public static func tagNamespace(named namespace: String) -> LibraryTagNamespaceTemplate? {
        tagNamespaces.first { $0.namespace == namespace }
    }

    public static func validates(_ tagName: TagName) -> Bool {
        guard let template = tagNamespace(named: tagName.namespace) else { return true }
        return template.allowsCustomValues || template.allowedValues.contains(tagName.value)
    }

    private static func initial(_ path: String) -> LibraryFolderTemplate {
        LibraryFolderTemplate(path: path.split(separator: "/").map(String.init), provisioning: .initial)
    }

    private static func onFirstUse(_ path: String) -> LibraryFolderTemplate {
        LibraryFolderTemplate(path: path.split(separator: "/").map(String.init), provisioning: .onFirstUse)
    }
}
