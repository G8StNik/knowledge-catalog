# Local demo without Auth0

The local demo uses an isolated Docker Compose project and PostgreSQL volume. It does not use the normal Knowledge Catalog database, Auth0, real accounts, or production content. It binds both PostgreSQL and the website to this computer only.

On Windows with Docker Desktop running, open PowerShell in the repository and run:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/start-local-demo.ps1
```

The first run creates an ignored `.env.local-demo` file containing random local database passwords, installs the Python package in an ignored `.venv`, applies migrations, and creates the **Demo Author** and **Demo Reviewer** accounts with a General workspace and approved General Business starter configuration. It prints one short-lived ticket for each test user and starts the website at <http://127.0.0.1:8080/>. Keep the PowerShell window open while using the website. Paste the Author ticket into the development sign-in form. To act as the Reviewer, sign out and paste the Reviewer ticket (or use a second browser profile).

The tickets expire after 15 minutes; stop the web server with Ctrl+C and run the script again to obtain fresh tickets. The database and demo work persist in the isolated Docker volume. The starter configuration is approved only for this disposable demo. Upload a sample PDF, text, or Markdown source, give both test users access, then create, submit, review, publish and revise a sample SOP. Do not use real confidential documents in the local demo.

To prepare the database and users without starting the website, add `-PrepareOnly`. This issues tickets that are not displayed; a later normal launch issues fresh ones. Stopping the server does not stop PostgreSQL. To stop the demo database without deleting it, run `docker compose -p knowledge-catalog-local-demo stop postgres` from the repository.

If Docker Desktop is unavailable and a local PostgreSQL 17 runtime is already installed, `scripts/start-local-demo-native.ps1` runs the same demo against a separate local database. It defaults to the project's existing `.local-postgres/pgsql/bin` runtime and `.local-postgres-qa-utf8/data` cluster; use `-PostgresBin` and `-PostgresData` to select another local installation. It uses port 55440 and creates `kc_demo_preview` if necessary. Keep its PowerShell window open and restart the script for fresh tickets. This is a fallback for local testing, not a production deployment.
