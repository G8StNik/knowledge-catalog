-- Keep historical authorship and identity rows, while ending all current access.
CREATE FUNCTION identity.deactivate_member(p_principal uuid,p_event_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid; tenant uuid; member_account uuid;
BEGIN
  actor:=identity.require_organization_admin(); tenant:=security.current_organization();
  IF p_principal=actor THEN
    RAISE EXCEPTION 'Administrators cannot deactivate themselves' USING ERRCODE='23514';
  END IF;
  -- Serialize concurrent administrator changes and the last-admin check.
  PERFORM 1 FROM core.organization o WHERE o.organization_id=tenant FOR UPDATE;
  SELECT p.account_id INTO member_account FROM identity.principal p
    JOIN identity.organization_membership m ON m.organization_id=p.organization_id AND m.account_id=p.account_id
    WHERE p.organization_id=tenant AND p.principal_id=p_principal AND p.principal_type='USER'
      AND p.status='ACTIVE' AND m.status='ACTIVE' AND m.left_at IS NULL FOR UPDATE OF p,m;
  IF member_account IS NULL THEN
    RAISE EXCEPTION 'Active member unavailable' USING ERRCODE='42501';
  END IF;
  IF EXISTS(SELECT FROM security.organization_admin a WHERE a.organization_id=tenant AND a.principal_id=p_principal) THEN
    IF (SELECT count(*) FROM security.organization_admin a JOIN identity.principal p
          ON p.organization_id=a.organization_id AND p.principal_id=a.principal_id
          WHERE a.organization_id=tenant AND p.status='ACTIVE')<=1 THEN
      RAISE EXCEPTION 'Last administrator cannot be deactivated' USING ERRCODE='23514';
    END IF;
    DELETE FROM security.organization_admin a WHERE a.organization_id=tenant AND a.principal_id=p_principal;
  END IF;
  DELETE FROM security.session_ticket t WHERE t.organization_id=tenant AND t.principal_id=p_principal;
  DELETE FROM security.workspace_access w WHERE w.organization_id=tenant AND w.principal_id=p_principal;
  DELETE FROM security.source_acl a WHERE a.organization_id=tenant AND a.principal_id=p_principal;
  DELETE FROM security.configuration_permission c WHERE c.organization_id=tenant AND c.principal_id=p_principal;
  UPDATE identity.group_membership g SET effective_to=statement_timestamp()
    WHERE g.organization_id=tenant AND g.member_principal_id=p_principal AND g.effective_to IS NULL
      AND g.effective_from<statement_timestamp();
  UPDATE identity.principal p SET status='DEACTIVATED',updated_at=clock_timestamp()
    WHERE p.organization_id=tenant AND p.principal_id=p_principal;
  UPDATE identity.organization_membership m SET status='LEFT',left_at=clock_timestamp()
    WHERE m.organization_id=tenant AND m.account_id=member_account;
  INSERT INTO audit.event(audit_event_id,organization_id,actor_principal_id,action,entity_type,entity_id)
    VALUES(p_event_id,tenant,actor,'MEMBER_DEACTIVATED','principal',p_principal);
END $$;
GRANT EXECUTE ON FUNCTION identity.deactivate_member(uuid,uuid) TO kc_application,kc_human_approver;
