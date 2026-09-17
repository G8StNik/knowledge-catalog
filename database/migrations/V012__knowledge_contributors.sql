-- A reviewer must be independent of every content contributor, not only the creator.
CREATE TABLE catalog.knowledge_contributor (
  organization_id uuid NOT NULL, knowledge_version_id uuid NOT NULL, principal_id uuid NOT NULL,
  PRIMARY KEY (organization_id,knowledge_version_id,principal_id),
  FOREIGN KEY (organization_id,knowledge_version_id) REFERENCES catalog.knowledge_version(organization_id,knowledge_version_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,principal_id) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT
);
INSERT INTO catalog.knowledge_contributor SELECT organization_id,knowledge_version_id,created_by FROM catalog.knowledge_version;
ALTER TABLE catalog.knowledge_contributor ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.knowledge_contributor FORCE ROW LEVEL SECURITY;
CREATE POLICY authorized_read ON catalog.knowledge_contributor FOR SELECT TO kc_application,kc_human_approver,kc_readonly
  USING(organization_id=security.current_organization() AND security.can_read_version(knowledge_version_id));
GRANT SELECT ON catalog.knowledge_contributor TO kc_application,kc_human_approver,kc_readonly;

CREATE FUNCTION catalog.record_contributor() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid;
BEGIN
  IF TG_OP='INSERT' THEN actor:=NEW.created_by;
  ELSIF (NEW.title,NEW.summary,NEW.content,NEW.custom_metadata) IS DISTINCT FROM (OLD.title,OLD.summary,OLD.content,OLD.custom_metadata) THEN
    actor:=security.current_principal();
  ELSE RETURN NULL; END IF;
  INSERT INTO catalog.knowledge_contributor VALUES(NEW.organization_id,NEW.knowledge_version_id,actor) ON CONFLICT DO NOTHING;
  RETURN NULL;
END $$;
CREATE TRIGGER track_contributor AFTER INSERT OR UPDATE ON catalog.knowledge_version FOR EACH ROW EXECUTE FUNCTION catalog.record_contributor();
CREATE FUNCTION governance.require_independent_review() RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog AS $$
BEGIN
  IF EXISTS(SELECT FROM catalog.knowledge_contributor WHERE organization_id=NEW.organization_id
    AND knowledge_version_id=NEW.knowledge_version_id AND principal_id=NEW.reviewer_id) THEN
    RAISE EXCEPTION 'A content contributor cannot approve this version' USING ERRCODE='23514'; END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER independent_review BEFORE INSERT ON governance.knowledge_review FOR EACH ROW EXECUTE FUNCTION governance.require_independent_review();
CREATE TRIGGER frozen_contributor BEFORE INSERT OR UPDATE OR DELETE ON catalog.knowledge_contributor FOR EACH ROW EXECUTE FUNCTION catalog.guard_version_child();

-- Physical integrity pins responsibilities/reviews to the exact configuration of the version.
ALTER TABLE catalog.knowledge_version ADD UNIQUE (organization_id,configuration_revision_id,knowledge_version_id);
ALTER TABLE governance.knowledge_responsibility ADD FOREIGN KEY (organization_id,configuration_revision_id,knowledge_version_id)
  REFERENCES catalog.knowledge_version(organization_id,configuration_revision_id,knowledge_version_id) ON DELETE RESTRICT;
ALTER TABLE governance.knowledge_review ADD FOREIGN KEY (organization_id,configuration_revision_id,knowledge_version_id)
  REFERENCES catalog.knowledge_version(organization_id,configuration_revision_id,knowledge_version_id) ON DELETE RESTRICT;
