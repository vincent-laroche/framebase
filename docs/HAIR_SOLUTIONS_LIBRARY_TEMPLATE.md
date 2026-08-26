# Hair Solutions library template

This is the built-in Framebase starter taxonomy for the Hair Solutions visual library. It is a **logical catalog template**, not a filesystem tree and not a command to change an existing library. Applying it later must create folders through `FolderRepository`; original bytes and immutable storage keys never move.

## Organizing rule

- A folder records a stable fact: subject, product, page, person, or visual purpose.
- A tag records a cross-cutting or changing fact: review status, source, product used, article, campaign, channel, or rights.
- Do not create status folders such as `approved` or `needs-review`. Use `status:approved` and `status:review` instead.
- `gallery` and `raw` remain folders because they describe distinct, durable asset roles. An edited gallery export is a new asset; it does not turn a raw original into a gallery file.
- Every listed folder is created empty when the template is applied. Asset placement remains a separate, later review step.

## Folder tree

The canonical structure lives in `HairSolutionsLibraryTemplate.folders`. Its top-level logical folders are:

```text
00_inbox        flat triage inbox
01_products     product imagery and maintenance products
02_specs        swatches, icons, diagrams, and option guidance
03_people       models, founder, before/after, customers, detail shots
04_lifestyle    stable lifestyle scenes
05_education    application, removal, care, and styling
06_web          home, about, help center, collections, portal, blogs, global
07_brand        logos and UI artwork
08_marketing    email, campaigns, social, and ads
09_reference    competitors, operations, vendors, inspiration
10_private      personal and sensitive material
```

Key durable paths include `01_products/hair-systems/thin-skin-pro/{gallery,raw,renders}`, the named recurring people under `03_people/models`, the five Shopify blog handles under `06_web/blog`, and `08_marketing/campaigns/2026-09-relaunch`. The full declarative list creates every path in the supplied taxonomy immediately.

## Tag contract

Tags use lowercase `namespace:value` slugs. The eventual Phase 4 tag editor should enforce single-valued `status`, `source`, and `rights`, while allowing multiple products, articles, campaigns, and channels.

| Namespace | Values / rule |
| --- | --- |
| `status` | `review`, `retouch`, `approved`, `archived` |
| `source` | `ai`, `vendor`, `studio`, `customer`, `stock`, `partner` |
| `product` | One or more model slugs, e.g. `product:thin-skin-pro` |
| `article` | One or more Shopify article slugs, e.g. `article:how-to-apply-tape` |
| `campaign` | Campaign slug, e.g. `campaign:2026-09-relaunch` |
| `channel` | `meta`, `google`, `instagram`, `email` |
| `rights` | `internal-only`, `vendor-provided`, `licensed`, `customer-consented` |

The template creates all controlled values above, plus the three explicit examples from this structure: `product:thin-skin-pro`, `article:how-to-apply-tape`, and `campaign:2026-09-relaunch`. Other product, article, and campaign tags are created only when Vincent defines them; the template does not invent names.

This taxonomy is now represented in `FramebaseDomain` and tested, but it does not yet create a library, persist tags, or bulk-assign existing assets. Those actions belong to the focused Phase 4 organization plan and require an explicit apply/review flow.
