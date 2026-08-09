import { DatabaseSync } from 'node:sqlite';
import type { D1Database, D1PreparedStatement } from '@cloudflare/workers-types';

class FakeD1PreparedStatement {
  constructor(
    private readonly db: DatabaseSync,
    private readonly sql: string,
    private readonly params: unknown[] = []
  ) {}

  bind(...params: unknown[]): D1PreparedStatement {
    return new FakeD1PreparedStatement(this.db, this.sql, params) as unknown as D1PreparedStatement;
  }

  async run() {
    const info = this.db.prepare(this.sql).run(...(this.params as never[]));
    return {
      results: [],
      success: true,
      meta: { last_row_id: Number(info.lastInsertRowid ?? 0), changes: Number(info.changes ?? 0), duration: 0 }
    };
  }

  async first<T = unknown>(): Promise<T | null> {
    const row = this.db.prepare(this.sql).get(...(this.params as never[]));
    return (row as T | undefined) ?? null;
  }

  async all<T = unknown>() {
    const rows = this.db.prepare(this.sql).all(...(this.params as never[]));
    return { results: rows as T[], success: true, meta: {} };
  }
}

/** In-memory D1Database backed by node:sqlite — real SQL semantics, no Miniflare dependency. */
export function createFakeD1(schemaSql: string): D1Database {
  const db = new DatabaseSync(':memory:');
  db.exec(schemaSql);
  return {
    prepare(sql: string) {
      return new FakeD1PreparedStatement(db, sql) as unknown as D1PreparedStatement;
    }
  } as unknown as D1Database;
}
