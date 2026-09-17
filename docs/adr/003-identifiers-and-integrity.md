# ADR-003: UUIDv7 and tenant-aware integrity

Status: accepted from KC-002/KC-003.

Applications generate UUIDv7; PostgreSQL stores UUID values without generator defaults. `kc.ids.uuid7` supplies a monotonic per-process implementation with cryptographic randomness. This avoids database-version-specific generation features.

Organization-owned references include organization_id. Versioned configuration references additionally include configuration_revision_id, preventing cross-tenant and cross-revision corruption even in privileged jobs. Identity subjects are separate from global accounts and organization membership. Groups use the same principal abstraction as humans, services and AI agents.

Use timestamptz, restrictive deletion and immutable identity kinds. Soft deletion and deactivation preserve historical references. Purge, retention and legal holds require a later explicitly governed process.
