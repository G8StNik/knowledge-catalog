CREATE FUNCTION audit.capture_configuration_change() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE event_id uuid; actor uuid; tenant uuid; entity uuid; previous jsonb; next_value jsonb;
BEGIN
  actor:=security.require_configuration_approver(); tenant:=security.current_organization();
  event_id:=nullif(current_setting('kc.change_event_id',true),'')::uuid;
  IF event_id IS NULL THEN RAISE EXCEPTION 'Application-generated change event ID required' USING ERRCODE='23514'; END IF;
  IF TG_OP<>'INSERT' THEN previous:=to_jsonb(OLD); END IF;
  IF TG_OP<>'DELETE' THEN next_value:=to_jsonb(NEW); END IF;
  entity:=(coalesce(next_value,previous)->>(TG_TABLE_NAME || '_id'))::uuid;
  INSERT INTO audit.event(audit_event_id,organization_id,actor_principal_id,action,entity_type,entity_id,before_state,after_state)
    VALUES(event_id,tenant,actor,'CONFIGURATION_DRAFT_' || TG_OP,TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,entity,previous,next_value);
  -- Consume once: a new application ID is required for the next row mutation.
  PERFORM set_config('kc.change_event_id','',true);
  RETURN NULL;
END $$;

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['catalog.domain','catalog.taxonomy','catalog.taxonomy_term','catalog.term_alias',
    'catalog.knowledge_type','catalog.custom_field_definition','catalog.custom_field_choice','catalog.knowledge_type_field',
    'catalog.relationship_type','catalog.relationship_type_restriction','catalog.knowledge_template','catalog.template_responsibility','catalog.template_field',
    'governance.authority_level','governance.classification','governance.role','governance.lifecycle_workflow',
    'governance.lifecycle_state','governance.lifecycle_transition','governance.responsibility_requirement'] LOOP
    EXECUTE format('CREATE TRIGGER z_draft_audit AFTER INSERT OR UPDATE OR DELETE ON %s FOR EACH ROW EXECUTE FUNCTION audit.capture_configuration_change()',t);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION governance.create_revision(revision_id uuid, package text, version_number integer,
  description text, proposal_id uuid DEFAULT NULL) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid; tenant uuid;
BEGIN
  actor:=security.require_configuration_approver(); tenant:=security.current_organization();
  IF proposal_id IS NOT NULL AND NOT EXISTS(SELECT FROM governance.configuration_proposal
    WHERE organization_id=tenant AND configuration_proposal_id=proposal_id AND status='PENDING') THEN
    RAISE EXCEPTION 'Proposal must be pending in this tenant' USING ERRCODE='23514';
  END IF;
  INSERT INTO governance.configuration_revision(configuration_revision_id,organization_id,package_key,version,
    description,source_proposal_id,created_by) VALUES(revision_id,tenant,package,version_number,description,proposal_id,actor);
  -- Revision ID is application-generated and also identifies its creation event.
  INSERT INTO audit.event(audit_event_id,organization_id,actor_principal_id,action,entity_type,entity_id,metadata)
    VALUES(revision_id,tenant,actor,'CONFIGURATION_REVISION_CREATED','configuration_revision',revision_id,
      jsonb_build_object('package_key',package,'version',version_number,'source_proposal_id',proposal_id));
END $$;
