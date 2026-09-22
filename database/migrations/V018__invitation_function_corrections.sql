DROP FUNCTION identity.revoke_invitation(uuid,uuid);
DROP FUNCTION security.accept_identity_invitation(bytea,text,text,text,text,text,name,timestamptz,
  bytea,uuid,uuid,uuid,uuid,uuid);
CREATE FUNCTION identity.revoke_invitation(p_invitation uuid,p_event_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid; tenant uuid;
BEGIN
  actor:=identity.require_organization_admin(); tenant:=security.current_organization();
  UPDATE identity.invitation i SET status='REVOKED'
    WHERE i.organization_id=tenant AND i.invitation_id=p_invitation AND i.status='PENDING';
  IF NOT FOUND THEN RAISE EXCEPTION 'Pending invitation unavailable' USING ERRCODE='42501'; END IF;
  INSERT INTO audit.event(audit_event_id,organization_id,actor_principal_id,action,entity_type,entity_id)
    VALUES(p_event_id,tenant,actor,'INVITATION_REVOKED','invitation',p_invitation);
END $$;

CREATE FUNCTION security.accept_identity_invitation(p_token_hash bytea,p_organization_key text,
  p_issuer text,p_subject text,p_verified_email text,p_display_name text,p_audience name,p_expires timestamptz,
  p_ticket_hash bytea,p_account_id uuid,p_membership_id uuid,p_principal_id uuid,p_external_id uuid,p_event_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE invitation_row identity.invitation%ROWTYPE; tenant uuid; existing_account uuid;
BEGIN
  SELECT o.organization_id INTO tenant FROM core.organization o
    WHERE o.organization_key=p_organization_key::public.citext AND o.status='ACTIVE' AND o.deleted_at IS NULL;
  SELECT * INTO invitation_row FROM identity.invitation i WHERE i.organization_id=tenant
    AND i.token_hash=p_token_hash AND i.status='PENDING' AND i.expires_at>statement_timestamp() FOR UPDATE;
  IF invitation_row.invitation_id IS NULL OR nullif(btrim(p_subject),'') IS NULL
      OR nullif(btrim(p_issuer),'') IS NULL OR nullif(btrim(p_display_name),'') IS NULL
      OR nullif(btrim(p_verified_email),'') IS NULL
      OR invitation_row.email<>p_verified_email::public.citext THEN
    RAISE EXCEPTION 'Invitation unavailable or identity mismatch' USING ERRCODE='42501'; END IF;
  IF pg_has_role(p_audience,'kc_platform_admin','MEMBER') OR pg_has_role(p_audience,'kc_context_owner','MEMBER')
      OR pg_has_role(p_audience,'kc_auth_broker','MEMBER') OR NOT pg_has_role(p_audience,'kc_human_approver','MEMBER') THEN
    RAISE EXCEPTION 'Nonprivileged human runtime required' USING ERRCODE='42501'; END IF;
  IF EXISTS(SELECT FROM identity.external_identity e WHERE e.organization_id=tenant AND e.provider='oidc'
      AND e.provider_tenant_id=p_issuer AND e.provider_object_id=p_subject) THEN
    RAISE EXCEPTION 'Identity already linked' USING ERRCODE='42501'; END IF;
  SELECT a.account_id INTO existing_account FROM identity.account a
    WHERE a.primary_email=invitation_row.email AND a.status='ACTIVE';
  IF existing_account IS NULL THEN
    INSERT INTO identity.account(account_id,display_name,primary_email)
      VALUES(p_account_id,p_display_name,invitation_row.email);
    existing_account:=p_account_id;
  END IF;
  IF EXISTS(SELECT FROM identity.organization_membership m WHERE m.organization_id=tenant AND m.account_id=existing_account) THEN
    RAISE EXCEPTION 'Organization membership already exists' USING ERRCODE='42501'; END IF;
  INSERT INTO identity.organization_membership(organization_membership_id,organization_id,account_id)
    VALUES(p_membership_id,tenant,existing_account);
  INSERT INTO identity.principal(principal_id,organization_id,account_id,principal_type,display_name,email)
    VALUES(p_principal_id,tenant,existing_account,'USER',p_display_name,invitation_row.email);
  INSERT INTO identity.external_identity(external_identity_id,organization_id,principal_id,provider,provider_tenant_id,provider_object_id,provider_email)
    VALUES(p_external_id,tenant,p_principal_id,'oidc',p_issuer,p_subject,invitation_row.email);
  INSERT INTO security.workspace_access(organization_id,workspace_id,principal_id,can_edit,can_review)
    VALUES(tenant,invitation_row.workspace_id,p_principal_id,invitation_row.can_edit,invitation_row.can_review);
  UPDATE identity.invitation i SET status='ACCEPTED',accepted_by=p_principal_id,accepted_at=statement_timestamp()
    WHERE i.invitation_id=invitation_row.invitation_id;
  PERFORM security.issue_ticket(p_ticket_hash,tenant,p_principal_id,p_audience,p_expires);
  INSERT INTO audit.event(audit_event_id,organization_id,actor_principal_id,action,entity_type,entity_id)
    VALUES(p_event_id,tenant,p_principal_id,'INVITATION_ACCEPTED','invitation',invitation_row.invitation_id);
END $$;
GRANT EXECUTE ON FUNCTION identity.revoke_invitation(uuid,uuid) TO kc_human_approver;
GRANT EXECUTE ON FUNCTION security.accept_identity_invitation(bytea,text,text,text,text,text,name,timestamptz,
  bytea,uuid,uuid,uuid,uuid,uuid) TO kc_auth_broker;
