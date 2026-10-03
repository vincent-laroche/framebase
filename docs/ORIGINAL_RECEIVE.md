# Original receive

`framebase receive-originals` is the command a later bulk import of Vincent's Mac photos would call. This change does not run that import. It does not copy `/Users/vincent/04_systems/media_workshop/iPhoto export 2010-2026/`, delete local files, or delete iCloud Photos.

Originals go into the matching local library. Screenshots are not personal photos.

| Space | Package |
| --- | --- |
| `personal` | `~/Pictures/Personal Library.framebase`, or the existing `~/Pictures/Framebase Library.framebase` |
| `hairSolutions` | `~/Pictures/HSC Library.framebase` |
| `screenshots` | `~/Pictures/Screenshots Library.framebase` |

Those packages may be missing. Pass `--library` explicitly. The command creates the named package when it is missing and the name matches `--space`. It refuses a package that is already another space.

## Command

Local copy only, leaving every source file in place:

```sh
framebase receive-originals \
  --library "$HOME/Pictures/Personal Library.framebase" \
  --space personal \
  /path/to/one-photo-or-directory
```

The same bytes under another name, or on a later run, stay one asset in that library's Inbox. Identity is the SHA-256 of the original file. The command does not run OCR or any model API.

To also store those bytes in the development bucket, add the dev Worker URL and a device token that already has `assets.import`:

```sh
framebase receive-originals \
  --library "$HOME/Pictures/Personal Library.framebase" \
  --space personal \
  --api https://framebase-api-dev.notionsync.workers.dev \
  --token "$FRAMEBASE_DEV_TOKEN" \
  /path/to/one-photo-or-directory
```

Point the same command at a directory when a later bulk import is approved. Do not point it at the iPhoto export until that separate run. Do not pass a production URL. The command refuses `framebase-api-prod`, `framebase-blobs-prod`, `framebase-catalog-prod`, and `hsc-media-origin`.

JSON reports the library space, filename, asset id, `imported` or `alreadyPresent`, and whether the blob was `uploaded`, `alreadyInR2`, or `localOnly`. It does not include storage keys, managed-original paths, or presigned URLs.

## API a bulk import calls

Bytes never travel as the HTTP body of `framebase-api-dev`. That Worker is on `workers.dev`. The zone body cap is 100 MB on Free/Pro and 200 MB on Business, and the over-limit response is 413. Worker memory is 128 MB. Catalog calls are small JSON. The original is a direct upload to R2.

For an original at or under 5 GiB:

1. `POST /v1/blobs/upload-initiate` with `sha256`, `byteSize`, `mediaType`, and `originalExtension`.
2. If the response is `already_verified`, stop. The same bytes are already in the bucket.
3. Otherwise `PUT` the file to the returned `https://<account>.r2.cloudflarestorage.com/framebase-blobs-dev/blobs/sha256/<2 hex>/<hash>.<ext>` URL. Send the signed `Content-Type`. Do not send the file to the Worker.
4. `POST /v1/blobs/upload-complete` with only `sha256` and `byteSize`. The Worker streams the object from R2 and checks the SHA-256. It does not buffer the object.
5. `POST /v1/mutations` with `Idempotency-Key: receive-asset-<asset id>` and one `create_asset` whose `blobId` is the SHA-256, `folderId` is `system-inbox`, and `assetMetadata.librarySpace` is `personal`, `hairSolutions`, or `screenshots`. Replaying that key does not insert a second asset.

For an original larger than 5 GiB and at or under 5 TiB, use multipart. Parts are 8 MiB. Each part is a presigned `UploadPart` against the same bucket:

1. `POST /v1/blobs/multipart/initiate`
2. `POST /v1/blobs/multipart/<upload id>/parts/<n>/presign`
3. `PUT` that part directly to R2 and read the `ETag`
4. `POST /v1/blobs/multipart/<upload id>/parts/<n>/record` with `{ "etag", "byteSize" }`
5. `POST /v1/blobs/multipart/<upload id>/complete`
6. `POST /v1/blobs/multipart/<upload id>/confirm` with the original SHA-256 and byte size
7. The same `create_asset` mutation as above

`PUT /v1/blobs/multipart/<upload id>/parts/<n>` returns 413 `DIRECT_R2_REQUIRED`. A JSON body larger than 8 KB on the initiate, complete, or record routes also returns 413.

## Bucket

`framebase-blobs-dev` is the only bucket this path writes. It was verified read-only on 2026-10-03. Standard storage has no hard stop: past the account-wide 10 GB-month free tier it is $0.015 per GB-month. One object can be about 5 TiB. One `PutObject` tops out near 5 GiB. Multipart goes to about 5 TiB. The lifecycle rule only aborts an unfinished multipart upload after 7 days. There is no object lock, no CORS, and `r2.dev` is disabled. This change does not buy capacity, change billing, or change the bucket.

Class A operations are billed separately: 1 million free, then $4.50 per million, rounded up to the next million. Content-hash idempotency skips a second `PUT` when the bytes are already verified, which keeps that bill to one upload per distinct original.

The development catalog is the existing D1 database `framebase-catalog-dev`. Library separation stays the local `.framebase` package. Remote objects are content-addressed, so the same bytes are one R2 object even if two libraries name them. `assetMetadata.librarySpace` records which library the receive command targeted. This is not a production catalog and not a per-library production bucket.

No deploy is part of this change. The new Worker behavior is proven by local API tests against a fake bucket named `framebase-blobs-dev`. The live `framebase-api-dev` service still has the previous revision until a development deploy is approved. Before that deploy, `--api` can only complete originals the deployed Worker already accepts: a presigned PUT at or under 20 MiB. Larger originals, presigned multipart parts, and the Worker-body refusal land when that development deploy happens. Do not deploy production to get there.
