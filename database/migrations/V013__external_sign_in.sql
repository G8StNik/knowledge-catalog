-- The web authentication adapter has a separate, narrowly scoped broker login.
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='kc_auth_broker') THEN
    CREATE ROLE kc_auth_broker NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
  END IF;
END $$;
GRANT USAGE ON SCHEMA security TO kc_auth_broker;

CREATE FUNCTION security.issue_identity_ticket(token_hash bytea, organization_key text,
  issuer text, subject text, audience name, expires timestamptz, event_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE tenant uuid; actor uuid;
BEGIN
  -- The trusted adapter verifies signature, issuer, audience, nonce and MFA first.
  -- Email claims are deliberately not used for linking or authorization.
  SELECT p.organization_id,p.principal_id INTO tenant,actor
  FROM identity.external_identity e
  JOIN identity.principal p USING(organization_id,principal_id)
  JOIN core.organization o USING(organization_id)
  JOIN identity.organization_membership m ON m.organization_id=p.organization_id AND m.account_id=p.account_id
  JOIN identity.account a ON a.account_id=p.account_id
  WHERE o.organization_key=issue_identity_ticket.organization_key::public.citext
    AND e.provider='oidc' AND e.provider_tenant_id=issuer AND e.provider_object_id=subject
    AND o.status='ACTIVE' AND o.deleted_at IS NULL AND p.principal_type='USER' AND p.status='ACTIVE'
    AND m.status='ACTIVE' AND m.left_at IS NULL AND a.status='ACTIVE';
  IF actor IS NULL THEN
    RAISE EXCEPTION 'Organization membership unavailable' USING ERRCODE='42501';
  END IF;
  IF pg_has_role(audience,'kc_platform_admin','MEMBER') OR pg_has_role(audience,'kc_context_owner','MEMBER')
    OR pg_has_role(audience,'kc_auth_broker','MEMBER') OR NOT pg_has_role(audience,'kc_human_approver','MEMBER') THEN
    RAISE EXCEPTION 'Nonprivileged human runtime required' USING ERRCODE='42501';
  END IF;
  PERFORM security.issue_ticket(token_hash,tenant,actor,audience,expires);
  INSERT INTO audit.event(audit_event_id,organization_id,actor_principal_id,action,entity_type,entity_id)
    VALUES(event_id,tenant,actor,'USER_SIGN_IN','principal',actor);
END $$;
GRANT EXECUTE ON FUNCTION security.issue_identity_ticket(bytea,text,text,text,name,timestamptz,uuid) TO kc_auth_broker;

CREATE FUNCTION security.revoke_identity_ticket(token_hash bytea) RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog AS $$
  DELETE FROM security.session_ticket t WHERE t.token_hash=revoke_identity_ticket.token_hash
$$;
GRANT EXECUTE ON FUNCTION security.revoke_identity_ticket(bytea) TO kc_auth_broker;
