"""Local SOP workspace with Auth0 MFA sign-in or explicit development ticket mode."""
import argparse
import base64
import binascii
import json
import os
import secrets
import time
import hashlib
from datetime import datetime, timedelta, timezone
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from uuid import UUID
from urllib.parse import urlsplit, parse_qs
from urllib.error import URLError

import jwt

import psycopg

from kc import knowledge, sources
from kc.session import tenant_transaction
from kc.auth0 import Auth0, Auth0Settings
from kc.ids import uuid7

STATIC = Path(__file__).with_name('web_static')


def rows(conn, query, args=()):
    cursor = conn.execute(query, args)
    return [dict(zip([c.name for c in cursor.description], row)) for row in cursor]


def snapshot(conn):
    """Every query runs under the caller's transaction-scoped RLS context."""
    return {
        'actor': rows(conn, 'SELECT p.principal_id,p.display_name FROM identity.principal p WHERE principal_id=security.current_principal()')[0],
        'versions': rows(conn, '''SELECT v.*, i.knowledge_key, i.current_version_id,
            security.has_workspace_access(i.owning_workspace_id,'edit') AS can_edit,
            security.has_workspace_access(i.owning_workspace_id,'review') AS can_review
            FROM catalog.knowledge_version v JOIN catalog.knowledge_item i USING(organization_id,knowledge_item_id)
            ORDER BY v.created_at DESC'''),
        'workspaces': rows(conn, "SELECT workspace_id,workspace_name FROM core.workspace WHERE security.has_workspace_access(workspace_id,'edit')"),
        'types': rows(conn, '''SELECT t.* FROM catalog.knowledge_type t WHERE is_enabled AND EXISTS
            (SELECT FROM governance.configuration_activation a WHERE a.configuration_revision_id=t.configuration_revision_id
            AND a.effective_from<=statement_timestamp() AND (a.effective_to IS NULL OR a.effective_to>statement_timestamp()))'''),
        'domains': rows(conn, 'SELECT domain_id,configuration_revision_id,display_name FROM catalog.domain WHERE is_enabled'),
        'roles': rows(conn, 'SELECT role_id,configuration_revision_id,display_name FROM governance.role WHERE is_enabled'),
        'people': rows(conn, "SELECT principal_id,display_name,status FROM identity.principal WHERE principal_type='USER'"),
        'fields': rows(conn, '''SELECT f.*, b.knowledge_type_id, b.is_required AS binding_required
            FROM catalog.custom_field_definition f JOIN catalog.knowledge_type_field b
            USING(organization_id,configuration_revision_id,custom_field_definition_id) WHERE f.is_enabled AND b.is_enabled'''),
        'choices': rows(conn, 'SELECT custom_field_definition_id,value,display_name FROM catalog.custom_field_choice WHERE is_enabled'),
        'classifications': rows(conn, 'SELECT classification_id,configuration_revision_id,display_name FROM governance.classification WHERE is_enabled'),
        'evidence': rows(conn, '''SELECT v.artifact_version_id,v.organization_id,v.source_artifact_id,
            v.version_key,v.content,v.content_hash,v.captured_at,v.file_name,v.media_type,
            v.original_content_hash,v.uploaded_by,v.effective_from,v.effective_to,
            a.external_key,a.source_uri,a.title,a.owning_workspace_id,a.owner_principal_id,
            a.classification_id,a.configuration_revision_id FROM source.artifact_version v
            JOIN source.source_artifact a USING(organization_id,source_artifact_id) ORDER BY captured_at DESC'''),
        'citations': rows(conn, 'SELECT * FROM catalog.citation'),
        'responsibilities': rows(conn, 'SELECT * FROM governance.knowledge_responsibility'),
        'reviews': rows(conn, 'SELECT * FROM governance.knowledge_review ORDER BY reviewed_at'),
    }


def dispatch(conn, action, payload):
    if action == 'create':
        return knowledge.create_draft(conn, **payload)
    version = UUID(payload.pop('version_id'))
    operations = {'edit': knowledge.edit_draft, 'attach': knowledge.attach_evidence,
                  'assign': knowledge.assign_responsibility, 'submit': knowledge.submit,
                  'review': knowledge.review, 'publish': knowledge.publish,
                  'return-to-draft': knowledge.return_to_draft, 'revise': knowledge.revise}
    if action not in operations:
        raise ValueError('Unknown action')
    return operations[action](conn, version, **payload)


