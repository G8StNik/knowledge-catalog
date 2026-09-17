-- KC-005: publication history and its evidence are separate immutable records.
CREATE TABLE security.workspace_access (
  organization_id uuid NOT NULL, workspace_id uuid NOT NULL, principal_id uuid NOT NULL,
  can_edit boolean NOT NULL DEFAULT false, can_review boolean NOT NULL DEFAULT false,
  PRIMARY KEY (organization_id,workspace_id,principal_id),
  FOREIGN KEY (organization_id,workspace_id) REFERENCES core.workspace(organization_id,workspace_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,principal_id) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT
);
CREATE TABLE source.knowledge_source (
  knowledge_source_id uuid PRIMARY KEY, organization_id uuid NOT NULL REFERENCES core.organization ON DELETE RESTRICT,
  source_key text NOT NULL, display_name text NOT NULL, provider_kind text NOT NULL,
  UNIQUE (organization_id,knowledge_source_id), UNIQUE (organization_id,source_key)
);
CREATE TABLE source.source_artifact (
  source_artifact_id uuid PRIMARY KEY, organization_id uuid NOT NULL, knowledge_source_id uuid NOT NULL,
  external_key text NOT NULL, source_uri text NOT NULL,
  UNIQUE (organization_id,source_artifact_id), UNIQUE (organization_id,knowledge_source_id,external_key),
  FOREIGN KEY (organization_id,knowledge_source_id) REFERENCES source.knowledge_source(organization_id,knowledge_source_id) ON DELETE RESTRICT
);
CREATE TABLE source.artifact_version (
  artifact_version_id uuid PRIMARY KEY, organization_id uuid NOT NULL, source_artifact_id uuid NOT NULL,
  version_key text NOT NULL, content text NOT NULL,
  content_hash text GENERATED ALWAYS AS (encode(public.digest(content,'sha256'),'hex')) STORED,
  captured_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (organization_id,artifact_version_id), UNIQUE (organization_id,source_artifact_id,version_key),
  FOREIGN KEY (organization_id,source_artifact_id) REFERENCES source.source_artifact(organization_id,source_artifact_id) ON DELETE RESTRICT
);
CREATE TABLE security.source_acl (
  organization_id uuid NOT NULL, source_artifact_id uuid NOT NULL, principal_id uuid NOT NULL,
  is_allowed boolean NOT NULL DEFAULT false, valid_until timestamptz NOT NULL,
  PRIMARY KEY (organization_id,source_artifact_id,principal_id),
  FOREIGN KEY (organization_id,source_artifact_id) REFERENCES source.source_artifact(organization_id,source_artifact_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,principal_id) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT
);
CREATE TABLE catalog.knowledge_item (
  knowledge_item_id uuid PRIMARY KEY, organization_id uuid NOT NULL, owning_workspace_id uuid NOT NULL,
  knowledge_key text NOT NULL, current_version_id uuid,
  created_by uuid NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (organization_id,knowledge_item_id), UNIQUE (organization_id,knowledge_key),
  FOREIGN KEY (organization_id,owning_workspace_id) REFERENCES core.workspace(organization_id,workspace_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,created_by) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT
);
CREATE TABLE catalog.knowledge_version (
  knowledge_version_id uuid PRIMARY KEY, organization_id uuid NOT NULL, knowledge_item_id uuid NOT NULL,
  version_number integer NOT NULL CHECK (version_number>0), configuration_revision_id uuid NOT NULL,
  knowledge_type_id uuid NOT NULL, domain_id uuid NOT NULL, authority_level_id uuid NOT NULL, classification_id uuid NOT NULL,
  lifecycle_state_id uuid NOT NULL, title text NOT NULL CHECK (btrim(title)<>''), summary text NOT NULL DEFAULT '', content text NOT NULL,
  custom_metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(custom_metadata)='object'),
  status text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','IN_REVIEW','APPROVED','PUBLISHED')),
  review_round integer NOT NULL DEFAULT 1, review_digest text,
  created_by uuid NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  published_by uuid, published_at timestamptz,
  UNIQUE (organization_id,knowledge_version_id), UNIQUE (organization_id,knowledge_item_id,knowledge_version_id),
  UNIQUE (organization_id,knowledge_item_id,version_number),
  FOREIGN KEY (organization_id,knowledge_item_id) REFERENCES catalog.knowledge_item(organization_id,knowledge_item_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,knowledge_type_id) REFERENCES catalog.knowledge_type(organization_id,configuration_revision_id,knowledge_type_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,domain_id) REFERENCES catalog.domain(organization_id,configuration_revision_id,domain_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,authority_level_id) REFERENCES governance.authority_level(organization_id,configuration_revision_id,authority_level_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,classification_id) REFERENCES governance.classification(organization_id,configuration_revision_id,classification_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,lifecycle_state_id) REFERENCES governance.lifecycle_state(organization_id,configuration_revision_id,lifecycle_state_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,created_by) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,published_by) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT,
  CHECK ((status='PUBLISHED')=(published_at IS NOT NULL AND published_by IS NOT NULL))
);
CREATE UNIQUE INDEX one_open_knowledge_version ON catalog.knowledge_version(organization_id,knowledge_item_id) WHERE status<>'PUBLISHED';
ALTER TABLE catalog.knowledge_item ADD FOREIGN KEY (organization_id,knowledge_item_id,current_version_id)
  REFERENCES catalog.knowledge_version(organization_id,knowledge_item_id,knowledge_version_id) ON DELETE RESTRICT;
