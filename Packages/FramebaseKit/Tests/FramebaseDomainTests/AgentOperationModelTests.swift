import Foundation
import FramebaseDomain
import Testing

@Suite("Agent operation contracts")
struct AgentOperationModelTests {
    private let assetID = AssetID(rawValue: UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!)

    @Test("Bulk agent mutations require an exact approval token")
    func bulkMutationRequiresApproval() throws {
        let identity = AgentIdentity(name: "Codex", scopes: [.assetsOrganize])
        let request = try AgentOperationRequest(
            operation: .moveAssets,
            targetAssetIDs: [assetID],
            catalogRevision: 42
        )

        #expect(request.requiresProposal)
        #expect(!request.canApply(as: identity, approval: nil, at: .now))

        let approval = try AgentApprovalToken(
            operationID: request.id,
            targetAssetIDs: request.targetAssetIDs,
            catalogRevision: 42,
            expiresAt: .distantFuture
        )
        #expect(request.canApply(as: identity, approval: approval, at: .now))
    }

    @Test("Revoked identities and undocumented purge are denied")
    func revokedIdentityAndPurgeDenial() throws {
        let identity = AgentIdentity(name: "Revoked tool", scopes: Set(AgentScope.allCases), status: .revoked)
        let request = try AgentOperationRequest(operation: .searchAssets, targetAssetIDs: [], catalogRevision: 42)

        #expect(!request.canApply(as: identity, approval: nil, at: .now))
        #expect(!AgentOperationKind.allCases.map(\.rawValue).contains("permanentPurge"))
    }

    @Test("Operation descriptions redact query data")
    func descriptionsRedactSensitiveParameters() throws {
        let request = try AgentOperationRequest(
            operation: .searchAssets,
            targetAssetIDs: [],
            catalogRevision: 42,
            parameters: .searchText("PRIVATE CUSTOMER OCR")
        )

        #expect(!request.description.contains("PRIVATE CUSTOMER OCR"))
        #expect(request.requiredScope == .libraryRead)
    }
}
