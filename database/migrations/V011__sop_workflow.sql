CREATE FUNCTION catalog.version_digest(version uuid) RETURNS text LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
  SELECT encode(public.digest(jsonb_build_object(
    'title',v.title,'summary',v.summary,'content',v.content,'metadata',v.custom_metadata,
    'configuration',v.configuration_revision_id,'type',v.knowledge_type_id,'domain',v.domain_id,
    'authority',v.authority_level_id,'classification',v.classification_id,
    'citations',(SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY c.citation_id),'[]') FROM catalog.citation c WHERE c.organization_id=v.organization_id AND c.knowledge_version_id=v.knowledge_version_id),
    'responsibilities',(SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.knowledge_responsibility_id),'[]') FROM governance.knowledge_responsibility r WHERE r.organization_id=v.organization_id AND r.knowledge_version_id=v.knowledge_version_id)
  )::text,'sha256'),'hex') FROM catalog.knowledge_version v
  WHERE v.organization_id=security.current_organization() AND v.knowledge_version_id=version
$$;

CREATE FUNCTION catalog.validate_knowledge(version uuid) RETURNS void LANGUAGE plpgsql SET search_path=pg_catalog AS $$
DECLARE v catalog.knowledge_version; f record; value jsonb; n integer; k text;
BEGIN
  SELECT * INTO STRICT v FROM catalog.knowledge_version WHERE organization_id=security.current_organization() AND knowledge_version_id=version;
  IF btrim(v.content)='' OR NOT EXISTS(SELECT FROM catalog.citation WHERE organization_id=v.organization_id AND knowledge_version_id=version) THEN
    RAISE EXCEPTION 'Content and source evidence are required' USING ERRCODE='23514'; END IF;
  IF NOT EXISTS(SELECT FROM governance.configuration_activation a WHERE a.organization_id=v.organization_id
      AND a.configuration_revision_id=v.configuration_revision_id AND a.effective_from<=statement_timestamp()
      AND (a.effective_to IS NULL OR a.effective_to>statement_timestamp())) THEN
    RAISE EXCEPTION 'Configuration revision is not effective' USING ERRCODE='23514'; END IF;
  IF NOT EXISTS(SELECT FROM catalog.knowledge_type WHERE organization_id=v.organization_id AND knowledge_type_id=v.knowledge_type_id AND is_enabled)
    OR NOT EXISTS(SELECT FROM catalog.domain WHERE organization_id=v.organization_id AND domain_id=v.domain_id AND is_enabled)
    OR NOT EXISTS(SELECT FROM governance.authority_level WHERE organization_id=v.organization_id AND authority_level_id=v.authority_level_id AND is_enabled)
    OR NOT EXISTS(SELECT FROM governance.classification WHERE organization_id=v.organization_id AND classification_id=v.classification_id AND is_enabled) THEN
    RAISE EXCEPTION 'Disabled configuration cannot be published' USING ERRCODE='23514'; END IF;
  FOR k IN SELECT jsonb_object_keys(v.custom_metadata) LOOP
    IF NOT EXISTS(SELECT FROM catalog.knowledge_type_field a JOIN catalog.custom_field_definition d USING(organization_id,configuration_revision_id,custom_field_definition_id)
      WHERE a.organization_id=v.organization_id AND a.configuration_revision_id=v.configuration_revision_id AND a.knowledge_type_id=v.knowledge_type_id AND d.key=k AND a.is_enabled AND d.is_enabled) THEN
      RAISE EXCEPTION 'Unknown custom metadata field: %',k USING ERRCODE='23514'; END IF;
  END LOOP;
  FOR f IN SELECT d.*,a.is_required AS assignment_required FROM catalog.knowledge_type_field a
    JOIN catalog.custom_field_definition d USING(organization_id,configuration_revision_id,custom_field_definition_id)
    WHERE a.organization_id=v.organization_id AND a.configuration_revision_id=v.configuration_revision_id
      AND a.knowledge_type_id=v.knowledge_type_id AND a.is_enabled AND d.is_enabled LOOP
    value:=v.custom_metadata->f.key;
    IF (f.is_required OR f.assignment_required) AND (value IS NULL OR value='null'::jsonb OR value='""'::jsonb) THEN
      RAISE EXCEPTION 'Required metadata missing: %',f.key USING ERRCODE='23514'; END IF;
    IF f.validation_schema<>'{}' OR f.conditional_rules<>'{}' OR f.calculation<>'{}' THEN
      RAISE EXCEPTION 'Extended metadata rules require a supported evaluator: %',f.key USING ERRCODE='23514'; END IF;
    IF value IS NULL OR value='null'::jsonb THEN CONTINUE; END IF;
    CASE f.data_type
      WHEN 'TEXT','RICHTEXT' THEN IF jsonb_typeof(value)<>'string' THEN RAISE EXCEPTION 'Text required: %',f.key USING ERRCODE='23514'; END IF;
      WHEN 'NUMBER' THEN IF jsonb_typeof(value)<>'number' THEN RAISE EXCEPTION 'Number required: %',f.key USING ERRCODE='23514'; END IF;
      WHEN 'BOOLEAN' THEN IF jsonb_typeof(value)<>'boolean' THEN RAISE EXCEPTION 'Boolean required: %',f.key USING ERRCODE='23514'; END IF;
      WHEN 'DATE' THEN
        IF jsonb_typeof(value)<>'string' OR (value#>>'{}') !~ '^\d{4}-\d{2}-\d{2}$' THEN RAISE EXCEPTION 'ISO date required: %',f.key USING ERRCODE='23514'; END IF;
        PERFORM (value#>>'{}')::date;
      WHEN 'CHOICE' THEN
        IF NOT EXISTS(SELECT FROM catalog.custom_field_choice WHERE organization_id=v.organization_id AND configuration_revision_id=v.configuration_revision_id
          AND custom_field_definition_id=f.custom_field_definition_id AND is_enabled AND to_jsonb(custom_field_choice.value)=value) THEN
          RAISE EXCEPTION 'Invalid choice: %',f.key USING ERRCODE='23514'; END IF;
      ELSE RAISE EXCEPTION 'Unsupported field evaluator: %',f.data_type USING ERRCODE='23514';
    END CASE;
  END LOOP;
  FOR f IN SELECT * FROM governance.responsibility_requirement WHERE organization_id=v.organization_id
      AND configuration_revision_id=v.configuration_revision_id AND knowledge_type_id=v.knowledge_type_id AND is_enabled LOOP
    SELECT count(*) INTO n FROM governance.knowledge_responsibility r JOIN identity.principal p USING(organization_id,principal_id)
      JOIN identity.organization_membership m ON m.organization_id=p.organization_id AND m.account_id=p.account_id
      JOIN identity.account a ON a.account_id=p.account_id
      WHERE r.organization_id=v.organization_id AND r.knowledge_version_id=version AND r.role_id=f.role_id
        AND p.status='ACTIVE' AND p.principal_type='USER' AND m.status='ACTIVE' AND m.left_at IS NULL AND a.status='ACTIVE';
    IF n<f.minimum_count OR (f.maximum_count IS NOT NULL AND n>f.maximum_count) THEN
      RAISE EXCEPTION 'Responsibility requirement not met: %',f.key USING ERRCODE='23514'; END IF;
  END LOOP;
END $$;

CREATE FUNCTION catalog.approval_count(version uuid, required_role uuid) RETURNS integer LANGUAGE sql STABLE SET search_path=pg_catalog AS $$
  SELECT count(DISTINCT r.reviewer_id)::integer FROM governance.knowledge_review r
    JOIN catalog.knowledge_version v USING(organization_id,knowledge_version_id)
    JOIN catalog.knowledge_item i USING(organization_id,knowledge_item_id)
    JOIN identity.principal p ON p.organization_id=r.organization_id AND p.principal_id=r.reviewer_id
    JOIN identity.organization_membership m ON m.organization_id=p.organization_id AND m.account_id=p.account_id
    JOIN identity.account a ON a.account_id=p.account_id
    JOIN security.workspace_access w ON w.organization_id=i.organization_id AND w.workspace_id=i.owning_workspace_id AND w.principal_id=p.principal_id
  WHERE r.organization_id=security.current_organization() AND r.knowledge_version_id=version AND r.role_id=required_role
    AND r.review_round=v.review_round AND r.review_digest=v.review_digest AND r.reviewer_id<>v.created_by
    AND p.status='ACTIVE' AND m.status='ACTIVE' AND m.left_at IS NULL AND a.status='ACTIVE' AND w.can_review
    AND NOT EXISTS(SELECT FROM catalog.citation c JOIN source.artifact_version av USING(organization_id,artifact_version_id)
      WHERE c.organization_id=r.organization_id AND c.knowledge_version_id=version AND NOT EXISTS(SELECT FROM security.source_acl acl
        WHERE acl.organization_id=c.organization_id AND acl.source_artifact_id=av.source_artifact_id
          AND acl.principal_id=r.reviewer_id AND acl.is_allowed AND acl.valid_until>statement_timestamp()))
$$;

-- One narrow, parameterized command boundary; runtime roles receive no direct write grants.
CREATE FUNCTION catalog.knowledge_command(action text, payload jsonb, event_id uuid) RETURNS uuid
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE tenant uuid:=security.current_organization(); actor uuid; workspace uuid;
  version uuid:=(payload->>'version_id')::uuid; item uuid; r uuid; initial uuid; next_id uuid;
  v catalog.knowledge_version; typ catalog.knowledge_type; edge governance.lifecycle_transition;
  target governance.lifecycle_state; source_row record; idx integer; artifact uuid; role uuid; assignee uuid;
BEGIN
  IF tenant IS NULL THEN RAISE EXCEPTION 'Authenticated context required' USING ERRCODE='42501'; END IF;
  IF action='create' THEN
    workspace:=(payload->>'workspace_id')::uuid; actor:=catalog.require_actor(workspace,'edit');
    r:=(payload->>'configuration_revision_id')::uuid;
    SELECT * INTO typ FROM catalog.knowledge_type WHERE organization_id=tenant AND configuration_revision_id=r AND knowledge_type_id=(payload->>'knowledge_type_id')::uuid AND is_enabled;
    SELECT lifecycle_state_id INTO initial FROM governance.lifecycle_state WHERE organization_id=tenant AND configuration_revision_id=r
      AND lifecycle_workflow_id=typ.lifecycle_workflow_id AND is_initial AND is_enabled AND NOT is_published;
    IF initial IS NULL OR NOT EXISTS(SELECT FROM governance.configuration_activation WHERE organization_id=tenant AND configuration_revision_id=r
      AND effective_from<=statement_timestamp() AND (effective_to IS NULL OR effective_to>statement_timestamp())) THEN
      RAISE EXCEPTION 'Effective configuration with an initial workflow state required' USING ERRCODE='23514'; END IF;
    item:=(payload->>'item_id')::uuid;
    INSERT INTO catalog.knowledge_item VALUES(item,tenant,workspace,payload->>'knowledge_key',NULL,actor,clock_timestamp());
    INSERT INTO catalog.knowledge_version(knowledge_version_id,organization_id,knowledge_item_id,version_number,configuration_revision_id,
      knowledge_type_id,domain_id,authority_level_id,classification_id,lifecycle_state_id,title,summary,content,custom_metadata,created_by)
    VALUES(version,tenant,item,1,r,typ.knowledge_type_id,(payload->>'domain_id')::uuid,typ.default_authority_level_id,typ.default_classification_id,
      initial,payload->>'title',coalesce(payload->>'summary',''),payload->>'content',coalesce(payload->'metadata','{}'),actor);
  ELSE
    SELECT * INTO v FROM catalog.knowledge_version WHERE organization_id=tenant AND knowledge_version_id=version FOR UPDATE;
    IF v.knowledge_version_id IS NULL OR NOT security.can_read_knowledge(v.knowledge_item_id) THEN
      RAISE EXCEPTION 'Knowledge unavailable' USING ERRCODE='42501'; END IF;
    SELECT owning_workspace_id INTO workspace FROM catalog.knowledge_item WHERE organization_id=tenant AND knowledge_item_id=v.knowledge_item_id FOR UPDATE;
    actor:=catalog.require_actor(workspace,CASE WHEN action IN ('review','publish') THEN 'review' ELSE 'edit' END);
    IF action IN ('review','publish') AND NOT pg_has_role(session_user,'kc_human_approver','MEMBER') THEN
      RAISE EXCEPTION 'Separate human approval connection required' USING ERRCODE='42501'; END IF;
    CASE action
    WHEN 'edit' THEN
      IF v.status<>'DRAFT' THEN RAISE EXCEPTION 'Only drafts can be edited' USING ERRCODE='23514'; END IF;
      UPDATE catalog.knowledge_version SET title=coalesce(payload->>'title',title),summary=coalesce(payload->>'summary',summary),
        content=coalesce(payload->>'content',content),custom_metadata=coalesce(payload->'metadata',custom_metadata)
        WHERE organization_id=tenant AND knowledge_version_id=version;
    WHEN 'attach' THEN
      SELECT source_artifact_id INTO artifact FROM source.artifact_version WHERE organization_id=tenant AND artifact_version_id=(payload->>'artifact_version_id')::uuid;
      IF artifact IS NULL OR NOT security.has_source_access(artifact) THEN RAISE EXCEPTION 'Source evidence unavailable' USING ERRCODE='42501'; END IF;
      INSERT INTO catalog.citation VALUES((payload->>'citation_id')::uuid,tenant,version,(payload->>'artifact_version_id')::uuid,payload->>'locator',coalesce(payload->>'evidence_note',''));
    WHEN 'assign' THEN
      role:=(payload->>'role_id')::uuid; assignee:=(payload->>'principal_id')::uuid;
      IF NOT EXISTS(SELECT FROM governance.role g JOIN identity.principal p ON p.organization_id=g.organization_id
        WHERE g.organization_id=tenant AND g.configuration_revision_id=v.configuration_revision_id AND g.role_id=role AND g.is_enabled
          AND p.principal_id=assignee AND p.principal_type='USER' AND p.status='ACTIVE' AND p.principal_type=ANY(g.allowed_principal_types)) THEN
        RAISE EXCEPTION 'Enabled role and active human assignee required' USING ERRCODE='23514'; END IF;
      INSERT INTO governance.knowledge_responsibility VALUES((payload->>'responsibility_id')::uuid,tenant,version,v.configuration_revision_id,role,assignee);
    WHEN 'submit','review','publish','return_to_draft' THEN
      SELECT * INTO edge FROM governance.lifecycle_transition WHERE organization_id=tenant AND configuration_revision_id=v.configuration_revision_id
        AND key=payload->>'transition_key' AND from_state_id=v.lifecycle_state_id AND is_enabled;
      SELECT * INTO target FROM governance.lifecycle_state WHERE organization_id=tenant AND lifecycle_state_id=edge.to_state_id AND is_enabled;
      IF edge.lifecycle_transition_id IS NULL OR target.lifecycle_state_id IS NULL OR edge.conditions<>'{}' THEN
        RAISE EXCEPTION 'Enabled transition with supported conditions required' USING ERRCODE='23514'; END IF;
      IF action='return_to_draft' THEN
        IF v.status NOT IN ('IN_REVIEW','APPROVED') OR NOT target.is_initial OR edge.minimum_approvals<>0 OR target.is_published THEN
          RAISE EXCEPTION 'Return-to-draft transition required' USING ERRCODE='23514'; END IF;
        UPDATE catalog.knowledge_version SET status='DRAFT',lifecycle_state_id=target.lifecycle_state_id,review_round=review_round+1,review_digest=NULL
          WHERE organization_id=tenant AND knowledge_version_id=version;
      ELSE
        PERFORM catalog.validate_knowledge(version);
        IF action='submit' THEN
          IF v.status<>'DRAFT' OR target.is_published OR target.is_initial OR edge.minimum_approvals<>0 THEN
            RAISE EXCEPTION 'Draft-to-review transition required' USING ERRCODE='23514'; END IF;
          UPDATE catalog.knowledge_version SET status='IN_REVIEW',lifecycle_state_id=target.lifecycle_state_id,review_digest=catalog.version_digest(version)
            WHERE organization_id=tenant AND knowledge_version_id=version;
        ELSE
          IF v.review_digest IS DISTINCT FROM catalog.version_digest(version) THEN RAISE EXCEPTION 'Reviewed snapshot changed' USING ERRCODE='23514'; END IF;
          IF NOT edge.requires_human_approval OR edge.approval_role_id IS NULL OR edge.minimum_approvals<1 THEN
            RAISE EXCEPTION 'Human approval transition required' USING ERRCODE='23514'; END IF;
          IF action='review' THEN
            IF v.status<>'IN_REVIEW' OR target.is_published OR actor=v.created_by OR btrim(coalesce(payload->>'note',''))='' THEN
              RAISE EXCEPTION 'Independent review with a note required' USING ERRCODE='23514'; END IF;
            IF NOT EXISTS(SELECT FROM governance.knowledge_responsibility WHERE organization_id=tenant AND knowledge_version_id=version AND role_id=edge.approval_role_id AND principal_id=actor) THEN
              RAISE EXCEPTION 'Assigned approval responsibility required' USING ERRCODE='42501'; END IF;
            INSERT INTO governance.knowledge_review VALUES((payload->>'review_id')::uuid,tenant,version,v.review_round,actor,edge.approval_role_id,
              v.configuration_revision_id,v.review_digest,payload->>'note',clock_timestamp());
            IF catalog.approval_count(version,edge.approval_role_id)>=edge.minimum_approvals THEN
              UPDATE catalog.knowledge_version SET status='APPROVED',lifecycle_state_id=target.lifecycle_state_id WHERE organization_id=tenant AND knowledge_version_id=version;
            END IF;
          ELSE
            IF v.status<>'APPROVED' OR NOT target.is_published OR catalog.approval_count(version,edge.approval_role_id)<edge.minimum_approvals THEN
              RAISE EXCEPTION 'Valid human approvals required before publication' USING ERRCODE='23514'; END IF;
            UPDATE catalog.knowledge_version SET status='PUBLISHED',lifecycle_state_id=target.lifecycle_state_id,published_by=actor,published_at=clock_timestamp()
              WHERE organization_id=tenant AND knowledge_version_id=version;
            UPDATE catalog.knowledge_item SET current_version_id=version WHERE organization_id=tenant AND knowledge_item_id=v.knowledge_item_id;
          END IF;
        END IF;
      END IF;
    WHEN 'revise' THEN
      IF v.status<>'PUBLISHED' OR NOT EXISTS(SELECT FROM catalog.knowledge_item WHERE organization_id=tenant AND knowledge_item_id=v.knowledge_item_id AND current_version_id=version) THEN
        RAISE EXCEPTION 'Only the current published version can be revised' USING ERRCODE='23514'; END IF;
      SELECT s.lifecycle_state_id INTO initial FROM governance.lifecycle_state s JOIN catalog.knowledge_type t USING(organization_id,configuration_revision_id,lifecycle_workflow_id)
        WHERE t.organization_id=tenant AND t.knowledge_type_id=v.knowledge_type_id AND s.is_initial AND s.is_enabled;
      next_id:=(payload->>'new_version_id')::uuid;
      INSERT INTO catalog.knowledge_version(knowledge_version_id,organization_id,knowledge_item_id,version_number,configuration_revision_id,
        knowledge_type_id,domain_id,authority_level_id,classification_id,lifecycle_state_id,title,summary,content,custom_metadata,created_by)
      VALUES(next_id,tenant,v.knowledge_item_id,v.version_number+1,v.configuration_revision_id,v.knowledge_type_id,v.domain_id,v.authority_level_id,v.classification_id,
        initial,v.title,v.summary,v.content,v.custom_metadata,actor);
      idx:=0;
      FOR source_row IN SELECT * FROM catalog.citation WHERE organization_id=tenant AND knowledge_version_id=version ORDER BY citation_id LOOP
        INSERT INTO catalog.citation VALUES((payload->'citation_ids'->>idx)::uuid,tenant,next_id,source_row.artifact_version_id,source_row.locator,source_row.evidence_note); idx:=idx+1;
      END LOOP;
      idx:=0;
      FOR source_row IN SELECT * FROM governance.knowledge_responsibility WHERE organization_id=tenant AND knowledge_version_id=version ORDER BY knowledge_responsibility_id LOOP
        INSERT INTO governance.knowledge_responsibility VALUES((payload->'responsibility_ids'->>idx)::uuid,tenant,next_id,v.configuration_revision_id,source_row.role_id,source_row.principal_id); idx:=idx+1;
      END LOOP;
      version:=next_id;
    ELSE RAISE EXCEPTION 'Unknown knowledge action' USING ERRCODE='22023';
    END CASE;
  END IF;
  PERFORM catalog.log_event(event_id,actor,'KNOWLEDGE_' || upper(action),version);
  RETURN version;
END $$;
GRANT EXECUTE ON FUNCTION catalog.knowledge_command(text,jsonb,uuid) TO kc_application,kc_human_approver;
