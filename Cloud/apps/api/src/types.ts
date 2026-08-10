export interface Bindings {
  DB: D1Database;
  BLOBS: R2Bucket;
  JWT_SECRET?: string;
  ENROLLMENT_SECRET?: string;
  R2_ACCOUNT_ID?: string;
  R2_ACCESS_KEY_ID?: string;
  R2_SECRET_ACCESS_KEY?: string;
  R2_BUCKET_NAME?: string;
  OBSERVABILITY_SAMPLE_RATE?: string;
}

export interface Variables {
  deviceId?: string;
  scopes?: string[];
  requestId: string;
}

export interface AppEnv {
  Bindings: Bindings;
  Variables: Variables;
}
