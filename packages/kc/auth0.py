"""Auth0 adapter: authorization code + PKCE and verified OIDC identity claims.

Passwords, enrollment, recovery and MFA challenges stay in Auth0 Universal Login.
"""
import base64
import hashlib
import json
import os
import re
import secrets
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from urllib.parse import urlencode
from urllib.request import Request, build_opener, HTTPRedirectHandler

import jwt
import psycopg

from kc.ids import uuid7

MFA_ACR = 'http://schemas.openid.net/pape/policies/2007/06/multi-factor'


@dataclass(frozen=True)
class Auth0Settings:
    domain: str
    client_id: str
    client_secret: str = field(repr=False)
    broker_dsn: str = field(repr=False)

    def __post_init__(self):
        if not re.fullmatch(r'[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?', self.domain) or '.' not in self.domain:
            raise ValueError('KC_AUTH0_DOMAIN must be a hostname without a scheme or path')
        if not self.client_id or not self.client_secret or not self.broker_dsn:
            raise ValueError('Auth0 requires a client ID, client secret and separate broker DSN')

    @property
    def issuer(self):
        return f'https://{self.domain}/'

    @classmethod
    def from_environment(cls):
        return cls(*(os.environ[name] for name in
                     ('KC_AUTH0_DOMAIN', 'KC_AUTH0_CLIENT_ID', 'KC_AUTH0_CLIENT_SECRET', 'KC_AUTH_BROKER_DSN')))


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_):
        # Never forward the client secret to a redirected token endpoint.
        return None


class Auth0:
    def __init__(self, settings, origin, audience):
        self.settings, self.origin, self.audience = settings, origin, audience
        self.keys = jwt.PyJWKClient(settings.issuer + '.well-known/jwks.json', timeout=10)
        self.pending = {}
        self.lock = threading.Lock()

    def begin(self, organization, invitation=None):
        if not isinstance(organization, str) or not 1 <= len(organization) <= 200:
            raise ValueError('Enter your organization code')
        if invitation is not None and (not isinstance(invitation, str) or not re.fullmatch(r'[A-Za-z0-9_-]{40,128}', invitation)):
            raise ValueError('Invalid invitation code')
        state, browser, nonce, verifier = (secrets.token_urlsafe(48) for _ in range(4))
        with self.lock:
            now = time.monotonic()
            self.pending = {k: v for k, v in self.pending.items() if v['expires'] > now}
            if len(self.pending) >= 1000:
                raise PermissionError('Sign-in is busy. Please try again shortly.')
            self.pending[state] = dict(browser=browser, nonce=nonce, verifier=verifier,
                                       organization=organization, invitation=invitation, expires=now + 300)
        challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b'=').decode()
        url = self.settings.issuer + 'authorize?' + urlencode(dict(
            response_type='code', client_id=self.settings.client_id,
            redirect_uri=self.origin + '/auth/callback', scope='openid profile email',
            state=state, nonce=nonce, code_challenge=challenge, code_challenge_method='S256',
            acr_values=MFA_ACR, max_age=0))
        return url, browser

    def exchange(self, code, verifier):
        data = urlencode(dict(grant_type='authorization_code', code=code,
                              client_id=self.settings.client_id, client_secret=self.settings.client_secret,
                              redirect_uri=self.origin + '/auth/callback', code_verifier=verifier)).encode()
        request = Request(self.settings.issuer + 'oauth/token', data=data,
                          headers={'Content-Type': 'application/x-www-form-urlencoded'})
        with build_opener(NoRedirect).open(request, timeout=10) as response:
            raw = response.read(1024 * 1024 + 1)
            if len(raw) > 1024 * 1024:
                raise ValueError('Invalid token response')
            return json.loads(raw)['id_token']

    def verify(self, token, nonce):
        key = self.keys.get_signing_key_from_jwt(token).key
        claims = jwt.decode(token, key, algorithms=['RS256'], issuer=self.settings.issuer,
                            audience=self.settings.client_id, options={
                                'require': ['iss', 'sub', 'aud', 'exp', 'iat', 'nonce', 'auth_time'],
                                'strict_aud': True})
        if not isinstance(claims['sub'], str) or not claims['sub']:
            raise ValueError('Invalid subject')
        if claims.get('azp', self.settings.client_id) != self.settings.client_id:
            raise ValueError('Invalid authorized party')
        if not isinstance(claims['nonce'], str) or not secrets.compare_digest(claims['nonce'], nonce):
            raise ValueError('Invalid nonce')
        amr = claims.get('amr')
        if not isinstance(amr, list) or 'mfa' not in amr:
            raise PermissionError('Sign-in requires two-factor authentication. Ask your administrator to enable MFA in Auth0.')
        auth_time = claims['auth_time']
        if type(auth_time) not in (int, float) or not time.time() - 600 <= auth_time <= time.time() + 30:
            raise ValueError('Fresh authentication required')
        return claims

    def finish(self, state, browser, code):
        with self.lock:
            flow = self.pending.get(state)
            if not flow or flow['expires'] <= time.monotonic() or not secrets.compare_digest(flow['browser'], browser):
                raise PermissionError('Sign-in expired or did not start in this browser. Please try again.')
            del self.pending[state]  # Single use, including failed exchanges.
        claims = self.verify(self.exchange(code, flow['verifier']), flow['nonce'])
        seconds = min(600, int(claims['exp'] - time.time()))
        if seconds <= 0:
            raise PermissionError('Sign-in expired. Please try again.')
        ticket = secrets.token_urlsafe(48)
        with psycopg.connect(self.settings.broker_dsn) as conn:
            if flow['invitation']:
                if claims.get('email_verified') is not True or not isinstance(claims.get('email'), str):
                    raise PermissionError('Invitation requires a verified email in Auth0.')
                conn.execute('SELECT security.accept_identity_invitation(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)', (
                    hashlib.sha256(flow['invitation'].encode()).digest(), flow['organization'], self.settings.issuer,
                    claims['sub'], claims['email'], claims.get('name') or claims['email'], self.audience,
                    datetime.now(timezone.utc) + timedelta(seconds=seconds), hashlib.sha256(ticket.encode()).digest(),
                    uuid7(), uuid7(), uuid7(), uuid7(), uuid7()))
            else:
                conn.execute('SELECT security.issue_identity_ticket(%s,%s,%s,%s,%s,%s,%s)', (
                    hashlib.sha256(ticket.encode()).digest(), flow['organization'], self.settings.issuer,
                    claims['sub'], self.audience, datetime.now(timezone.utc) + timedelta(seconds=seconds), uuid7()))
        return ticket, seconds

    def revoke(self, ticket):
        with psycopg.connect(self.settings.broker_dsn) as conn:
            conn.execute('SELECT security.revoke_identity_ticket(%s)', (hashlib.sha256(ticket.encode()).digest(),))

    def logout_url(self):
        return self.settings.issuer + 'v2/logout?' + urlencode({'client_id': self.settings.client_id, 'returnTo': self.origin + '/'})
