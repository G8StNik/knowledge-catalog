-- Give a human document owner access when the document is created.
CREATE FUNCTION source.grant_document_owner() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
BEGIN
  IF NEW.owner_principal_id IS NOT NULL THEN
    IF NOT EXISTS(SELECT FROM security.workspace_access w WHERE w.organization_id=NEW.organization_id
        AND w.workspace_id=NEW.owning_workspace_id AND w.principal_id=NEW.owner_principal_id) THEN
      RAISE EXCEPTION 'Source owner requires workspace access' USING ERRCODE='23514'; END IF;
    INSERT INTO security.source_acl(organization_id,source_artifact_id,principal_id,is_allowed,valid_until)
      VALUES(NEW.organization_id,NEW.source_artifact_id,NEW.owner_principal_id,true,
        statement_timestamp()+interval '1 year');
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER grant_document_owner AFTER INSERT ON source.source_artifact
  FOR EACH ROW EXECUTE FUNCTION source.grant_document_owner();
INSERT INTO security.source_acl(organization_id,source_artifact_id,principal_id,is_allowed,valid_until)
  SELECT a.organization_id,a.source_artifact_id,a.owner_principal_id,true,statement_timestamp()+interval '1 year'
  FROM source.source_artifact a JOIN security.workspace_access w
    ON w.organization_id=a.organization_id AND w.workspace_id=a.owning_workspace_id
      AND w.principal_id=a.owner_principal_id
  WHERE a.owner_principal_id IS NOT NULL
  ON CONFLICT(organization_id,source_artifact_id,principal_id) DO UPDATE
    SET is_allowed=true,valid_until=greatest(security.source_acl.valid_until,excluded.valid_until);
