"""Administrator-only linking of a verified Auth0 subject to an existing human."""
import argparse
import os
import re
from uuid import UUID

import psycopg

from kc.auth0 import Auth0Settings
from kc.ids import uuid7


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    listing = sub.add_parser('list-people', help='List existing organization codes and human principal IDs')
    linking = sub.add_parser('link', help='Link the exact Auth0 User ID; never infer a link from email')
    linking.add_argument('--organization', required=True)
    linking.add_argument('--principal', type=UUID, required=True)
    linking.add_argument('--subject', required=True, help='Exact Auth0 User ID, such as auth0|...')
    onboarding = sub.add_parser('onboard', help='Create an organization, first workspace and verified administrator')
    onboarding.add_argument('--organization', required=True, help='Permanent organization code')
    onboarding.add_argument('--name', required=True, help='Organization name')
    onboarding.add_argument('--admin-name', required=True)
    onboarding.add_argument('--admin-email', required=True)
    onboarding.add_argument('--admin-subject', required=True, help='Exact verified Auth0 User ID')
    args = parser.parse_args()
    if args.action == 'onboard':
        if (not re.fullmatch(r'[a-z][a-z0-9_-]{2,63}',args.organization) or not args.name.strip()
                or not args.admin_name.strip() or not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+',args.admin_email)
                or not args.admin_subject.strip() or len(args.admin_subject)>512):
            parser.error('Check the organization code, name and verified administrator identity')
        domain = os.environ['KC_AUTH0_DOMAIN']
        issuer = Auth0Settings(domain, 'validation-only', 'validation-only', 'validation-only').issuer
        tenant,workspace,membership,principal,external,permission=[uuid7() for _ in range(6)]
        with psycopg.connect(os.environ['KC_PROVISIONING_DSN']) as conn:
            row=conn.execute('SELECT account_id,status FROM identity.account WHERE primary_email=%s',(args.admin_email,)).fetchone()
            if row and row[1]!='ACTIVE': parser.error('Administrator account is inactive')
            account=row[0] if row else uuid7()
            if not row:
                conn.execute('INSERT INTO identity.account(account_id,display_name,primary_email) VALUES(%s,%s,%s)',
                             (account,args.admin_name,args.admin_email))
            conn.execute('INSERT INTO core.organization(organization_id,organization_key,organization_name) VALUES(%s,%s,%s)',
                         (tenant,args.organization,args.name))
            conn.execute("INSERT INTO core.workspace(workspace_id,organization_id,workspace_key,workspace_name) VALUES(%s,%s,'general','General')",
                         (workspace,tenant))
            conn.execute('INSERT INTO identity.organization_membership(organization_membership_id,organization_id,account_id) VALUES(%s,%s,%s)',
                         (membership,tenant,account))
            conn.execute("INSERT INTO identity.principal(principal_id,organization_id,account_id,principal_type,display_name,email) VALUES(%s,%s,%s,'USER',%s,%s)",
                         (principal,tenant,account,args.admin_name,args.admin_email))
            conn.execute("INSERT INTO identity.external_identity(external_identity_id,organization_id,principal_id,provider,provider_tenant_id,provider_object_id,provider_email) VALUES(%s,%s,%s,'oidc',%s,%s,%s)",
                         (external,tenant,principal,issuer,args.admin_subject,args.admin_email))
            conn.execute('INSERT INTO security.organization_admin VALUES(%s,%s)',(tenant,principal))
            conn.execute('INSERT INTO security.workspace_access VALUES(%s,%s,%s,true,true)',(tenant,workspace,principal))
            conn.execute('INSERT INTO security.configuration_permission(configuration_permission_id,organization_id,principal_id,can_approve) VALUES(%s,%s,%s,true)',
                         (permission,tenant,principal))
        print(f'Created organization {args.organization} with General workspace and administrator {principal}.')
        return
    with psycopg.connect(os.environ['KC_PROVISIONING_DSN']) as conn:
        if args.action == 'list-people':
            for code, name, principal in conn.execute('''SELECT o.organization_key,p.display_name,p.principal_id
                FROM identity.principal p JOIN core.organization o USING(organization_id)
                WHERE p.principal_type='USER' ORDER BY o.organization_key,p.display_name'''):
                print(f'{code}\t{name}\t{principal}')
        else:
            domain = os.environ['KC_AUTH0_DOMAIN']
            issuer = Auth0Settings(domain, 'validation-only', 'validation-only', 'validation-only').issuer
            if not args.subject.strip() or len(args.subject) > 512:
                parser.error('Provide the exact Auth0 User ID')
            row = conn.execute('''SELECT p.organization_id FROM identity.principal p
                JOIN core.organization o USING(organization_id)
                WHERE o.organization_key=%s AND p.principal_id=%s AND p.principal_type='USER' AND p.status='ACTIVE' ''',
                (args.organization,args.principal)).fetchone()
            if row is None:
                parser.error('An existing active human in that organization is required')
            conn.execute('''INSERT INTO identity.external_identity(external_identity_id,organization_id,principal_id,
                provider,provider_tenant_id,provider_object_id) VALUES(%s,%s,%s,'oidc',%s,%s)''',
                (uuid7(),row[0],args.principal,issuer,args.subject))
    if args.action == 'link':
        print('Identity linked. Existing membership and workspace permissions still apply.')


if __name__ == '__main__':
    main()
