# ADR-005: Explicit transactional SQL migrations

Status: accepted from KC-003; runner implemented in Python.

Use Flyway-style `VNNN__description.sql` files, applied explicitly by an operator/CI command. The small runner stores filename and SHA-256 checksums, validates the full applied history before changes, takes a database advisory lock, and applies each migration with its history row in one transaction. It rejects missing, modified, duplicate and out-of-order applied history. No automatic production schema mutation at app startup.

Do not edit migrations after deploying to shared environments. Add a forward migration, rehearse it against backups and review destructive changes. There is no automatic down migration. A failed migration rolls back; earlier successful migrations remain applied. This is a Flyway naming convention, not the Flyway product or its history-table format.

Local Docker uses a dedicated development database administrator, while runtime logins belong only to narrow group roles. Production bootstrap/extensions and migration ownership require a controlled privileged deployment account. Do not use the local administrator DSN in a service. Run the real PostgreSQL tests against an isolated cluster/database; they create disposable databases and nonprivileged test logins.
