-- Human organization administrators can prepare one-time invitations. The Auth0
-- broker may redeem them only after verifying the subject, MFA and email claim.
CREATE TABLE security.organization_admin (
  organization_id uuid NOT NULL, principal_id uuid NOT NULL,
  PRIMARY KEY(organization_id,principal_id),
  FOREIGN KEY(organization_id,principal_id) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT
);
CREATE TABLE identity.invitation (
  invitation_id uuid PRIMARY KEY, organization_id uuid NOT NULL REFERENCES core.organization ON DELETE RESTRICT,
  token_hash bytea NOT NULL UNIQUE CHECK(octet_length(token_hash)=32),
  email public.citext NOT NULL, workspace_id uuid NOT NULL,
  can_edit boolean NOT NULL DEFAULT false, can_review boolean NOT NULL DEFAULT false,
  status text NOT NULL DEFAULT 'PENDING' CHECK(status IN ('PENDING','ACCEPTED','REVOKED')),
  expires_at timestamptz NOT NULL, created_by uuid NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  accepted_by uuid, accepted_at timestamptz,
  UNIQUE(organization_id,invitation_id),
  FOREIGN KEY(organization_id,workspace_id) REFERENCES core.workspace(organization_id,workspace_id) ON DELETE RESTRICT,
  FOREIGN KEY(organization_id,created_by) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT,
  FOREIGN KEY(organization_id,accepted_by) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT,
  CHECK((status='ACCEPTED')=(accepted_by IS NOT NULL AND accepted_at IS NOT NULL))
);
ALTER TABLE security.organization_admin ENABLE ROW LEVEL SECURITY;
ALTER TABLE security.organization_admin FORCE ROW LEVEL SECURITY;
CREATE POLICY platform_admin ON security.organization_admin TO kc_platform_admin USING(true) WITH CHECK(true);
GRANT SELECT,INSERT,DELETE ON security.organization_admin TO kc_platform_admin;
ALTER TABLE identity.invitation ENABLE ROW LEVEL SECURITY;
ALTER TABLE identity.invitation FORCE ROW LEVEL SECURITY;
CREATE POLICY platform_invitation ON identity.invitation TO kc_platform_admin USING(true) WITH CHECK(true);
GRANT SELECT,INSERT,UPDATE ON identity.invitation TO kc_platform_admin;

CREATE FUNCTION identity.require_organization_admin() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid; tenant uuid;
BEGIN
  SELECT organization_id,principal_id INTO tenant,actor FROM security.context() WHERE principal_type='USER';
  IF actor IS NULL OR NOT EXISTS(SELECT FROM security.organization_admin a
      WHERE a.organization_id=tenant AND a.principal_id=actor) THEN
    RAISE EXCEPTION 'Organization administrator required' USING ERRCODE='42501'; END IF;
  RETURN actor;
