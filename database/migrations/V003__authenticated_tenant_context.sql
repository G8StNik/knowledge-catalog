-- The authentication broker verifies an external identity before issuing a short-lived
-- opaque ticket. Runtime connections cannot mint tickets or forge principals via GUCs.
CREATE TABLE security.session_ticket (
  token_hash bytea PRIMARY KEY CHECK (octet_length(token_hash) = 32),
  organization_id uuid NOT NULL, principal_id uuid NOT NULL, database_role name NOT NULL,
  expires_at timestamptz NOT NULL,
  FOREIGN KEY (organization_id,principal_id) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT
);
CREATE INDEX session_ticket_expiry ON security.session_ticket(expires_at);
REVOKE ALL ON security.session_ticket FROM PUBLIC;

GRANT USAGE ON SCHEMA security, core, identity TO kc_context_owner;
GRANT SELECT ON security.session_ticket, core.organization, identity.principal,
  identity.organization_membership, identity.account TO kc_context_owner;

CREATE FUNCTION security.context() RETURNS TABLE(organization_id uuid, principal_id uuid, principal_type text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog AS $$
  SELECT p.organization_id, p.principal_id, p.principal_type
  FROM security.session_ticket t
  JOIN identity.principal p USING (organization_id,principal_id)
  JOIN core.organization o USING (organization_id)
  LEFT JOIN identity.organization_membership m ON m.organization_id=p.organization_id AND m.account_id=p.account_id
  LEFT JOIN identity.account a ON a.account_id=p.account_id
  WHERE t.token_hash = public.digest(nullif(current_setting('kc.session_token',true),''),'sha256')
    AND t.database_role = session_user AND t.expires_at > statement_timestamp()
    AND p.status='ACTIVE' AND p.principal_type <> 'GROUP'
    AND o.status='ACTIVE' AND o.deleted_at IS NULL
    AND (p.principal_type <> 'USER' OR (m.status='ACTIVE' AND m.left_at IS NULL AND a.status='ACTIVE'))
$$;
ALTER FUNCTION security.context() OWNER TO kc_context_owner;

CREATE FUNCTION security.current_organization() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT organization_id FROM security.context()
$$;
CREATE FUNCTION security.current_principal() RETURNS uuid LANGUAGE sql STABLE AS $$
  SELECT principal_id FROM security.context()
$$;
CREATE FUNCTION security.begin_context(token text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF length(token) < 40 THEN RAISE EXCEPTION 'Invalid session ticket' USING ERRCODE='28000'; END IF;
  PERFORM set_config('kc.session_token',token,true);
  IF security.current_organization() IS NULL THEN
    RAISE EXCEPTION 'Invalid, expired or revoked session ticket' USING ERRCODE='28000';
  END IF;
END $$;

CREATE FUNCTION security.issue_ticket(token_hash bytea, tenant uuid, actor uuid, audience name, expires timestamptz)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog AS $$
DECLARE kind text;
BEGIN
  IF expires <= clock_timestamp() OR expires > clock_timestamp() + interval '15 minutes' THEN
    RAISE EXCEPTION 'Ticket lifetime must be at most 15 minutes' USING ERRCODE='23514';
  END IF;
  SELECT principal_type INTO kind FROM identity.principal WHERE organization_id=tenant AND principal_id=actor AND status='ACTIVE';
  IF kind IS NULL OR kind='GROUP' THEN RAISE EXCEPTION 'Invalid actor' USING ERRCODE='23514'; END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname=audience AND rolcanlogin AND NOT rolsuper AND NOT rolbypassrls) THEN
    RAISE EXCEPTION 'Audience must be a nonprivileged LOGIN role' USING ERRCODE='23514';
  END IF;
  IF kind='AI_AGENT' AND (NOT pg_has_role(audience,'kc_ai_agent','MEMBER')
      OR pg_has_role(audience,'kc_human_approver','MEMBER') OR pg_has_role(audience,'kc_platform_admin','MEMBER')) THEN
    RAISE EXCEPTION 'AI requires isolated proposal-only database credentials' USING ERRCODE='42501';
  END IF;
  IF pg_has_role(audience,'kc_human_approver','MEMBER') AND kind <> 'USER' THEN
    RAISE EXCEPTION 'Approval connection requires a human identity' USING ERRCODE='42501';
  END IF;
  INSERT INTO security.session_ticket VALUES(token_hash,tenant,actor,audience,expires);
END $$;
GRANT EXECUTE ON FUNCTION security.issue_ticket(bytea,uuid,uuid,name,timestamptz) TO kc_platform_admin;

GRANT USAGE ON SCHEMA core,identity,catalog,governance,security,audit TO
  kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;
GRANT EXECUTE ON FUNCTION security.context(),security.current_organization(),security.current_principal(),security.begin_context(text)
  TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;

-- Global accounts never receive tenant-facing table access.
ALTER TABLE identity.account ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity.account FORCE ROW LEVEL SECURITY;
CREATE POLICY platform_account ON identity.account TO kc_platform_admin USING (true) WITH CHECK (true);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['core.organization','core.workspace','core.organization_setting',
    'identity.principal','identity.organization_membership','identity.external_identity','identity.group_membership'] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY tenant_isolation ON %s TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization())',t);
    EXECUTE format('CREATE POLICY platform_provisioning ON %s TO kc_platform_admin USING (true) WITH CHECK (true)',t);
    EXECUTE format('GRANT SELECT ON %s TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver',t);
    EXECUTE format('GRANT SELECT,INSERT,UPDATE ON %s TO kc_platform_admin',t);
  END LOOP;
END $$;
GRANT USAGE ON SCHEMA core, identity, security TO kc_platform_admin;
GRANT SELECT,INSERT,UPDATE ON identity.account TO kc_platform_admin;
-- Revocation and expired-ticket cleanup are restricted to the authentication broker.
GRANT DELETE ON security.session_ticket TO kc_platform_admin;
