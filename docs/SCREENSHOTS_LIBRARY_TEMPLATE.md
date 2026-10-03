# Screenshots library template

Starter taxonomy for screenshots and other non-photo junk. This is a separate library space, with its own catalog, not a tag or folder inside Personal or Hair Solutions.

Hair Solutions keeps `09_reference/ops-screenshots` as business reference material. That folder is not this library.

## Organizing rule

- A folder records a durable kind of capture: screenshots, documents, other captures, or files moved out of the live set.
- A tag records review state or a cross-cutting source/app with the existing `namespace:value` contract.
- Do not create status folders. Use `status:keep`, `status:review`, `status:duplicate`, `status:obsolete`, and `status:archived`.
- `discard` is where obsolete noise is moved so the live library does not have to keep today's pile.
- Applying the template creates empty folders and controlled tags. It does not import files.

## Folder tree

```text
screenshots
  desktop
  apps
  web
documents
  receipts
captures
discard
```

## Tag contract

| Namespace | Values / rule |
| --- | --- |
| `status` | Single value: `keep`, `review`, `duplicate`, `obsolete`, `archived` |
| `source` | Single value: `mac`, `phone`, `browser`, `app` |
| `app` | One or more custom slugs, such as `app:framebase` |

Tags do not replace the folder an asset already belongs to.
