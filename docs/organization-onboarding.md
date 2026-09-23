# Organization onboarding and invitations

Knowledge Catalog now creates the first organization through a trusted provisioning command. The first administrator can then create one-time invitations in **People & invitations**. No invitation email is sent by the app; the administrator shares the code through an established trusted channel.

## Create an organization

First configure the Auth0 Regular Web Application and its required MFA as described in [Auth0 setup](auth0-setup.md). Create the initial administrator in Auth0 and copy the exact Auth0 User ID from that verified user record. Set `KC_PROVISIONING_DSN` to a separate `kc_platform_admin` login and `KC_AUTH0_DOMAIN` to the tenant domain. Then run:

```sh
python -m kc.identity_cli onboard --organization example-company --name "Example Company" --admin-name "First Administrator" --admin-email admin@example.com --admin-subject 'auth0|EXACT_USER_ID'
```

The command atomically creates the organization, **General** workspace, account, active membership, human principal, exact Auth0 identity link, organization administrator grant, workspace edit/review access and configuration approval permission. It does not activate a configuration package; import and approve the desired package separately. The code is permanent and case-insensitive. Do not infer the Auth0 User ID from an email address.

## Invite a person

The administrator signs in with MFA, opens **People & invitations**, enters the person's email, selects the workspace and chooses whether the person may edit or review. **Create invitation** displays a one-time code. Copy it and share it privately. The code is shown once, expires after seven days, and can be revoked from the same screen. Only its SHA-256 hash is stored in PostgreSQL.

The recipient opens the Knowledge Catalog sign-in page, enters the organization code and invitation code, then completes Auth0 sign-in with MFA. Auth0 must supply a verified email claim matching the invited address. On success, the database consumes the code once and creates the account or reuses an active account with that verified email, an active organization membership, a human principal, the exact external identity link and the selected workspace access. A code cannot activate an already linked identity or an existing membership. A revoked, expired, reused or mismatched code fails without granting access.

Invited people do not automatically become organization administrators or configuration approvers. Workspace edit/review permissions apply to the selected workspace; source documents retain their separate access lists. The first administrator can review invitation status, but never see a code again after creation.

## Remove a member's access

An organization administrator can select **Remove access** beside an active member in **People & invitations**. This deactivates the member, ends their organization membership, revokes active sign-in tickets, and removes workspace, source, configuration and group access. Published SOPs, source evidence, and audit history retain the original author's identity. Administrators cannot remove themselves, and the database prevents removal of the last active organization administrator. Restoring a former member is a separate verified administrative process; a new invitation alone will not reactivate the historical membership.

This local pilot does not provision Auth0 users, send email or expose an internet-facing invitation page. Invitees must already have or create an Auth0 account using the enabled connections. A live Auth0 tenant with MFA and verified email claims is still required to exercise the complete sign-in flow outside tests.