class WorkspaceServer(ThreadingHTTPServer):
    def __init__(self, address, dsn, *, auth0_settings=None, dev_ticket_login=False):
        if (auth0_settings is None) == (not dev_ticket_login):
            raise ValueError('Configure Auth0 or explicitly enable development ticket login')
        super().__init__(address, Handler)
        self.dsn = dsn
        self.sessions = {}
        self.origin = f'http://127.0.0.1:{self.server_port}'
        self.auth = None
        if auth0_settings:
            with psycopg.connect(dsn) as conn:
                audience = conn.execute('SELECT session_user').fetchone()[0]
            self.auth = Auth0(auth0_settings, self.origin, audience)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass  # Never log tickets, request bodies, or catalog contents.

    def respond(self, status, body, content_type='application/json', cookie=None, location=None):
        data = json.dumps(body, default=str).encode() if content_type == 'application/json' else body
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
        for value in ([cookie] if isinstance(cookie, str) else cookie or []):
            self.send_header('Set-Cookie', value)
        if location:
            self.send_header('Location', location)
        self.end_headers()
        self.wfile.write(data)

    def open_session(self, ticket, seconds=600):
        now = time.monotonic()
        self.server.sessions = {k: v for k, v in self.server.sessions.items() if v['expires'] > now}
        old = SimpleCookie(self.headers.get('Cookie', '')).get('kc_session')
        if old:
            self.server.sessions.pop(old.value, None)
        key = secrets.token_urlsafe(32)
        self.server.sessions[key] = {'ticket': ticket, 'expires': now + seconds}
        return f'kc_session={key}; HttpOnly; SameSite=Strict; Path=/; Max-Age={seconds}'

    def session(self):
        cookie = SimpleCookie(self.headers.get('Cookie', ''))
        key = cookie['kc_session'].value if 'kc_session' in cookie else ''
        entry = self.server.sessions.get(key)
        if not entry or entry['expires'] <= time.monotonic():
            self.server.sessions.pop(key, None)
            raise PermissionError('Your session has ended. Please sign in again.')
        return key, entry

    def do_GET(self):
        self.handle_request(False)

    def do_POST(self):
        self.handle_request(True)

    def handle_request(self, write):
        try:
            # Fixed loopback host plus strict Origin prevent DNS rebinding and cross-site writes.
            if self.headers.get('Host') != self.server.origin.removeprefix('http://'):
                return self.respond(403, {'error': 'Invalid host'})
            path = urlsplit(self.path).path
            if not write and path == '/api/auth/config':
                return self.respond(200, {'mode': 'auth0' if self.server.auth else 'development'})
            if not write and path == '/auth/callback' and self.server.auth:
                expired = 'kc_login=; HttpOnly; SameSite=Lax; Path=/auth/callback; Max-Age=0'
                try:
                    query = parse_qs(urlsplit(self.path).query, strict_parsing=True)
                    if 'error' in query or any(len(query.get(k, [])) != 1 for k in ('code', 'state')):
                        raise ValueError('Invalid callback')
                    browser = SimpleCookie(self.headers.get('Cookie', '')).get('kc_login')
                    ticket, seconds = self.server.auth.finish(query['state'][0], browser.value if browser else '', query['code'][0])
                    cookie = self.open_session(ticket, seconds)
                    return self.respond(303, {}, cookie=[expired, cookie], location='/')
                except (ValueError, KeyError, TypeError, PermissionError, jwt.PyJWTError, URLError, TimeoutError, psycopg.Error):
                    return self.respond(303, {}, cookie=expired, location='/?signin=failed')
            if not write and path in ('/', '/app.js', '/style.css'):
                name, mime = {'/': ('index.html', 'text/html; charset=utf-8'), '/app.js': ('app.js', 'text/javascript'), '/style.css': ('style.css', 'text/css')}[path]
                return self.respond(200, (STATIC / name).read_bytes(), mime)
            payload = {}
            if write:
                if self.headers.get('Origin') != self.server.origin or self.headers.get('Content-Type') != 'application/json':
                    return self.respond(403, {'error': 'Invalid request origin or content type'})
                size = int(self.headers.get('Content-Length', '0'))
                maximum = 14 * 1024 * 1024 if path == '/api/source/upload' else 1024 * 1024
                if size < 1 or size > maximum:
                    return self.respond(413, {'error': 'Request is too large'})
                payload = json.loads(self.rfile.read(size))
                if not isinstance(payload, dict):
                    raise ValueError('Expected an object')
            if write and path == '/api/auth/start' and self.server.auth:
                url, browser = self.server.auth.begin(payload['organization'], payload.get('invitation') or None)
                return self.respond(200, {'url': url}, cookie=f'kc_login={browser}; HttpOnly; SameSite=Lax; Path=/auth/callback; Max-Age=300')
            if write and self.path == '/api/login' and not self.server.auth:
                ticket = payload['ticket']
                if not isinstance(ticket, str) or not 20 <= len(ticket) <= 512:
                    raise ValueError('Invalid access ticket')
                with psycopg.connect(self.server.dsn) as conn:
                    with tenant_transaction(conn, ticket):
                        actor = conn.execute("SELECT principal_type FROM security.context()").fetchone()
                        if not actor or actor[0] != 'USER':
                            raise PermissionError('A human account is required.')
                return self.respond(200, {'ok': True}, cookie=self.open_session(ticket))
            if write and self.path == '/api/logout':
                cookie = SimpleCookie(self.headers.get('Cookie', '')).get('kc_session')
                key = cookie.value if cookie else ''
                session = self.server.sessions.get(key)
                self.server.sessions.pop(key, None)
                if session and self.server.auth:
                    self.server.auth.revoke(session['ticket'])
                result = {'ok': True}
                if self.server.auth:
                    result['url'] = self.server.auth.logout_url()
                return self.respond(200, result, cookie='kc_session=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0')
            key, session = self.session()
            with psycopg.connect(self.server.dsn) as conn:
                with tenant_transaction(conn, session['ticket']):
                    if not write and self.path == '/api/workspace':
                        result = snapshot(conn)
                    elif write and path == '/api/source/upload':
                        try:
                            content = base64.b64decode(payload.pop('content_base64'), validate=True)
                        except (binascii.Error, KeyError):
                            raise ValueError('Invalid file')
                        result = {'artifact_version_id': sources.upload(conn, content=content, **payload)}
                    elif not write and path == '/api/source/access':
                        artifact = UUID(parse_qs(urlsplit(self.path).query)['artifact'][0])
                        result = {'members': rows(conn, 'SELECT * FROM source.access_members(%s)', (artifact,))}
                    elif write and path == '/api/source/access':
                        if not isinstance(payload['allowed'], bool):
                            raise ValueError('Access decision must be true or false')
                        conn.execute('SELECT source.set_access(%s,%s,%s,%s)',
                                     (UUID(payload['artifact_id']), UUID(payload['principal_id']),
                                      payload['allowed'], uuid7()))
                        result = {'ok': True}
                    elif not write and path == '/api/organization/invitations':
                        result = {'invitations': rows(conn, 'SELECT * FROM identity.list_invitations()')}
                    elif write and path == '/api/organization/invite':
                        if not isinstance(payload['can_edit'], bool) or not isinstance(payload['can_review'], bool):
                            raise ValueError('Workspace permissions must be true or false')
                        code = secrets.token_urlsafe(48)
                        conn.execute('SELECT identity.create_invitation(%s,%s,%s,%s,%s,%s,%s,%s)', (
                            uuid7(), hashlib.sha256(code.encode()).digest(), payload['email'],
                            UUID(payload['workspace_id']), payload['can_edit'], payload['can_review'],
                            datetime.now(timezone.utc) + timedelta(days=7), uuid7()))
                        result = {'invitation_code': code}
                    elif write and path == '/api/organization/revoke':
                        conn.execute('SELECT identity.revoke_invitation(%s,%s)', (UUID(payload['invitation_id']), uuid7()))
                        result = {'ok': True}
                    elif write and path == '/api/organization/deactivate-member':
                        conn.execute('SELECT identity.deactivate_member(%s,%s)',
                                     (UUID(payload['principal_id']), uuid7()))
                        result = {'ok': True}
                    elif write and self.path.startswith('/api/action/'):
                        result = {'version_id': dispatch(conn, self.path.rsplit('/', 1)[-1], payload)}
                    else:
                        return self.respond(404, {'error': 'Not found'})
            self.respond(200, result)
        except PermissionError as error:
            self.respond(401, {'error': str(error)})
        except (ValueError, KeyError, TypeError):
            self.respond(400, {'error': 'Check the form values and try again.'})
        except psycopg.Error as error:
            if error.sqlstate == '28000':
                return self.respond(401, {'error': 'Your access ticket has expired or is invalid. Sign in again.'})
            # Constraint details can reveal hidden rows. Never return raw DB diagnostics.
            messages = {'42501': 'Your access has expired or this action is not permitted. Sign in again or ask your administrator.',
                        '23505': 'This record already exists, or this SOP already has an open revision.',
                        '23514': 'Workflow requirements are not met. Check required fields, evidence, responsibilities, and independent approval.'}
            self.respond(403 if error.sqlstate == '42501' else 409,
                         {'error': messages.get(error.sqlstate, 'The request could not be completed. Check your access and configuration.')})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8080)
    parser.add_argument('--dev-ticket-login', action='store_true', help='Explicit local development mode; does not use Auth0 or MFA')
    args = parser.parse_args()
    try:
        settings = None if args.dev_ticket_login else Auth0Settings.from_environment()
        server = WorkspaceServer(('127.0.0.1', args.port), os.environ['KC_WEB_DSN'],
                                 auth0_settings=settings, dev_ticket_login=args.dev_ticket_login)
    except (KeyError, ValueError) as error:
        parser.error(f'Sign-in configuration is incomplete: {error}')
    print(f'SOP workspace: {server.origin}', flush=True)
    server.serve_forever()


if __name__ == '__main__':
    main()
