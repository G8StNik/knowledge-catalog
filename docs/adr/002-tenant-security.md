# ADR-002: Authenticated tenant context and forced RLS

Status: accepted principle; ticket mechanism is an implementation refinement for review.

Use FORCE ROW LEVEL SECURITY and OrganizationID composite FKs on tenant tables. Global accounts and session-ticket hashes are private to privileged identity operations. Runtime roles never own tables, bypass RLS, create roles, or hold superuser privileges.

The earlier GUC example could be forged by a SQL caller if organization/principal IDs alone established identity. Instead, a trusted authentication broker issues a cryptographically random bearer ticket after verifying an external identity and membership. Only its SHA-256 hash is stored, with a login audience and a maximum 15-minute lifetime. `security.begin_context` establishes it transaction-locally; context lookup verifies the ticket, login, organization, principal, human membership and account on each statement. Setting another OrganizationID or PrincipalID GUC grants nothing. Revocation removes the hash.

Runtime pools are distinct: application, read-only, ingestion, AI proposal and human approval. The AI pool has no create-revision, approval or activation privilege. Human approval additionally requires a USER principal and an effective administrative permission. The broker must never route an AI request through a human approval pool. Do not grant membership in `kc_platform_admin` or `kc_context_owner` to runtime logins.

The NOLOGIN context owner bypasses RLS only to read context inputs without recursive policies. Migration-owned SECURITY DEFINER routines have fixed search paths, no PUBLIC execution, explicit function grants and tenant/actor checks. Migration and broker credentials are trusted administrative boundaries, not application credentials. Administrators with DDL/superuser powers can change security; database RLS cannot defend against the database administrator.

Production broker identity verification, secret management, ticket cleanup, login provisioning and request authentication are deployment responsibilities. No authentication endpoint is included here. Ticket plaintext must not enter logs, source control, packages or model prompts. Use parameterized queries and reset pooled transactions after every request.

Source ACL authorization remains an additional layer before retrieval. RLS alone does not authorize documents within a tenant.

Reference: [PostgreSQL row security](https://www.postgresql.org/docs/17/ddl-rowsecurity.html).
