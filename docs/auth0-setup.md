# Auth0 sign-in setup

The application integration is implemented and tested with signed test tokens and a real PostgreSQL database. No live Auth0 tenant has been created or configured yet. The Auth0-hosted login, recovery emails and real MFA enrollment must still be verified after these steps.

## 1. Create the Auth0 application

Create an Auth0 tenant in your chosen region. In **Applications → Applications**, create **Knowledge Catalog** as a **Regular Web Application**, using Universal Login. Record the tenant **Domain** and application **Client ID**. Keep the **Client Secret** in your local secret manager/server environment; do not paste it into chat, commit it, or expose it to browser JavaScript.

For the existing local app on port 8080, configure these exact application URLs:

| Setting | Value |
|---|---|
| Allowed Callback URLs | `http://127.0.0.1:8080/auth/callback` |
| Allowed Logout URLs | `http://127.0.0.1:8080/` |
| Application Login URI | Leave unset for this local pilot; start sign-in from the app |

Use **RS256** ID-token signing and the **Authorization Code** grant. Configure the token endpoint authentication method as **Post** (`client_secret_post`). The application also sends PKCE. Do not enable password grants for this integration. If you change the port, update both registered URLs. The app deliberately does not accept an arbitrary callback or return URL supplied by the browser.

[Auth0 authorization-code documentation](https://auth0.com/docs/get-started/authentication-and-authorization-flow/authorization-code-flow/add-login-auth-code-flow).

## 2. Enable the three sign-in choices

Enable the relevant connections for this application:

- **Email/password:** an Auth0 database connection. Auth0 stores passwords and handles password-reset emails through Universal Login.
- **Google:** a Google social connection, with the Google application credentials configured in Auth0. Configure your own credentials before a shared deployment.
- **Microsoft work accounts:** a Microsoft Azure Active Directory / Entra enterprise connection. This also requires an app registration with Microsoft; follow Auth0's connection wizard. Enable the connection for Knowledge Catalog and configure its Universal Login discovery/display options. Microsoft personal accounts use a separate Microsoft social connection if you need them too.

These are Auth0 connection settings, not three separate password systems in Knowledge Catalog. Users go to one hosted sign-in page. Which connections appear depends on your Auth0 configuration and plan. Configure the email provider and test reset delivery before inviting other users. Password recovery for Google/Microsoft accounts stays with their respective providers.

[Microsoft work-account connection guide](https://auth0.com/docs/authenticate/identity-providers/enterprise-identity-providers/azure-active-directory/v2).

## 3. Require MFA, including Google and Microsoft logins

In **Security → Multi-factor Auth**, enable an available factor, such as an authenticator application, and recovery codes. Set the MFA requirement to **Always** for a dedicated Knowledge Catalog tenant. Confirm that your Auth0 plan includes the factors and enterprise connections you intend to use.

Deploy `deployment/auth0/require-mfa.js` as a **post-login Action**, set its `KC_CLIENT_ID` Action secret to your Knowledge Catalog Client ID, and attach it to the **Login** flow. It requires MFA for this application without a remembered-browser exemption. This also makes the application-specific requirement explicit if other apps share the Auth0 tenant.

The application independently rejects ID tokens without `amr: ["mfa", ...]`. It does not trust an email claim or assume Microsoft/Google already performed MFA. It requests fresh authentication and does not silently refresh tokens. Users may therefore receive an additional Auth0 challenge after federated sign-in. Keep recovery codes secure and test losing an authenticator with a test account before rollout.

[Enable MFA](https://auth0.com/docs/secure/multi-factor-authentication/enable-mfa) · [Auth0's MFA token validation guidance](https://auth0.com/docs/secure/multi-factor-authentication/step-up-authentication/configure-step-up-authentication-for-web-apps).

## 4. Prepare database roles and approved people

Install the updated package and apply migrations through the migration account:

```sh
python -m pip install -e '.[test]'
python -m kc.migrate
```

V013 adds `kc_auth_broker`, a NOLOGIN group with only the ability to resolve an existing external identity into a short-lived ticket and revoke a ticket. Create a separate nonprivileged LOGIN role for that group using your existing database administration process. The web runtime login remains a member of `kc_human_approver`. Keep runtime, authentication-broker, provisioning and migration credentials separate.

Example role memberships, after creating login roles with securely supplied passwords:

```sql
GRANT kc_auth_broker TO kc_auth_login;
GRANT kc_human_approver TO kc_web_login;
```

The broker login must not receive `kc_platform_admin`, superuser, table access or migration privileges. The provisioning login used for the commands below needs the existing `kc_platform_admin` permissions and is not the web broker.

Set `KC_PROVISIONING_DSN` securely, then list existing people:

```sh
python -m kc.identity_cli list-people
```

An administrator verifies the intended person's Auth0 **User ID** from Auth0's user record and links it to the existing human principal:

```sh
python -m kc.identity_cli link --organization YOUR_ORGANIZATION_CODE --principal EXISTING_PRINCIPAL_UUID --subject 'auth0|EXACT_AUTH0_USER_ID'
```

Copy the actual full User ID; federated accounts can use a different prefix. `KC_AUTH0_DOMAIN` determines the exact trusted issuer for the link. An organization code is an existing `core.organization.organization_key`, not an Auth0 organization ID. It is not a secret and does not itself grant access.

This command does not create memberships, roles or source access. Provision those through the existing administrative setup. A newly registered Auth0 user has no catalog access until explicitly mapped. Do not link accounts just because their email addresses match. Multiple separately verified Auth0 subjects can be mapped to the same catalog principal; account merging/recovery inside Auth0 requires its own verified process. No automatic account linking is enabled.

## 5. Start the app

Set these variables in the server process environment:

| Variable | Purpose |
|---|---|
| `KC_AUTH0_DOMAIN` | Exact Auth0 or configured custom domain, without `https://` or a slash |
| `KC_AUTH0_CLIENT_ID` | Regular Web Application Client ID |
| `KC_AUTH0_CLIENT_SECRET` | Application secret; server-only |
| `KC_AUTH_BROKER_DSN` | Separate login belonging only to `kc_auth_broker` |
| `KC_WEB_DSN` | Runtime login belonging to `kc_human_approver` |

The app does not automatically load a `.env` file. Supply these via your environment/secret manager. The provisioning and migration credentials are not needed by the running app.

```sh
python -m kc.web --port 8080
```

Open `http://127.0.0.1:8080`, enter your organization code and select **Continue to secure sign-in**. Complete Auth0 sign-in and MFA. Sessions expire after at most ten minutes (or earlier if the ID token expires); sign in again to continue. Catalog membership suspension and source ACL changes are rechecked on every database request. Sign-out removes the local session, revokes its database ticket, and redirects through Auth0 logout. It does not promise to sign you out of Google/Microsoft globally.

The old ticket form is available only with `python -m kc.web --dev-ticket-login`. This development mode is visibly labelled, has no MFA, and cannot run alongside Auth0 mode. Missing Auth0 settings stop normal startup instead of enabling ticket access.

## 6. Verify the live configuration

Using separate test author and reviewer accounts:

1. Verify email/password, Google and Microsoft work-account sign-in independently, including MFA enrollment and subsequent challenges.
2. Verify password-reset delivery and recovery-code use. Never use a real organizational SOP for this test.
3. Verify an unmapped user and an incorrect organization code cannot enter the catalog.
4. Create and review a sample SOP using separate identities; confirm self-approval is rejected.
5. Sign out, use the browser Back button, and verify protected requests require sign-in. Verify session expiry and disabled membership.

**Remaining deployment boundary:** this remains a loopback-only, single-process pilot using Python's standard HTTP server and in-memory sessions. This work does not deploy a public site. A shared rollout needs a supported production server, HTTPS with Secure cookies, distributed session/transaction storage, rate limiting, server-side request limits, monitoring and a logout/revocation strategy across instances. External Auth0 account suspension is effective at the next authentication or local session expiry; no Auth0 back-channel logout integration is claimed. Expired database tickets require an administrative cleanup job. The PostgreSQL database remains the authority for organization/workspace/source permissions.

## Local verification

On September 21, 2026, the complete regression suite passed **65 tests in 66.95 seconds** against PostgreSQL 17.11, including the existing Edge SOP workflow. A further Auth0 desktop/mobile browser-handoff test passed separately (**1 test in 3.65 seconds**), for **66 passing tests** in total. The Auth0 tests use real RSA signatures and the real database, with the external token exchange replaced by a controlled test response. No live Auth0 sign-in, MFA enrollment, email delivery or federation was claimed or exercised.
