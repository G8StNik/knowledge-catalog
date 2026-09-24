-- Allow reviewed Office and saved HTML originals through the governed source command.
CREATE OR REPLACE FUNCTION source.document_command(action text,payload jsonb,event_id uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE tenant uuid; actor uuid; workspace uuid; artifact uuid; version uuid; source_id uuid;
  revision uuid; classification uuid; owner uuid; recipient uuid; next_number integer;
BEGIN
  SELECT organization_id,principal_id INTO tenant,actor FROM security.context() WHERE principal_type='USER';
  workspace:=(payload->>'workspace_id')::uuid;
  IF tenant IS NULL OR actor IS NULL OR NOT security.has_workspace_access(workspace,'edit') THEN
    RAISE EXCEPTION 'Authorized human workspace editor required' USING ERRCODE='42501'; END IF;
  IF action NOT IN ('create','version') THEN RAISE EXCEPTION 'Unknown source action' USING ERRCODE='22023'; END IF;
  IF nullif(payload->>'content_base64','') IS NULL OR nullif(btrim(payload->>'text_content'),'') IS NULL
      OR nullif(btrim(payload->>'file_name'),'') IS NULL
      OR payload->>'media_type' NOT IN ('application/pdf','text/plain','text/markdown',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'application/vnd.openxmlformats-officedocument.presentationml.presentation','text/html') THEN
    RAISE EXCEPTION 'Valid source file metadata and readable text required' USING ERRCODE='23514'; END IF;
  IF octet_length(decode(payload->>'content_base64','base64'))=0
      OR octet_length(decode(payload->>'content_base64','base64'))>10485760 THEN
    RAISE EXCEPTION 'Source file must contain 1 byte to 10 MB' USING ERRCODE='22023'; END IF;
  owner:=coalesce((payload->>'owner_principal_id')::uuid,actor);
  IF NOT EXISTS(SELECT FROM identity.principal p WHERE p.organization_id=tenant AND p.principal_id=owner
      AND p.principal_type='USER' AND p.status='ACTIVE') THEN
    RAISE EXCEPTION 'Active human owner required' USING ERRCODE='23514'; END IF;
  revision:=(payload->>'configuration_revision_id')::uuid;
  classification:=(payload->>'classification_id')::uuid;
  IF NOT EXISTS(SELECT FROM governance.classification c WHERE c.organization_id=tenant
      AND c.configuration_revision_id=revision AND c.classification_id=classification AND c.is_enabled) THEN
    RAISE EXCEPTION 'Enabled classification required' USING ERRCODE='23514'; END IF;
  IF action='create' THEN
    IF nullif(btrim(payload->>'document_key'),'') IS NULL OR nullif(btrim(payload->>'title'),'') IS NULL THEN
      RAISE EXCEPTION 'Document number and title are required' USING ERRCODE='23514'; END IF;
    artifact:=(payload->>'source_artifact_id')::uuid;
    version:=(payload->>'artifact_version_id')::uuid;
    SELECT knowledge_source_id INTO source_id FROM source.knowledge_source
      WHERE organization_id=tenant AND source_key='user_uploads';
    IF source_id IS NULL THEN
      source_id:=(payload->>'knowledge_source_id')::uuid;
      INSERT INTO source.knowledge_source VALUES(source_id,tenant,'user_uploads','User uploads','local_upload');
    END IF;
    INSERT INTO source.source_artifact(source_artifact_id,organization_id,knowledge_source_id,external_key,source_uri,
      owning_workspace_id,owner_principal_id,configuration_revision_id,classification_id,title)
    VALUES(artifact,tenant,source_id,payload->>'document_key','upload:'||artifact::text,workspace,owner,revision,classification,payload->>'title');
    next_number:=1;
  ELSE
    artifact:=(payload->>'source_artifact_id')::uuid;
    PERFORM FROM source.source_artifact a WHERE a.organization_id=tenant AND a.source_artifact_id=artifact
      AND a.owning_workspace_id=workspace AND security.has_source_access(artifact) FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Source document unavailable' USING ERRCODE='42501'; END IF;
    SELECT max(v.version_key::integer)+1 INTO next_number FROM source.source_artifact a
      JOIN source.artifact_version v USING(organization_id,source_artifact_id)
      WHERE a.organization_id=tenant AND a.source_artifact_id=artifact AND a.owning_workspace_id=workspace
      AND security.has_source_access(artifact) AND v.version_key ~ '^[0-9]+$';
    IF next_number IS NULL THEN RAISE EXCEPTION 'Source document unavailable' USING ERRCODE='42501'; END IF;
    version:=(payload->>'artifact_version_id')::uuid;
  END IF;
  INSERT INTO source.artifact_version(artifact_version_id,organization_id,source_artifact_id,version_key,content,
    file_name,media_type,original_content,uploaded_by,effective_from,effective_to)
  VALUES(version,tenant,artifact,next_number::text,payload->>'text_content',payload->>'file_name',payload->>'media_type',
    decode(payload->>'content_base64','base64'),actor,(payload->>'effective_from')::date,(payload->>'effective_to')::date);
  INSERT INTO security.source_acl VALUES(tenant,artifact,actor,true,statement_timestamp()+interval '1 year')
    ON CONFLICT(organization_id,source_artifact_id,principal_id) DO UPDATE
      SET is_allowed=true,valid_until=greatest(security.source_acl.valid_until,excluded.valid_until);
  FOR recipient IN SELECT value::uuid FROM jsonb_array_elements_text(coalesce(payload->'principal_ids','[]')) LOOP
    IF NOT EXISTS(SELECT FROM security.workspace_access w WHERE w.organization_id=tenant AND w.workspace_id=workspace
        AND w.principal_id=recipient) THEN RAISE EXCEPTION 'Recipient requires workspace access' USING ERRCODE='23514'; END IF;
    INSERT INTO security.source_acl VALUES(tenant,artifact,recipient,true,statement_timestamp()+interval '1 year')
      ON CONFLICT(organization_id,source_artifact_id,principal_id) DO UPDATE SET is_allowed=true,valid_until=excluded.valid_until;
  END LOOP;
  INSERT INTO audit.event(audit_event_id,organization_id,actor_principal_id,action,entity_type,entity_id)
    VALUES(event_id,tenant,actor,'SOURCE_'||upper(action),'artifact_version',version);
  RETURN version;
END $$;
GRANT EXECUTE ON FUNCTION source.document_command(text,jsonb,uuid) TO kc_application,kc_human_approver;
