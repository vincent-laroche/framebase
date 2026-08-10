import Foundation
import FramebaseDomain
import GRDB

public struct CatalogAgentIdentityRepository: AgentIdentityRepository, Sendable {
    private let databasePool: DatabasePool

    init(databasePool: DatabasePool) { self.databasePool = databasePool }

    public func create(_ identity: AgentIdentity, at date: Date = Date()) async throws {
        let scopes = String(decoding: try JSONEncoder().encode(identity.scopes.map(\.rawValue).sorted()), as: UTF8.self)
        let milliseconds = CatalogDate.milliseconds(date)
        try await databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO agent_identities (id, name, scopes_json, status, created_at_ms, updated_at_ms)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO NOTHING
                """, arguments: [identity.id.uuidString.lowercased(), identity.name, scopes, identity.status.rawValue, milliseconds, milliseconds])
        }
    }

    public func identity(id: UUID) async throws -> AgentIdentity? {
        try await databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM agent_identities WHERE id = ?", arguments: [id.uuidString.lowercased()]) else {
                return nil
            }
            let scopes = try JSONDecoder().decode([String].self, from: Data((row["scopes_json"] as String).utf8))
            return AgentIdentity(
                id: id,
                name: row["name"],
                scopes: Set(scopes.compactMap(AgentScope.init(rawValue:))),
                status: AgentIdentityStatus(rawValue: row["status"] as String)!
            )
        }
    }

    public func revoke(id: UUID, at date: Date = Date()) async throws {
        try await databasePool.write { db in
            try db.execute(sql: "UPDATE agent_identities SET status = ?, updated_at_ms = ? WHERE id = ?", arguments: [AgentIdentityStatus.revoked.rawValue, CatalogDate.milliseconds(date), id.uuidString.lowercased()])
        }
    }
}
