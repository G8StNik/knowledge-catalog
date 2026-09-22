# SOP browser workspace

For normal user sign-in with required MFA, start with the [Auth0 setup guide](auth0-setup.md). The ticket instructions below are the separate local development mode.

## Development ticket mode

Run the existing migrations and provision an activated configuration, workspace entitlements, source evidence and individual identity tickets as described in [SOP workflow](sop-workflow.md).

Install the project (`python -m pip install -e .`), set `KC_WEB_DSN` in the server environment, then run:

```sh
python -m kc.web --dev-ticket-login --port 8080
```

Open http://127.0.0.1:8080. The server binds only to loopback; use this exact address, not `localhost`. The DSN must use a nonprivileged login belonging to `kc_human_approver` for the full review/publication flow. Each human signs in with their own short-lived broker-issued ticket addressed to that database login. A shared database login does not mean a shared human identity: the database independently verifies the ticket's organization, principal, membership, source ACLs and workspace permissions on every request. Never use a migration, superuser or platform-admin login as the web login.

The existing trusted authentication broker remains responsible for issuing tickets after authenticating the human. In development ticket mode, the UI does not issue tickets or offer an identity selector. The Auth0 adapter issues tickets internally only after verifying sign-in and MFA. Tickets must not be placed in URLs, source files or logs. They are exchanged for a random HttpOnly, SameSite=Strict browser cookie and held only in server memory for at most ten minutes; database expiry/revocation can end access sooner. Restarting the server signs everyone out. Use separate browser profiles for author/reviewer testing or sign out between people.

## Normal sign-in

Use the [Auth0 setup guide](auth0-setup.md) for normal sign-in with mandatory MFA. The ticket setup above now requires the explicit `--dev-ticket-login` flag and is for development only. Auth0 mode does not accept ticket-form login.

## User flow

1. Select **Upload source** to add PDF, text or Markdown evidence, or to add a new immutable version of an existing document. Choose its workspace, human owner, governed classification and readers. See [Source document uploads](source-uploads.md).
2. Select **Create SOP**, choose an authorized workspace, configured knowledge type and domain, then fill in the procedure and metadata. The SOP type is selected by default when available.
3. Save the draft. Attach one or more accessible source versions with a section/location and evidence note. Assign the required owner and approver responsibilities.
4. Select **Submit for review**. Required fields, evidence, responsibilities and effective configuration are enforced by the database. Submitted content is frozen.
5. An independently authorized reviewer opens the SOP and expands its source evidence, records a review note and selects **Approve this version**. The database rejects contributor self-approval even if the button is visible.
6. Select **Publish version**. The published record is read-only. **Create revision** creates a new draft; the version history continues to identify the current publication.

Search and stage filters help locate versions. Version history opens the exact historical content, citations and reviews. Forms escape stored text rather than rendering source HTML. A failed action leaves the form intact. The UI uses the standard starter workflow transition keys; custom workflow mappings remain available through the CLI.

## Deployment boundary

This is a local browser application, not an internet deployment. It uses Python's standard HTTP server to avoid adding an application framework to the foundation. It must not be exposed through a tunnel or reverse proxy. A production rollout needs a supported web server, HTTPS, a live configured Auth0 tenant, distributed session management, rate limits, pagination and operational monitoring. It currently loads all records visible to the actor in one workspace response and is intended for small local catalogs.

Configuration activation remains a trusted administrative operation. A workspace editor can upload a source and grant its read access only to people who already belong to that workspace. Classification and access do not make a source authoritative; an SOP reviewer still evaluates the exact cited version. The UI cannot activate AI proposals. Custom metadata supports the existing database field evaluators; unsupported extended rules remain blocked by the database. Drafts have no collaborative merge or autosave; use one editor per draft and save explicitly.

## Validation

`python -m pytest` includes real HTTP/database tests for the full lifecycle, authentication, cross-site request rejection, logout, source revocation and published-history preservation. Browser testing is optional: set `KC_BROWSER_NODE` to a Node executable and `NODE_PATH` to a directory containing Playwright, with Microsoft Edge installed, then run `python -m pytest tests/test_web.py`. The browser test drives the full create/evidence/responsibility/review/publish/revise sequence and checks desktop and mobile layouts using synthetic evidence and test identities. It never approves a real organizational SOP.

The suite rebuilds a fresh PostgreSQL database and verifies the server boundary, source access, immutable versions and the full SOP lifecycle. The optional Edge run additionally exercises source upload, evidence attachment, independent review, publication and revision at desktop and mobile sizes.
