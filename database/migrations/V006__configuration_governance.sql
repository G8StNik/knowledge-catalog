CREATE FUNCTION governance.guard_draft_entity() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE tenant uuid; revision uuid; state text;
BEGIN
  PERFORM security.require_configuration_approver();
  IF TG_OP='DELETE' THEN tenant:=OLD.organization_id; revision:=OLD.configuration_revision_id;
  ELSE tenant:=NEW.organization_id; revision:=NEW.configuration_revision_id; END IF;
  IF tenant IS DISTINCT FROM security.current_organization() THEN
    RAISE EXCEPTION 'Wrong tenant' USING ERRCODE='42501';
  END IF;
  IF TG_OP='UPDATE' AND (NEW.organization_id,NEW.configuration_revision_id)
    IS DISTINCT FROM (OLD.organization_id,OLD.configuration_revision_id) THEN
    RAISE EXCEPTION 'Configuration cannot move across revisions' USING ERRCODE='23514';
  END IF;
  SELECT status INTO state FROM governance.configuration_revision
    WHERE organization_id=tenant AND configuration_revision_id=revision FOR UPDATE;
  IF state IS DISTINCT FROM 'DRAFT' THEN
    RAISE EXCEPTION 'Approved configuration is immutable; create a new revision' USING ERRCODE='23514';
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF;
  RETURN NEW;
END $$;

CREATE FUNCTION governance.guard_revision() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP='DELETE' OR OLD.status='APPROVED' THEN
    RAISE EXCEPTION 'Approved revisions cannot be changed or deleted' USING ERRCODE='23514';
  END IF;
  IF (NEW.organization_id,NEW.configuration_revision_id,NEW.package_key,NEW.version,NEW.created_by,NEW.source_proposal_id)
     IS DISTINCT FROM (OLD.organization_id,OLD.configuration_revision_id,OLD.package_key,OLD.version,OLD.created_by,OLD.source_proposal_id) THEN
    RAISE EXCEPTION 'Revision identity and provenance are immutable' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER revision_immutable BEFORE UPDATE OR DELETE ON governance.configuration_revision FOR EACH ROW EXECUTE FUNCTION governance.guard_revision();

CREATE FUNCTION governance.check_hierarchy() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE found_cycle boolean;
BEGIN
  IF TG_TABLE_NAME='domain' THEN
    WITH RECURSIVE ancestors(id) AS (
      SELECT NEW.parent_domain_id UNION
      SELECT d.parent_domain_id FROM catalog.domain d JOIN ancestors a ON d.domain_id=a.id
      WHERE d.organization_id=NEW.organization_id AND d.configuration_revision_id=NEW.configuration_revision_id
    ) SELECT EXISTS(SELECT FROM ancestors WHERE id=NEW.domain_id) INTO found_cycle;
  ELSE
    WITH RECURSIVE ancestors(id) AS (
      SELECT NEW.parent_term_id UNION
      SELECT t.parent_term_id FROM catalog.taxonomy_term t JOIN ancestors a ON t.taxonomy_term_id=a.id
      WHERE t.organization_id=NEW.organization_id AND t.configuration_revision_id=NEW.configuration_revision_id
    ) SELECT EXISTS(SELECT FROM ancestors WHERE id=NEW.taxonomy_term_id) INTO found_cycle;
  END IF;
  IF found_cycle THEN RAISE EXCEPTION 'Hierarchy cycle' USING ERRCODE='23514'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER b_hierarchy BEFORE INSERT OR UPDATE ON catalog.domain FOR EACH ROW EXECUTE FUNCTION governance.check_hierarchy();
CREATE TRIGGER b_hierarchy BEFORE INSERT OR UPDATE ON catalog.taxonomy_term FOR EACH ROW EXECUTE FUNCTION governance.check_hierarchy();

CREATE FUNCTION audit.reject_mutation() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'Append-only audit record' USING ERRCODE='23514'; END $$;
CREATE TRIGGER append_only BEFORE UPDATE OR DELETE ON audit.event FOR EACH ROW EXECUTE FUNCTION audit.reject_mutation();

CREATE FUNCTION governance.propose_configuration(proposal_id uuid, event_id uuid, package jsonb,
  rationale text, confidence numeric, evidence jsonb, generator_metadata jsonb) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid; tenant uuid; kind text;
