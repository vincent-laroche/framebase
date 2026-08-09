export interface Bindings {
  DB: D1Database;
  BLOBS: R2Bucket;
  JWT_SECRET?: string;
}

export interface Variables {
  deviceId?: string;
  scopes?: string[];
}

export interface AppEnv {
  Bindings: Bindings;
  Variables: Variables;
}
