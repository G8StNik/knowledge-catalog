# ADR-004: Auth0 sign-in with mandatory MFA and explicit identity mapping

Status: accepted provider choice; local integration implemented, live tenant setup pending.

Use Auth0 Universal Login as the selected external identity provider. Keep its integration in `kc.auth0`; catalog identities and permissions remain provider-independent. Microsoft work-account, Google and database/email connections are configured within Auth0. Passwords, recovery and factor enrollment never enter the catalog application.

Use authorization code flow with S256 PKCE, a one-time state bound to an HttpOnly browser cookie, a nonce, a fixed issuer and redirect URI, and RS256 signature verification with issuer/audience/expiry/authorized-party checks. Require fresh authentication and signed `amr` evidence of MFA. Do not accept browser-supplied identity claims or automatically link by email.

The adapter uses a separate limited database broker role to exchange a verified issuer/subject and selected organization code for an existing active human principal's ticket. The same external subject can belong to several organizations; the selected organization never bypasses membership checks. V013 adds the narrow broker interface without changing previous migrations. Sign-in emits an audit event containing only opaque catalog IDs.

The standard sign-in mode fails closed when configuration or MFA is missing. The old ticket form is an explicit local development mode, never a fallback. Sessions remain at most ten minutes and database authorization is checked per request. Local logout revokes the ticket and invokes Auth0 logout. Live federation, recovery delivery and MFA enrollment require the operator's Auth0 tenant and credentials and cannot be verified using synthetic tests.

The local HTTP server is not promoted to a public production service by this change. HTTPS, a production server, distributed sessions, operational rate limits and provider back-channel revocation remain deployment work. See the Auth0 setup guide for exact operator steps and remaining limits.