CREATE TABLE catalog.citation (
  citation_id uuid PRIMARY KEY, organization_id uuid NOT NULL, knowledge_version_id uuid NOT NULL, artifact_version_id uuid NOT NULL,
  locator text NOT NULL CHECK (btrim(locator)<>''), evidence_note text NOT NULL DEFAULT '',
  UNIQUE (organization_id,knowledge_version_id,artifact_version_id,locator),
  FOREIGN KEY (organization_id,knowledge_version_id) REFERENCES catalog.knowledge_version(organization_id,knowledge_version_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,artifact_version_id) REFERENCES source.artifact_version(organization_id,artifact_version_id) ON DELETE RESTRICT
);
CREATE TABLE governance.knowledge_responsibility (
  knowledge_responsibility_id uuid PRIMARY KEY, organization_id uuid NOT NULL, knowledge_version_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL, role_id uuid NOT NULL, principal_id uuid NOT NULL,
  UNIQUE (organization_id,knowledge_version_id,role_id,principal_id),
  FOREIGN KEY (organization_id,knowledge_version_id) REFERENCES catalog.knowledge_version(organization_id,knowledge_version_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,role_id) REFERENCES governance.role(organization_id,configuration_revision_id,role_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,principal_id) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT
);
CREATE TABLE governance.knowledge_review (
  knowledge_review_id uuid PRIMARY KEY, organization_id uuid NOT NULL, knowledge_version_id uuid NOT NULL,
  review_round integer NOT NULL, reviewer_id uuid NOT NULL, role_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL, review_digest text NOT NULL, note text NOT NULL,
  reviewed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (organization_id,knowledge_version_id,review_round,reviewer_id,role_id),
  FOREIGN KEY (organization_id,knowledge_version_id) REFERENCES catalog.knowledge_version(organization_id,knowledge_version_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,role_id) REFERENCES governance.role(organization_id,configuration_revision_id,role_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,reviewer_id) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT
);

CREATE FUNCTION security.has_workspace_access(workspace uuid, permission text DEFAULT 'read') RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
  SELECT EXISTS(SELECT FROM security.workspace_access a JOIN core.workspace w USING(organization_id,workspace_id)
    WHERE a.organization_id=security.current_organization() AND a.workspace_id=workspace
    AND a.principal_id=security.current_principal() AND w.status='ACTIVE' AND w.deleted_at IS NULL
    AND CASE permission WHEN 'read' THEN true WHEN 'edit' THEN a.can_edit WHEN 'review' THEN a.can_review ELSE false END)
