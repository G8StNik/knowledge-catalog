-- Source readers are visible and editable only to authorized workspace editors.
CREATE FUNCTION source.access_members(artifact uuid)
RETURNS TABLE(principal_id uuid, display_name text, is_allowed boolean, valid_until timestamptz)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE workspace uuid;
BEGIN
  SELECT a.owning_workspace_id INTO workspace FROM source.source_artifact a
    WHERE a.organization_id=security.current_organization() AND a.source_artifact_id=artifact;
  IF workspace IS NULL OR NOT security.has_workspace_access(workspace,'edit')
      OR NOT security.has_source_access(artifact) THEN
    RAISE EXCEPTION 'Source permission management unavailable' USING ERRCODE='42501'; END IF;
  RETURN QUERY SELECT p.principal_id,p.display_name,coalesce(acl.is_allowed,false),acl.valid_until
    FROM security.workspace_access w JOIN identity.principal p
      ON p.organization_id=w.organization_id AND p.principal_id=w.principal_id
    LEFT JOIN security.source_acl acl ON acl.organization_id=w.organization_id
      AND acl.source_artifact_id=artifact AND acl.principal_id=w.principal_id
    WHERE w.organization_id=security.current_organization() AND w.workspace_id=workspace
      AND p.principal_type='USER' AND p.status='ACTIVE'
    ORDER BY p.display_name;
END $$;

CREATE FUNCTION source.set_access(artifact uuid,recipient uuid,allowed boolean,event_id uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE tenant uuid; actor uuid; workspace uuid; owner uuid;
BEGIN
  SELECT organization_id,principal_id INTO tenant,actor FROM security.context() WHERE principal_type='USER';
  SELECT a.owning_workspace_id,a.owner_principal_id INTO workspace,owner FROM source.source_artifact a
    WHERE a.organization_id=tenant AND a.source_artifact_id=artifact FOR UPDATE;
  IF tenant IS NULL OR actor IS NULL OR workspace IS NULL
      OR NOT security.has_workspace_access(workspace,'edit') OR NOT security.has_source_access(artifact) THEN
    RAISE EXCEPTION 'Source permission management unavailable' USING ERRCODE='42501'; END IF;
  IF NOT EXISTS(SELECT FROM identity.principal p JOIN security.workspace_access w
      ON w.organization_id=p.organization_id AND w.principal_id=p.principal_id
      WHERE p.organization_id=tenant AND p.principal_id=recipient AND p.principal_type='USER'
        AND p.status='ACTIVE' AND w.workspace_id=workspace) THEN
    RAISE EXCEPTION 'Active workspace member required' USING ERRCODE='23514'; END IF;
  IF NOT allowed AND recipient IN (actor,owner) THEN
    RAISE EXCEPTION 'Cannot remove your own or the source owner access' USING ERRCODE='23514'; END IF;
  INSERT INTO security.source_acl(organization_id,source_artifact_id,principal_id,is_allowed,valid_until)
    VALUES(tenant,artifact,recipient,allowed,statement_timestamp()+interval '1 year')
    ON CONFLICT(organization_id,source_artifact_id,principal_id) DO UPDATE
      SET is_allowed=excluded.is_allowed,valid_until=excluded.valid_until;
  INSERT INTO audit.event(audit_event_id,organization_id,actor_principal_id,action,entity_type,entity_id)
    VALUES(event_id,tenant,actor,CASE WHEN allowed THEN 'SOURCE_ACCESS_GRANTED' ELSE 'SOURCE_ACCESS_REVOKED' END,
      'source_artifact',artifact);
END $$;
GRANT EXECUTE ON FUNCTION source.access_members(uuid),source.set_access(uuid,uuid,boolean,uuid)
  TO kc_application,kc_human_approver;