END $$;
CREATE FUNCTION identity.list_invitations()
RETURNS TABLE(invitation_id uuid,email public.citext,workspace_id uuid,can_edit boolean,can_review boolean,
  status text,expires_at timestamptz,created_at timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  PERFORM identity.require_organization_admin();
  RETURN QUERY SELECT i.invitation_id,i.email,i.workspace_id,i.can_edit,i.can_review,i.status,i.expires_at,i.created_at
    FROM identity.invitation i WHERE i.organization_id=security.current_organization() ORDER BY i.created_at DESC;
END $$;
CREATE FUNCTION identity.create_invitation(invitation_id uuid,token_hash bytea,email text,workspace uuid,
  can_edit boolean,can_review boolean,expires timestamptz,event_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid; tenant uuid;
BEGIN
  actor:=identity.require_organization_admin(); tenant:=security.current_organization();
  IF nullif(btrim(email),'') IS NULL OR length(email)>320 OR position('@' in email)<2
      OR octet_length(token_hash)<>32 OR expires<=statement_timestamp()
      OR expires>statement_timestamp()+interval '7 days' THEN
    RAISE EXCEPTION 'Invalid invitation' USING ERRCODE='23514'; END IF;
  IF NOT EXISTS(SELECT FROM core.workspace w WHERE w.organization_id=tenant AND w.workspace_id=workspace
      AND w.status='ACTIVE' AND w.deleted_at IS NULL) THEN
    RAISE EXCEPTION 'Active workspace required' USING ERRCODE='23514'; END IF;
  INSERT INTO identity.invitation(invitation_id,organization_id,token_hash,email,workspace_id,can_edit,can_review,expires_at,created_by)
    VALUES(invitation_id,tenant,token_hash,btrim(email)::public.citext,workspace,can_edit,can_review,expires,actor);
  INSERT INTO audit.event(audit_event_id,organization_id,actor_principal_id,action,entity_type,entity_id)
    VALUES(event_id,tenant,actor,'INVITATION_CREATED','invitation',invitation_id);
END $$;
CREATE FUNCTION identity.revoke_invitation(invitation uuid,event_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid; tenant uuid;
BEGIN
  actor:=identity.require_organization_admin(); tenant:=security.current_organization();
  UPDATE identity.invitation SET status='REVOKED' WHERE organization_id=tenant AND invitation_id=invitation AND status='PENDING';
  IF NOT FOUND THEN RAISE EXCEPTION 'Pending invitation unavailable' USING ERRCODE='42501'; END IF;
  INSERT INTO audit.event(audit_event_id,organization_id,actor_principal_id,action,entity_type,entity_id)
    VALUES(event_id,tenant,actor,'INVITATION_REVOKED','invitation',invitation);
END $$;

CREATE FUNCTION security.accept_identity_invitation(token_hash bytea,organization_key text,issuer text,subject text,
  verified_email text,display_name text,audience name,expires timestamptz,ticket_hash bytea,
  account_id uuid,membership_id uuid,principal_id uuid,external_id uuid,event_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE invitation_row identity.invitation%ROWTYPE; tenant uuid; existing_account uuid;
BEGIN
  SELECT o.organization_id INTO tenant FROM core.organization o
    WHERE o.organization_key=organization_key::public.citext AND o.status='ACTIVE' AND o.deleted_at IS NULL;
  SELECT * INTO invitation_row FROM identity.invitation i WHERE i.organization_id=tenant
    AND i.token_hash=accept_identity_invitation.token_hash AND i.status='PENDING'
    AND i.expires_at>statement_timestamp() FOR UPDATE;
  IF invitation_row.invitation_id IS NULL OR nullif(btrim(subject),'') IS NULL
      OR nullif(btrim(issuer),'') IS NULL OR nullif(btrim(display_name),'') IS NULL
      OR invitation_row.email<>verified_email::public.citext THEN
    RAISE EXCEPTION 'Invitation unavailable or identity mismatch' USING ERRCODE='42501'; END IF;
  IF pg_has_role(audience,'kc_platform_admin','MEMBER') OR pg_has_role(audience,'kc_context_owner','MEMBER')
      OR pg_has_role(audience,'kc_auth_broker','MEMBER') OR NOT pg_has_role(audience,'kc_human_approver','MEMBER') THEN
    RAISE EXCEPTION 'Nonprivileged human runtime required' USING ERRCODE='42501'; END IF;
  IF EXISTS(SELECT FROM identity.external_identity e WHERE e.organization_id=tenant AND e.provider='oidc'
      AND e.provider_tenant_id=issuer AND e.provider_object_id=subject) THEN
    RAISE EXCEPTION 'Identity already linked' USING ERRCODE='42501'; END IF;
  SELECT a.account_id INTO existing_account FROM identity.account a WHERE a.primary_email=invitation_row.email AND a.status='ACTIVE';
  IF existing_account IS NULL THEN
    INSERT INTO identity.account(account_id,display_name,primary_email)
      VALUES(account_id,display_name,invitation_row.email);
    existing_account:=account_id;
  END IF;
  IF EXISTS(SELECT FROM identity.organization_membership m WHERE m.organization_id=tenant AND m.account_id=existing_account) THEN
    RAISE EXCEPTION 'Organization membership already exists' USING ERRCODE='42501'; END IF;
  INSERT INTO identity.organization_membership(organization_membership_id,organization_id,account_id)
    VALUES(membership_id,tenant,existing_account);
  INSERT INTO identity.principal(principal_id,organization_id,account_id,principal_type,display_name,email)
    VALUES(principal_id,tenant,existing_account,'USER',display_name,invitation_row.email);
  INSERT INTO identity.external_identity(external_identity_id,organization_id,principal_id,provider,provider_tenant_id,provider_object_id,provider_email)
    VALUES(external_id,tenant,principal_id,'oidc',issuer,subject,invitation_row.email);
  INSERT INTO security.workspace_access(organization_id,workspace_id,principal_id,can_edit,can_review)
    VALUES(tenant,invitation_row.workspace_id,principal_id,invitation_row.can_edit,invitation_row.can_review);
  UPDATE identity.invitation SET status='ACCEPTED',accepted_by=principal_id,accepted_at=statement_timestamp()
    WHERE invitation_id=invitation_row.invitation_id;
  PERFORM security.issue_ticket(ticket_hash,tenant,principal_id,audience,expires);
  INSERT INTO audit.event(audit_event_id,organization_id,actor_principal_id,action,entity_type,entity_id)
    VALUES(event_id,tenant,principal_id,'INVITATION_ACCEPTED','invitation',invitation_row.invitation_id);
END $$;
GRANT EXECUTE ON FUNCTION identity.require_organization_admin(),identity.list_invitations(),
  identity.create_invitation(uuid,bytea,text,uuid,boolean,boolean,timestamptz,uuid),
  identity.revoke_invitation(uuid,uuid) TO kc_human_approver;
GRANT EXECUTE ON FUNCTION security.accept_identity_invitation(bytea,text,text,text,text,text,name,timestamptz,
  bytea,uuid,uuid,uuid,uuid,uuid) TO kc_auth_broker;
