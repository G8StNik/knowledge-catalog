"""Administrator-only linking of a verified Auth0 subject to an existing human."""
import argparse
import os
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
    args = parser.parse_args()
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
