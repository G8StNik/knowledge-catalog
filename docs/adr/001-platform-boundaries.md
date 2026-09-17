# ADR-001: Company-agnostic PostgreSQL monorepo

Status: accepted from KC-001/KC-002.

Use PostgreSQL as the authoritative catalog, shared-database organization tenancy initially, and a monorepo. Support SaaS and self-hosted deployment. Keep workspace ownership separate from sharing and authorization. Use relational integrity for governance and JSONB for tenant-defined metadata. Source systems, object storage, search, embeddings and model providers sit behind replaceable interfaces.

Consequences: no provider-specific catalog IDs, mandatory cloud, vector extension or hard-coded industry taxonomy. Dedicated databases for higher-isolation tiers remain a later operational decision. The next knowledge/source modules use the physical specification rather than introducing parallel schemas.