$$;
CREATE FUNCTION security.has_source_access(artifact uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
  SELECT EXISTS(SELECT FROM security.source_acl WHERE organization_id=security.current_organization()
    AND source_artifact_id=artifact AND principal_id=security.current_principal() AND is_allowed AND valid_until>statement_timestamp())
$$;
CREATE FUNCTION security.can_read_knowledge(item uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
  SELECT EXISTS(SELECT FROM catalog.knowledge_item i WHERE i.organization_id=security.current_organization()
    AND i.knowledge_item_id=item AND security.has_workspace_access(i.owning_workspace_id)
    AND NOT EXISTS(SELECT FROM catalog.knowledge_version v JOIN catalog.citation c USING(organization_id,knowledge_version_id)
      JOIN source.artifact_version a USING(organization_id,artifact_version_id)
      WHERE v.organization_id=i.organization_id AND v.knowledge_item_id=i.knowledge_item_id AND NOT security.has_source_access(a.source_artifact_id)))
$$;
CREATE FUNCTION security.can_read_version(version uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
  SELECT EXISTS(SELECT FROM catalog.knowledge_version WHERE organization_id=security.current_organization()
    AND knowledge_version_id=version AND security.can_read_knowledge(knowledge_item_id))
$$;
CREATE FUNCTION catalog.require_actor(workspace uuid, permission text) RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid;
BEGIN
  SELECT principal_id INTO actor FROM security.context() WHERE principal_type='USER';
  IF actor IS NULL OR NOT security.has_workspace_access(workspace,permission) THEN
    RAISE EXCEPTION 'Authorized human workspace access required' USING ERRCODE='42501'; END IF;
  RETURN actor;
END $$;
CREATE FUNCTION catalog.log_event(event uuid, actor uuid, action text, entity uuid) RETURNS void LANGUAGE sql SET search_path=pg_catalog AS $$
  INSERT INTO audit.event(audit_event_id,organization_id,actor_principal_id,action,entity_type,entity_id)
  VALUES(event,security.current_organization(),actor,action,'knowledge_version',entity)
$$;
CREATE FUNCTION catalog.guard_version() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP='DELETE' OR OLD.status='PUBLISHED' THEN RAISE EXCEPTION 'Published history is immutable' USING ERRCODE='23514'; END IF;
  IF (NEW.organization_id,NEW.knowledge_item_id,NEW.knowledge_version_id,NEW.version_number,NEW.configuration_revision_id,NEW.created_by)
    IS DISTINCT FROM (OLD.organization_id,OLD.knowledge_item_id,OLD.knowledge_version_id,OLD.version_number,OLD.configuration_revision_id,OLD.created_by) THEN
    RAISE EXCEPTION 'Version identity is immutable' USING ERRCODE='23514'; END IF;
  IF OLD.status<>'DRAFT' AND (NEW.title,NEW.summary,NEW.content,NEW.custom_metadata,NEW.knowledge_type_id,NEW.domain_id,NEW.authority_level_id,NEW.classification_id)
    IS DISTINCT FROM (OLD.title,OLD.summary,OLD.content,OLD.custom_metadata,OLD.knowledge_type_id,OLD.domain_id,OLD.authority_level_id,OLD.classification_id) THEN
    RAISE EXCEPTION 'Reviewed content is frozen' USING ERRCODE='23514'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER immutable_version BEFORE UPDATE OR DELETE ON catalog.knowledge_version FOR EACH ROW EXECUTE FUNCTION catalog.guard_version();
CREATE FUNCTION catalog.guard_version_child() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE r record; tenant uuid; version uuid;
BEGIN
  tenant:=coalesce(NEW.organization_id,OLD.organization_id); version:=coalesce(NEW.knowledge_version_id,OLD.knowledge_version_id);
  SELECT * INTO r FROM catalog.knowledge_version WHERE organization_id=tenant AND knowledge_version_id=version FOR UPDATE;
  IF r.status IS DISTINCT FROM 'DRAFT' THEN RAISE EXCEPTION 'Evidence and responsibilities are frozen during review and after publication' USING ERRCODE='23514'; END IF;
  IF TG_OP='UPDATE' AND (NEW.organization_id,NEW.knowledge_version_id) IS DISTINCT FROM (OLD.organization_id,OLD.knowledge_version_id) THEN
    RAISE EXCEPTION 'Cannot move version children' USING ERRCODE='23514'; END IF;
  IF TG_TABLE_NAME='knowledge_responsibility' AND TG_OP<>'DELETE' THEN
    IF NEW.configuration_revision_id<>r.configuration_revision_id THEN
      RAISE EXCEPTION 'Responsibility configuration mismatch' USING ERRCODE='23514'; END IF;
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; END IF; RETURN NEW;
END $$;
CREATE TRIGGER frozen_citation BEFORE INSERT OR UPDATE OR DELETE ON catalog.citation FOR EACH ROW EXECUTE FUNCTION catalog.guard_version_child();
CREATE TRIGGER frozen_responsibility BEFORE INSERT OR UPDATE OR DELETE ON governance.knowledge_responsibility FOR EACH ROW EXECUTE FUNCTION catalog.guard_version_child();
CREATE TRIGGER immutable_source BEFORE UPDATE OR DELETE ON source.artifact_version FOR EACH ROW EXECUTE FUNCTION audit.reject_mutation();
CREATE TRIGGER immutable_review BEFORE UPDATE OR DELETE ON governance.knowledge_review FOR EACH ROW EXECUTE FUNCTION audit.reject_mutation();

-- Source ingestion and permissions are trusted provisioning operations, never editor grants.
DO $$ DECLARE t text; BEGIN
  FOREACH t IN ARRAY ARRAY['security.workspace_access','security.source_acl','source.knowledge_source','source.source_artifact','source.artifact_version'] LOOP
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY provisioner ON %s TO kc_platform_admin USING(true) WITH CHECK(true)',t);
    EXECUTE format('GRANT SELECT,INSERT ON %s TO kc_platform_admin',t);
  END LOOP;
END $$;
GRANT UPDATE,DELETE ON security.workspace_access,security.source_acl TO kc_platform_admin;
GRANT USAGE ON SCHEMA source TO kc_platform_admin,kc_application,kc_human_approver,kc_readonly;
CREATE POLICY own_workspace_access ON security.workspace_access FOR SELECT TO kc_application,kc_human_approver,kc_readonly
  USING(organization_id=security.current_organization() AND principal_id=security.current_principal());
CREATE POLICY own_source_acl ON security.source_acl FOR SELECT TO kc_application,kc_human_approver,kc_readonly
  USING(organization_id=security.current_organization() AND principal_id=security.current_principal());
CREATE POLICY visible_source ON source.knowledge_source FOR SELECT TO kc_application,kc_human_approver,kc_readonly
  USING(organization_id=security.current_organization() AND EXISTS(SELECT FROM source.source_artifact a WHERE a.organization_id=knowledge_source.organization_id AND a.knowledge_source_id=knowledge_source.knowledge_source_id));
CREATE POLICY visible_artifact ON source.source_artifact FOR SELECT TO kc_application,kc_human_approver,kc_readonly
  USING(organization_id=security.current_organization() AND security.has_source_access(source_artifact_id));
CREATE POLICY visible_artifact_version ON source.artifact_version FOR SELECT TO kc_application,kc_human_approver,kc_readonly
  USING(organization_id=security.current_organization() AND security.has_source_access(source_artifact_id));
GRANT SELECT ON security.workspace_access,security.source_acl,source.knowledge_source,source.source_artifact,source.artifact_version TO kc_application,kc_human_approver,kc_readonly;
DO $$ DECLARE t text; predicate text; BEGIN
  FOREACH t IN ARRAY ARRAY['catalog.knowledge_item','catalog.knowledge_version','catalog.citation','governance.knowledge_responsibility','governance.knowledge_review'] LOOP
    predicate:=CASE WHEN t='catalog.knowledge_item' THEN 'security.can_read_knowledge(knowledge_item_id)' ELSE 'security.can_read_version(knowledge_version_id)' END;
    EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY',t);
    EXECUTE format('ALTER TABLE %s FORCE ROW LEVEL SECURITY',t);
    EXECUTE format('CREATE POLICY authorized_read ON %s FOR SELECT TO kc_application,kc_human_approver,kc_readonly USING(organization_id=security.current_organization() AND %s)',t,predicate);
    EXECUTE format('GRANT SELECT ON %s TO kc_application,kc_human_approver,kc_readonly',t);
  END LOOP;
END $$;
GRANT EXECUTE ON FUNCTION security.has_workspace_access(uuid,text),security.has_source_access(uuid),security.can_read_knowledge(uuid),security.can_read_version(uuid)
  TO kc_application,kc_human_approver,kc_readonly;
