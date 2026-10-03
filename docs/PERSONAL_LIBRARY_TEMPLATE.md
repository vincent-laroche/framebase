# Personal library template

Starter taxonomy for Vincent's private photo library. It is a logical catalog template for the Personal library space, not a copy of the Hair Solutions product tree and not a filesystem layout.

## Organizing rule

- A folder records a durable photo fact: people, place, event, project, or that the file was moved out of the active library.
- A tag records a changing or cross-cutting fact with the existing `namespace:value` contract.
- Do not create status folders. Use `status:keep`, `status:review`, `status:duplicate`, `status:obsolete`, and `status:archived`.
- `archive` is the durable folder for files that have been moved out. Duplicate and obsolete detection stay tags so today's duplicate pile is not treated as a permanent structure.
- Applying the template creates empty folders and controlled tags. It does not import or move originals.

## Folder tree

```text
people
  family
  portraits
places
  home
  travel
events
projects
archive
```

The system Inbox remains the catalog inbox. These folders are additional logical folders.

## Tag contract

| Namespace | Values / rule |
| --- | --- |
| `status` | Single value: `keep`, `review`, `duplicate`, `obsolete`, `archived` |
| `source` | Single value: `camera`, `phone`, `scan`, `shared` |
| `person` | One or more custom slugs |
| `place` | One or more custom slugs |

The template does not invent person or place names. Hair Solutions values such as `status:approved` and `product:*` are not part of this vocabulary.
