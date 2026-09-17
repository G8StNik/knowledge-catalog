# Database development

Requires Docker Compose, or PostgreSQL 17 with Python 3.12+. The initial migrations install pgcrypto, citext and btree_gist, and provision NOLOGIN role groups. Use a privileged migration account on an isolated database/cluster for bootstrap. Runtime accounts must use the separate groups described below.

## Docker

Copy `.env.example` to `.env` and replace the password with a random URL-safe value. Keep it outside source control.

```sh
docker compose up -d postgres
docker compose run --rm migrate
docker compose --profile test run --rm test
```

The database binds only to localhost. The test service creates and removes its own isolated databases and test logins, and never uses normal runtime credentials for migrations. The named volume persists development data. Stopping containers does not remove it.

## Existing local PostgreSQL

```sh
python -m venv .venv
# Activate .venv using the command appropriate for your shell.
python -m pip install -e '.[test]'
# Set KC_MIGRATION_DSN to the privileged development database connection.
python -m kc.migrate
# Set KC_TEST_ADMIN_DSN to an isolated PostgreSQL cluster administrator connection.
python -m pytest -q
```

Environment examples: PowerShell uses `$env:KC_MIGRATION_DSN = 'postgresql://...'`; POSIX shells use `export KC_MIGRATION_DSN='postgresql://...'`. Passwords containing reserved URL characters must be encoded, or use libpq keyword connection strings. Never commit credentials.

## Optional demo data

After migrations, set `KC_DEV_MODE=1`, `KC_MIGRATION_DSN`, and `KC_DEV_REVIEWER_PASSWORD` to a local development password, then run:

```sh
python -m kc.dev_seed
```

This creates two organizations, workspaces, human accounts/memberships, human and AI principals, a local reviewer login, and **draft** General Business packages. It preserves an existing demo organization on rerun. It does not approve/activate configuration. The short-lived seed ticket is revoked afterward. This command is not a production provisioner.

## Runtime transaction contract

The trusted authentication broker verifies external identity, resolves organization membership and tenant principal, generates `secrets.token_urlsafe(48)`, and calls `security.issue_ticket` with its SHA-256 hash, tenant, principal, target database LOGIN role and expiration no more than 15 minutes away. The plaintext ticket is passed securely to that runtime pool. Never give broker credentials or human approval credentials to an AI agent.

```python
from kc.session import tenant_transaction

with tenant_transaction(connection, ticket):
    rows = connection.execute(
        "SELECT workspace_id, workspace_name FROM core.workspace "
        "WHERE organization_id = security.current_organization()"
    ).fetchall()
```

Start from an idle connection; commit/rollback clears the context. Ticket validity is checked again on each statement. Expired/revoked tickets and inactive memberships/accounts return no tenant context. Arbitrary organization/principal session variables are not authentication.

| Group role | Purpose |
|---|---|
| kc_application | Read tenant foundation/configuration; submit proposals; edit authorized knowledge drafts through workflow commands |
| kc_ingestion | Read tenant configuration; submit proposals; no activation |
| kc_readonly | Read tenant-visible foundation/configuration and workspace/source-authorized knowledge |
| kc_ai_agent | Read tenant configuration and own proposal/audit records; submit proposals only |
| kc_human_approver | Edit authorized configuration and invoke approval routines; configuration permission or knowledge workspace/role authority is checked for the corresponding operation |
| kc_platform_admin | Trusted provisioning, account/membership management, administrative permission grants, ticket issuance/revocation, source evidence ingestion and workspace/source entitlements |
| kc_context_owner | Internal NOLOGIN function owner; never grant membership |

Create distinct production LOGIN roles with `INHERIT` and grant exactly the intended group. No runtime LOGIN may be superuser, table owner, BYPASSRLS, or inherit a privileged group. The migration account is separate and never serves requests. A deployment may use role-specific secrets or workload identity for PostgreSQL connections.

## Configuration packages

`schemas/configuration-package.schema.json` documents format v1. `seeds/general-business.json` is an optional neutral starter. `kc.configuration.validate_package` rejects unknown entities/fields, duplicate or missing references, oversized input and remote JSON-schema references. PostgreSQL applies the final relational/type constraints atomically on import.

The CLI reads `KC_RUNTIME_DSN` and `KC_SESSION_TICKET` from a securely supplied environment:

```sh
python -m kc.config_cli import database/seeds/general-business.json
python -m kc.config_cli export REVISION_UUID reviewed-package.json
# Only after an authorized human has reviewed the exact draft:
python -m kc.config_cli activate REVISION_UUID --effective-from 2027-01-01T00:00:00+00:00 --note 'Reviewed by catalog administrator'
```

Imports remap stable entity keys to new application UUIDv7 values and produce a draft. Workspace references resolve by key in the target organization. A missing workspace or reference fails the whole import. Version conflicts reject rather than overwrite. Export removes known tenant/entity IDs and approval records; free-text/JSON metadata still needs the normal organizational review before sharing. Do not place credentials, ACL grants or private identity data in configuration metadata/defaults.

AI submissions use `governance.propose_configuration`; confidence parameters should be Decimal/numeric. Evidence should hold source references and locators, not copied restricted text. Reference authorization must be checked by the future source-aware service. Human reviewers can import a modified package with `--proposal PROPOSAL_UUID`; original proposed content remains immutable. Only `approve_and_activate` marks the linked proposal approved and freezes the reviewed snapshot.

Each draft-row mutation is audited with before/after state. The importer supplies a new application UUIDv7 change ID for each row. Other editing clients must set `kc.change_event_id` transaction-locally to a new UUIDv7 before each single-row insert/update/delete. The audit trigger consumes the ID once; unaudited edits and multi-row writes without distinct IDs fail atomically. Revision creation and activation/deactivation decisions have their own events.

At read time select approved revisions through activation intervals using `effective_from <= now()` and `(effective_to IS NULL OR effective_to > now())`, then require entity `is_enabled`. Use package_key explicitly; revisions in different packages do not share references. Existing knowledge will retain its exact configuration revision rather than silently adopting new meanings.

## Migrations and verification

The runner records checksums in `kc_migrations.history`, refuses altered/missing/out-of-order history, serializes runners with an advisory lock, and rolls back failed migrations. Applied files are immutable; extend with a new numbered SQL migration. Destructive changes require explicit review and backup/recovery planning.

Tests use real PostgreSQL and distinct non-superuser LOGIN connections. They cover missing/forged/cross-login context, pool cleanup, revoked identity, cross-tenant and cross-revision integrity, RLS across configuration tables, group/hierarchy integrity, concurrent cycle prevention, proposal restrictions, human permission, activation/immutability, portable packages and transactional migration recovery. CI rebuilds a fresh database twice.

## SOP publication workflow

Migrations V010–V012 add versioned knowledge and source evidence, independent human review, immutable publication, workspace/source access checks and contributor tracking. See [the full SOP walkthrough](../docs/sop-workflow.md) for commands and scope. To run the focused integration suite, use `python -m pytest tests/test_sop_workflow.py -q` with the same isolated `KC_TEST_ADMIN_DSN`.
