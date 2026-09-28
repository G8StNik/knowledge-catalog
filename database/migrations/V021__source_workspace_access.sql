-- A retained source ACL must not outlive access to its owning workspace.
-- Legacy externally provisioned sources have no owning workspace and keep their ACL rule.
CREATE OR REPLACE FUNCTION security.has_source_access(artifact uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
  SELECT EXISTS(
    SELECT FROM security.source_acl acl
    JOIN source.source_artifact a USING (organization_id,source_artifact_id)
    WHERE acl.organization_id=security.current_organization()
      AND acl.source_artifact_id=artifact
      AND acl.principal_id=security.current_principal()
      AND acl.is_allowed AND acl.valid_until>statement_timestamp()
      AND (a.owning_workspace_id IS NULL OR security.has_workspace_access(a.owning_workspace_id))
  )
$$;
