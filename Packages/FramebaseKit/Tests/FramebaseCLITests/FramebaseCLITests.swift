import Foundation
import FramebaseCatalog
import FramebaseCLI
import FramebaseDomain
import FramebaseTestSupport
import Testing

@Suite("Framebase local CLI")
struct FramebaseCLITests {
    @Test("Read-only diagnostics, folders, and search return machine-readable catalog metadata")
    func readOnlyCommands() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FramebaseCLITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let catalogURL = directory.appending(path: "catalog.sqlite", directoryHint: .notDirectory)
        let catalog = try CatalogDatabase(catalogURL: catalogURL)
        let folder = try await catalog.folders.createFolder(named: FolderName("Reference"), in: nil)
        let asset = try FixtureFactory.asset(parentFolderID: folder.id, filename: "reference.jpg")
        try await catalog.insertAsset(asset)

        let diagnostics = try await FramebaseCLI.execute(arguments: ["diagnostics", "--catalog", catalogURL.path])
        #expect(diagnostics.contains("\"assetCount\" : 1"))
        #expect(!diagnostics.contains(catalogURL.path))

        let folders = try await FramebaseCLI.execute(arguments: ["list-folders", "--catalog", catalogURL.path])
        #expect(folders.contains("Reference"))

        let search = try await FramebaseCLI.execute(arguments: ["search", "--catalog", catalogURL.path, "--text", "reference"])
        #expect(search.contains("reference.jpg"))
        #expect(!search.contains("storageKey"))
    }

    @Test("CLI rejects missing or unsafe command shapes")
    func rejectsUnsupportedCommands() async throws {
        await #expect(throws: FramebaseCLIError.self) {
            _ = try await FramebaseCLI.execute(arguments: ["permanent-purge", "--catalog", "/tmp/catalog.sqlite"])
        }
        await #expect(throws: FramebaseCLIError.self) {
            _ = try await FramebaseCLI.execute(arguments: ["search", "--catalog", "/tmp/catalog.sqlite"])
        }
        #expect(try await FramebaseCLI.execute(arguments: ["--help"]).contains("proposal-first"))
    }

    @Test("CLI tag proposal stays dry until its exact opaque approval is applied")
    func proposalAndApplyUseTheSharedWorkflowBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FramebaseCLITests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let catalogURL = directory.appending(path: "catalog.sqlite", directoryHint: .notDirectory)
        let catalog = try CatalogDatabase(catalogURL: catalogURL)
        let asset = try FixtureFactory.asset(parentFolderID: catalog.inboxID, filename: "proposal.jpg")
        try await catalog.insertAsset(asset)
        let identityJSON = try await FramebaseCLI.execute(arguments: [
            "agent", "create", "--catalog", catalogURL.path, "--name", "Fixture agent",
            "--scope", "workflows.run", "--scope", "assets.organize"
        ])
        let identity = try JSONDecoder().decode(CLIAgentIdentity.self, from: Data(identityJSON.utf8))

        let proposalJSON = try await FramebaseCLI.execute(arguments: [
            "proposal", "tag", "--catalog", catalogURL.path,
            "--agent", identity.id, "--asset", asset.id.description, "--tag", "review:strong"
        ])
        let proposal = try JSONDecoder().decode(CLIProposal.self, from: Data(proposalJSON.utf8))
        #expect(proposal.dryRun)
        #expect(proposal.targetAssetIDs == [asset.id.description])
        #expect(try await catalog.tags.tags(for: [asset.id])[asset.id] == nil)
        let inspected = try await FramebaseCLI.execute(arguments: ["inspect", "--catalog", catalogURL.path, "--asset", asset.id.description])
        #expect(inspected.contains("proposal.jpg"))
        #expect(!inspected.contains("storageKey"))
        let pendingJSON = try await FramebaseCLI.execute(arguments: ["get-operation", "--catalog", catalogURL.path, "--operation", proposal.operationID])
        let pending = try JSONDecoder().decode(CLIOperation.self, from: Data(pendingJSON.utf8))
        #expect(pending.state == "awaitingApproval")

        let otherIdentityJSON = try await FramebaseCLI.execute(arguments: [
            "agent", "create", "--catalog", catalogURL.path, "--name", "Other fixture agent",
            "--scope", "workflows.run", "--scope", "assets.organize"
        ])
        let otherIdentity = try JSONDecoder().decode(CLIAgentIdentity.self, from: Data(otherIdentityJSON.utf8))

        await #expect(throws: FramebaseCLIError.invalidApprovalToken) {
            _ = try await FramebaseCLI.execute(arguments: ["apply", "--catalog", catalogURL.path, "--agent", otherIdentity.id, "--operation", proposal.operationID, "--approval", proposal.approvalToken])
        }
        #expect(try await catalog.tags.tags(for: [asset.id])[asset.id] == nil)

        let appliedJSON = try await FramebaseCLI.execute(arguments: ["apply", "--catalog", catalogURL.path, "--agent", identity.id, "--operation", proposal.operationID, "--approval", proposal.approvalToken])
        let applied = try JSONDecoder().decode(CLIOperation.self, from: Data(appliedJSON.utf8))
        #expect(applied.state == "succeeded")
        #expect(applied.auditKinds == ["planCreated", "proposalCreated", "approvalGranted", "executionStarted", "executionSucceeded"])
        #expect(applied.audit.allSatisfy { $0.agentIdentityID == identity.id && $0.originatingTool == "framebase-cli" })
        #expect(try await catalog.tags.tags(for: [asset.id])[asset.id]?.map(\.name.rawValue) == ["review:strong"])

        _ = try await FramebaseCLI.execute(arguments: ["agent", "revoke", "--catalog", catalogURL.path, "--agent", identity.id])
        await #expect(throws: FramebaseCLIError.agentIdentityUnavailable) {
            _ = try await FramebaseCLI.execute(arguments: [
                "proposal", "tag", "--catalog", catalogURL.path, "--agent", identity.id,
                "--asset", asset.id.description, "--tag", "review:strong"
            ])
        }
    }
}

private struct CLIProposal: Decodable {
    let operationID: String
    let targetAssetIDs: [String]
    let approvalToken: String
    let dryRun: Bool
}

private struct CLIOperation: Decodable {
    let state: String
    let auditKinds: [String]
    let audit: [CLIAuditEvent]
}

private struct CLIAgentIdentity: Decodable { let id: String }
private struct CLIAuditEvent: Decodable { let agentIdentityID: String?; let originatingTool: String? }
