# SOP browser workspace

Run the existing migrations and provision an activated configuration, workspace entitlements, source evidence and individual identity tickets as described in [SOP workflow](sop-workflow.md).

Install the project (`python -m pip install -e .`), set `KC_WEB_DSN` in the server environment, then run:

```sh
python -m kc.web --port 8080
```

Open http://127.0.0.1:8080. The server binds only to loopback; use this exact address, not `localhost`. The DSN must use a nonprivileged login belonging to `kc_human_approver` for the full review/publication flow. Each human signs in with their own short-lived broker-issued ticket addressed to that database login. A shared database login does not mean a shared human identity: the database independently verifies the ticket's organization, principal, membership, source ACLs and workspace permissions on every request. Never use a migration, superuser or platform-admin login as the web login.

The existing trusted authentication broker remains responsible for issuing tickets after authenticating the human. This local UI does not issue tickets or offer an identity selector. Tickets must not be placed in URLs, source files or logs. They are exchanged for a random HttpOnly, SameSite=Strict browser cookie and held only in server memory for at most ten minutes; database expiry/revocation can end access sooner. Restarting the server signs everyone out. Use separate browser profiles for author/reviewer testing or sign out between people.

## User flow

1. Select **Create SOP**, choose an authorized workspace, configured knowledge type and domain, then fill in the procedure and metadata. The SOP type is selected by default when available.
2. Save the draft. Attach one or more existing source versions with a section/location and evidence note. Assign the required owner and approver responsibilities.
3. Select **Submit for review**. Required fields, evidence, responsibilities and effective configuration are enforced by the database. Submitted content is frozen.
4. An independently authorized reviewer opens the SOP and expands its source evidence, records a review note and selects **Approve this version**. The database rejects contributor self-approval even if the button is visible.
5. Select **Publish version**. The published record is read-only. **Create revision** creates a new draft; the version history continues to identify the current publication.

Search and stage filters help locate versions. Version history opens the exact historical content, citations and reviews. Forms escape stored text rather than rendering source HTML. A failed action leaves the form intact. The UI uses the standard starter workflow transition keys; custom workflow mappings remain available through the CLI.

## Deployment boundary

This is a local browser application, not an internet deployment. It uses Python's standard HTTP server to avoid adding an application framework to the foundation. It must not be exposed through a tunnel or reverse proxy. A production rollout needs a supported web server, HTTPS, an authenticated identity-provider/broker integration, distributed session management, rate limits, pagination and operational monitoring. It currently loads all records visible to the actor in one workspace response and is intended for small local catalogs.

Evidence ingestion, source permission provisioning and configuration activation remain trusted administrative operations. The UI attaches existing evidence; it cannot upload a document and declare it authoritative, grant permissions, or activate AI proposals. Custom metadata supports the existing database field evaluators; unsupported extended rules remain blocked by the database. Drafts have no collaborative merge or autosave; use one editor per draft and save explicitly.

## Validation

`python -m pytest` includes real HTTP/database tests for the full lifecycle, authentication, cross-site request rejection, logout, source revocation and published-history preservation. Browser testing is optional: set `KC_BROWSER_NODE` to a Node executable and `NODE_PATH` to a directory containing Playwright, with Microsoft Edge installed, then run `python -m pytest tests/test_web.py`. The browser test drives the full create/evidence/responsibility/review/publish/revise sequence and checks desktop and mobile layouts using synthetic evidence and test identities. It never approves a real organizational SOP.

On September 21, 2026, all **46 tests passed** against PostgreSQL 17.11 in 74.24 seconds, including the real Edge browser workflow. Desktop (1440 px) and mobile (390 px) screenshots were inspected; the mobile check found no horizontal overflow. Existing migrations were not changed. Git whitespace validation passed.
