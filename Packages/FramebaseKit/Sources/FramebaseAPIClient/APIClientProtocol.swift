import Foundation

/// A device-authenticated client for the `framebase-api-dev` `/v1` contract
/// defined in `Cloud/apps/api` and `docs/phases/PHASE_2_CLOUD_FOUNDATION.md`.
public protocol APIClientProtocol: Sendable {
    /// `GET /v1/health`. Public, no credential required.
    func health() async throws -> HealthResponse

    /// `POST /v1/auth/enroll`. Public, gated by `enrollmentSecret` rather than
    /// a bearer token; issues the session JWT other calls depend on.
    func enroll(enrollmentSecret: String, request: EnrollRequest) async throws -> EnrollResponse

    /// `GET /v1/changes?after=&limit=`. Requires `library.read`.
    func fetchChanges(after: Int, limit: Int) async throws -> ChangesResponse

    /// `POST /v1/blobs/upload-initiate`. Requires `assets.import`.
    func initiateBlobUpload(_ request: BlobUploadInitiateRequest) async throws -> BlobUploadInitiateResponse

    /// `PUT /v1/blobs/upload-direct?key=...`. Requires `assets.import`.
    /// `relativePath` is the `uploadUrl` returned by `initiateBlobUpload`.
    func uploadBlobBytes(
        _ data: Data,
        contentType: String,
        toRelativePath relativePath: String
    ) async throws -> BlobUploadDirectResponse

    /// Uploads an original from a file URL so callers do not need to hold the
    /// whole binary in memory. The file must remain readable for the duration
    /// of the call.
    func uploadBlobFile(
        at fileURL: URL,
        contentType: String,
        toRelativePath relativePath: String
    ) async throws -> BlobUploadDirectResponse

    /// `POST /v1/blobs/upload-complete`. Requires `assets.import`.
    func completeBlobUpload(_ request: BlobUploadCompleteRequest) async throws -> BlobUploadCompleteResponse

    /// `GET /v1/blobs/:id/download`. Requires `originals.download`.
    func downloadBlob(id: String) async throws -> BlobDownload

    /// `POST /v1/assets/register`. Requires `assets.import` and a verified
    /// remote blob. Preserves the caller's existing logical Asset ID.
    func registerAsset(_ request: AssetRegistrationRequest, idempotencyKey: String) async throws -> AssetRegistrationResponse

    /// `POST /v1/mutations`. Scope requirements vary per operation type; the
    /// server checks them. `idempotencyKey` is sent as the `Idempotency-Key`
    /// header, which the server prefers over the request body's
    /// `clientMutationId` when both are present.
    func submitMutations(_ request: MutationsRequest, idempotencyKey: String) async throws -> MutationsResponse
}