BEGIN
  SELECT c.principal_id,c.organization_id,c.principal_type INTO actor,tenant,kind FROM security.context() c;
  IF actor IS NULL THEN RAISE EXCEPTION 'Authenticated context required' USING ERRCODE='42501'; END IF;
  INSERT INTO governance.configuration_proposal(configuration_proposal_id,organization_id,generated_by,origin,
    rationale,confidence,evidence,proposed_package,generator_metadata)
    VALUES(proposal_id,tenant,actor,CASE WHEN kind='USER' THEN 'HUMAN' ELSE kind END,
      rationale,confidence,evidence,package,generator_metadata);
  INSERT INTO audit.event(audit_event_id,organization_id,actor_principal_id,action,entity_type,entity_id)
    VALUES(event_id,tenant,actor,'CONFIGURATION_PROPOSED','configuration_proposal',proposal_id);
END $$;

CREATE FUNCTION governance.create_revision(revision_id uuid, package text, version_number integer,
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
END $$;

CREATE FUNCTION governance.snapshot_revision(tenant uuid, revision uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path=pg_catalog AS $$
DECLARE t text; rows jsonb; result jsonb := '{}'::jsonb;
BEGIN
  FOREACH t IN ARRAY ARRAY['catalog.domain','catalog.taxonomy','catalog.taxonomy_term','catalog.term_alias',
    'catalog.knowledge_type','catalog.custom_field_definition','catalog.custom_field_choice','catalog.knowledge_type_field',
    'catalog.relationship_type','catalog.relationship_type_restriction','catalog.knowledge_template','catalog.template_responsibility','catalog.template_field',
    'governance.authority_level','governance.classification','governance.role','governance.lifecycle_workflow',
    'governance.lifecycle_state','governance.lifecycle_transition','governance.responsibility_requirement'] LOOP
    EXECUTE format('SELECT coalesce(jsonb_agg(to_jsonb(x) ORDER BY key),''[]''::jsonb) FROM %s x WHERE organization_id=$1 AND configuration_revision_id=$2',t)
      INTO rows USING tenant,revision;
    result:=result || jsonb_build_object(t,rows);
  END LOOP;
  RETURN result;
END $$;

CREATE FUNCTION governance.validate_revision(tenant uuid, revision uuid) RETURNS void
LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  IF EXISTS(SELECT FROM governance.lifecycle_workflow w WHERE w.organization_id=tenant AND w.configuration_revision_id=revision
    AND w.is_enabled AND NOT EXISTS(SELECT FROM governance.lifecycle_state s WHERE s.organization_id=tenant
      AND s.configuration_revision_id=revision AND s.lifecycle_workflow_id=w.lifecycle_workflow_id AND s.is_initial AND s.is_enabled)) THEN
    RAISE EXCEPTION 'Enabled workflows require an enabled initial state' USING ERRCODE='23514';
  END IF;
  IF EXISTS(SELECT FROM governance.lifecycle_transition t JOIN governance.lifecycle_state s ON
    (s.organization_id,s.configuration_revision_id,s.lifecycle_state_id)=(t.organization_id,t.configuration_revision_id,t.to_state_id)
    WHERE t.organization_id=tenant AND t.configuration_revision_id=revision AND s.is_published
      AND t.is_enabled AND NOT t.requires_human_approval) THEN
    RAISE EXCEPTION 'Publication transitions require human approval' USING ERRCODE='23514';
  END IF;
  IF EXISTS(SELECT FROM catalog.custom_field_definition f WHERE f.organization_id=tenant AND f.configuration_revision_id=revision
      AND f.data_type IN ('CHOICE','MULTICHOICE') AND NOT EXISTS(SELECT FROM catalog.custom_field_choice c
      WHERE (c.organization_id,c.configuration_revision_id,c.custom_field_definition_id)=(f.organization_id,f.configuration_revision_id,f.custom_field_definition_id))) THEN
    RAISE EXCEPTION 'Choice fields require choices' USING ERRCODE='23514';
  END IF;
END $$;

CREATE FUNCTION governance.approve_and_activate(revision uuid, activation_id uuid, event_id uuid,
  starts timestamptz, ends timestamptz DEFAULT NULL, note text DEFAULT '') RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid; tenant uuid; r governance.configuration_revision; snapshot jsonb;
BEGIN
  actor:=security.require_configuration_approver(); tenant:=security.current_organization();
  SELECT * INTO r FROM governance.configuration_revision WHERE organization_id=tenant AND configuration_revision_id=revision FOR UPDATE;
  IF r.status IS DISTINCT FROM 'DRAFT' THEN RAISE EXCEPTION 'Draft revision required' USING ERRCODE='23514'; END IF;
  IF starts IS NULL OR starts<statement_timestamp() THEN RAISE EXCEPTION 'Activation cannot be backdated' USING ERRCODE='23514'; END IF;
  PERFORM governance.validate_revision(tenant,revision);
  snapshot:=governance.snapshot_revision(tenant,revision);
  IF r.source_proposal_id IS NOT NULL THEN
    UPDATE governance.configuration_proposal SET status='APPROVED',reviewed_by=actor,reviewed_at=clock_timestamp(),review_note=note
    WHERE organization_id=tenant AND configuration_proposal_id=r.source_proposal_id AND status='PENDING';
    IF NOT FOUND THEN RAISE EXCEPTION 'Proposal is no longer pending' USING ERRCODE='23514'; END IF;
  END IF;
  UPDATE governance.configuration_revision SET status='APPROVED',approved_by=actor,approved_at=clock_timestamp(),
    approved_digest=encode(public.digest(snapshot::text,'sha256'),'hex') WHERE configuration_revision_id=revision AND organization_id=tenant;
  INSERT INTO governance.configuration_activation VALUES(activation_id,tenant,revision,r.package_key,starts,ends,actor,clock_timestamp());
  INSERT INTO audit.event(audit_event_id,organization_id,actor_principal_id,action,entity_type,entity_id,after_state,metadata)
    VALUES(event_id,tenant,actor,'CONFIGURATION_APPROVED_AND_SCHEDULED','configuration_revision',revision,snapshot,
      jsonb_build_object('note',note,'effective_from',starts,'effective_to',ends,'source_proposal_id',r.source_proposal_id));
END $$;

CREATE FUNCTION governance.reject_proposal(proposal uuid, event_id uuid, note text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid; tenant uuid;
BEGIN
  actor:=security.require_configuration_approver(); tenant:=security.current_organization();
  UPDATE governance.configuration_proposal SET status='REJECTED',reviewed_by=actor,reviewed_at=clock_timestamp(),review_note=note
    WHERE organization_id=tenant AND configuration_proposal_id=proposal AND status='PENDING';
  IF NOT FOUND THEN RAISE EXCEPTION 'Pending proposal required' USING ERRCODE='23514'; END IF;
  INSERT INTO audit.event(audit_event_id,organization_id,actor_principal_id,action,entity_type,entity_id,metadata)
    VALUES(event_id,tenant,actor,'CONFIGURATION_PROPOSAL_REJECTED','configuration_proposal',proposal,jsonb_build_object('note',note));
END $$;

CREATE FUNCTION governance.deactivate_configuration(activation uuid,event_id uuid,ends timestamptz,note text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid; tenant uuid; old_state jsonb;
BEGIN
  actor:=security.require_configuration_approver(); tenant:=security.current_organization();
  SELECT to_jsonb(a) INTO old_state FROM governance.configuration_activation a
    WHERE organization_id=tenant AND configuration_activation_id=activation FOR UPDATE;
  IF old_state IS NULL OR ends IS NULL OR ends<statement_timestamp() THEN
    RAISE EXCEPTION 'Existing activation and nonhistorical end required' USING ERRCODE='23514';
  END IF;
  UPDATE governance.configuration_activation SET effective_to=ends
    WHERE organization_id=tenant AND configuration_activation_id=activation
      AND ends>effective_from AND (effective_to IS NULL OR ends<effective_to);
  IF NOT FOUND THEN RAISE EXCEPTION 'Deactivation may only shorten a future end' USING ERRCODE='23514'; END IF;
  INSERT INTO audit.event(audit_event_id,organization_id,actor_principal_id,action,entity_type,entity_id,before_state,metadata)
    VALUES(event_id,tenant,actor,'CONFIGURATION_DEACTIVATED','configuration_activation',activation,old_state,jsonb_build_object('note',note,'effective_to',ends));
END $$;
