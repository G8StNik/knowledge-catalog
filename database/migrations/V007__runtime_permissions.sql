-- Explicit grants: application/AI cannot edit or activate governed configuration.
ALTER TABLE catalog.domain ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.domain FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON catalog.domain TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON catalog.domain TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;
GRANT INSERT,UPDATE,DELETE ON catalog.domain TO kc_human_approver;
CREATE TRIGGER a_guard_draft BEFORE INSERT OR UPDATE OR DELETE ON catalog.domain
  FOR EACH ROW EXECUTE FUNCTION governance.guard_draft_entity();

ALTER TABLE catalog.taxonomy ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.taxonomy FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON catalog.taxonomy TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON catalog.taxonomy TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;
GRANT INSERT,UPDATE,DELETE ON catalog.taxonomy TO kc_human_approver;
CREATE TRIGGER a_guard_draft BEFORE INSERT OR UPDATE OR DELETE ON catalog.taxonomy
  FOR EACH ROW EXECUTE FUNCTION governance.guard_draft_entity();

ALTER TABLE catalog.taxonomy_term ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.taxonomy_term FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON catalog.taxonomy_term TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON catalog.taxonomy_term TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;
GRANT INSERT,UPDATE,DELETE ON catalog.taxonomy_term TO kc_human_approver;
CREATE TRIGGER a_guard_draft BEFORE INSERT OR UPDATE OR DELETE ON catalog.taxonomy_term
  FOR EACH ROW EXECUTE FUNCTION governance.guard_draft_entity();

ALTER TABLE catalog.term_alias ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.term_alias FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON catalog.term_alias TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON catalog.term_alias TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;
GRANT INSERT,UPDATE,DELETE ON catalog.term_alias TO kc_human_approver;
CREATE TRIGGER a_guard_draft BEFORE INSERT OR UPDATE OR DELETE ON catalog.term_alias
  FOR EACH ROW EXECUTE FUNCTION governance.guard_draft_entity();

ALTER TABLE governance.authority_level ENABLE ROW LEVEL SECURITY;
ALTER TABLE governance.authority_level FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON governance.authority_level TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON governance.authority_level TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;
GRANT INSERT,UPDATE,DELETE ON governance.authority_level TO kc_human_approver;
CREATE TRIGGER a_guard_draft BEFORE INSERT OR UPDATE OR DELETE ON governance.authority_level
  FOR EACH ROW EXECUTE FUNCTION governance.guard_draft_entity();

ALTER TABLE governance.classification ENABLE ROW LEVEL SECURITY;
ALTER TABLE governance.classification FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON governance.classification TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON governance.classification TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;
GRANT INSERT,UPDATE,DELETE ON governance.classification TO kc_human_approver;
CREATE TRIGGER a_guard_draft BEFORE INSERT OR UPDATE OR DELETE ON governance.classification
  FOR EACH ROW EXECUTE FUNCTION governance.guard_draft_entity();

ALTER TABLE governance.role ENABLE ROW LEVEL SECURITY;
ALTER TABLE governance.role FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON governance.role TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON governance.role TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;
GRANT INSERT,UPDATE,DELETE ON governance.role TO kc_human_approver;
CREATE TRIGGER a_guard_draft BEFORE INSERT OR UPDATE OR DELETE ON governance.role
  FOR EACH ROW EXECUTE FUNCTION governance.guard_draft_entity();

ALTER TABLE governance.lifecycle_workflow ENABLE ROW LEVEL SECURITY;
ALTER TABLE governance.lifecycle_workflow FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON governance.lifecycle_workflow TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON governance.lifecycle_workflow TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;
GRANT INSERT,UPDATE,DELETE ON governance.lifecycle_workflow TO kc_human_approver;
CREATE TRIGGER a_guard_draft BEFORE INSERT OR UPDATE OR DELETE ON governance.lifecycle_workflow
  FOR EACH ROW EXECUTE FUNCTION governance.guard_draft_entity();

ALTER TABLE governance.lifecycle_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE governance.lifecycle_state FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON governance.lifecycle_state TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON governance.lifecycle_state TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;
GRANT INSERT,UPDATE,DELETE ON governance.lifecycle_state TO kc_human_approver;
CREATE TRIGGER a_guard_draft BEFORE INSERT OR UPDATE OR DELETE ON governance.lifecycle_state
  FOR EACH ROW EXECUTE FUNCTION governance.guard_draft_entity();

ALTER TABLE governance.lifecycle_transition ENABLE ROW LEVEL SECURITY;
ALTER TABLE governance.lifecycle_transition FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON governance.lifecycle_transition TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON governance.lifecycle_transition TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;
GRANT INSERT,UPDATE,DELETE ON governance.lifecycle_transition TO kc_human_approver;
CREATE TRIGGER a_guard_draft BEFORE INSERT OR UPDATE OR DELETE ON governance.lifecycle_transition
  FOR EACH ROW EXECUTE FUNCTION governance.guard_draft_entity();

ALTER TABLE catalog.knowledge_type ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.knowledge_type FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON catalog.knowledge_type TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON catalog.knowledge_type TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;
GRANT INSERT,UPDATE,DELETE ON catalog.knowledge_type TO kc_human_approver;
CREATE TRIGGER a_guard_draft BEFORE INSERT OR UPDATE OR DELETE ON catalog.knowledge_type
  FOR EACH ROW EXECUTE FUNCTION governance.guard_draft_entity();

ALTER TABLE catalog.custom_field_definition ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.custom_field_definition FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON catalog.custom_field_definition TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON catalog.custom_field_definition TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;
GRANT INSERT,UPDATE,DELETE ON catalog.custom_field_definition TO kc_human_approver;
CREATE TRIGGER a_guard_draft BEFORE INSERT OR UPDATE OR DELETE ON catalog.custom_field_definition
  FOR EACH ROW EXECUTE FUNCTION governance.guard_draft_entity();

ALTER TABLE catalog.custom_field_choice ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.custom_field_choice FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON catalog.custom_field_choice TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON catalog.custom_field_choice TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;
GRANT INSERT,UPDATE,DELETE ON catalog.custom_field_choice TO kc_human_approver;
CREATE TRIGGER a_guard_draft BEFORE INSERT OR UPDATE OR DELETE ON catalog.custom_field_choice
  FOR EACH ROW EXECUTE FUNCTION governance.guard_draft_entity();

ALTER TABLE catalog.knowledge_type_field ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.knowledge_type_field FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON catalog.knowledge_type_field TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON catalog.knowledge_type_field TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;
GRANT INSERT,UPDATE,DELETE ON catalog.knowledge_type_field TO kc_human_approver;
CREATE TRIGGER a_guard_draft BEFORE INSERT OR UPDATE OR DELETE ON catalog.knowledge_type_field
  FOR EACH ROW EXECUTE FUNCTION governance.guard_draft_entity();

ALTER TABLE catalog.relationship_type ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.relationship_type FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON catalog.relationship_type TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON catalog.relationship_type TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;
GRANT INSERT,UPDATE,DELETE ON catalog.relationship_type TO kc_human_approver;
CREATE TRIGGER a_guard_draft BEFORE INSERT OR UPDATE OR DELETE ON catalog.relationship_type
  FOR EACH ROW EXECUTE FUNCTION governance.guard_draft_entity();

ALTER TABLE catalog.relationship_type_restriction ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.relationship_type_restriction FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON catalog.relationship_type_restriction TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON catalog.relationship_type_restriction TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;
GRANT INSERT,UPDATE,DELETE ON catalog.relationship_type_restriction TO kc_human_approver;
CREATE TRIGGER a_guard_draft BEFORE INSERT OR UPDATE OR DELETE ON catalog.relationship_type_restriction
  FOR EACH ROW EXECUTE FUNCTION governance.guard_draft_entity();

ALTER TABLE governance.responsibility_requirement ENABLE ROW LEVEL SECURITY;
ALTER TABLE governance.responsibility_requirement FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON governance.responsibility_requirement TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON governance.responsibility_requirement TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;
GRANT INSERT,UPDATE,DELETE ON governance.responsibility_requirement TO kc_human_approver;
CREATE TRIGGER a_guard_draft BEFORE INSERT OR UPDATE OR DELETE ON governance.responsibility_requirement
  FOR EACH ROW EXECUTE FUNCTION governance.guard_draft_entity();

ALTER TABLE catalog.knowledge_template ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.knowledge_template FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON catalog.knowledge_template TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON catalog.knowledge_template TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;
GRANT INSERT,UPDATE,DELETE ON catalog.knowledge_template TO kc_human_approver;
CREATE TRIGGER a_guard_draft BEFORE INSERT OR UPDATE OR DELETE ON catalog.knowledge_template
  FOR EACH ROW EXECUTE FUNCTION governance.guard_draft_entity();

ALTER TABLE catalog.template_responsibility ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.template_responsibility FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON catalog.template_responsibility TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON catalog.template_responsibility TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;
GRANT INSERT,UPDATE,DELETE ON catalog.template_responsibility TO kc_human_approver;
CREATE TRIGGER a_guard_draft BEFORE INSERT OR UPDATE OR DELETE ON catalog.template_responsibility
  FOR EACH ROW EXECUTE FUNCTION governance.guard_draft_entity();

ALTER TABLE catalog.template_field ENABLE ROW LEVEL SECURITY;
ALTER TABLE catalog.template_field FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON catalog.template_field TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON catalog.template_field TO kc_application,kc_ingestion,kc_readonly,kc_ai_agent,kc_human_approver;
GRANT INSERT,UPDATE,DELETE ON catalog.template_field TO kc_human_approver;
CREATE TRIGGER a_guard_draft BEFORE INSERT OR UPDATE OR DELETE ON catalog.template_field
  FOR EACH ROW EXECUTE FUNCTION governance.guard_draft_entity();

ALTER TABLE governance.configuration_revision ENABLE ROW LEVEL SECURITY;
ALTER TABLE governance.configuration_revision FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON governance.configuration_revision TO kc_application,kc_ingestion,kc_readonly,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON governance.configuration_revision TO kc_application,kc_ingestion,kc_readonly,kc_human_approver;
CREATE POLICY ai_read ON governance.configuration_revision TO kc_ai_agent USING (organization_id=security.current_organization());
GRANT SELECT ON governance.configuration_revision TO kc_ai_agent;
ALTER TABLE governance.configuration_activation ENABLE ROW LEVEL SECURITY;
ALTER TABLE governance.configuration_activation FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON governance.configuration_activation TO kc_application,kc_ingestion,kc_readonly,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON governance.configuration_activation TO kc_application,kc_ingestion,kc_readonly,kc_human_approver;
CREATE POLICY ai_read ON governance.configuration_activation TO kc_ai_agent USING (organization_id=security.current_organization());
GRANT SELECT ON governance.configuration_activation TO kc_ai_agent;
ALTER TABLE governance.configuration_proposal ENABLE ROW LEVEL SECURITY;
ALTER TABLE governance.configuration_proposal FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON governance.configuration_proposal TO kc_application,kc_ingestion,kc_readonly,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON governance.configuration_proposal TO kc_application,kc_ingestion,kc_readonly,kc_human_approver;
CREATE POLICY ai_read ON governance.configuration_proposal TO kc_ai_agent USING (organization_id=security.current_organization() AND generated_by=security.current_principal());
GRANT SELECT ON governance.configuration_proposal TO kc_ai_agent;
ALTER TABLE security.configuration_permission ENABLE ROW LEVEL SECURITY;
ALTER TABLE security.configuration_permission FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON security.configuration_permission TO kc_application,kc_ingestion,kc_readonly,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON security.configuration_permission TO kc_application,kc_ingestion,kc_readonly,kc_human_approver;
CREATE POLICY ai_read ON security.configuration_permission TO kc_ai_agent USING (organization_id=security.current_organization());
GRANT SELECT ON security.configuration_permission TO kc_ai_agent;
ALTER TABLE audit.event ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit.event FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_isolation ON audit.event TO kc_application,kc_ingestion,kc_readonly,kc_human_approver
  USING (organization_id=security.current_organization()) WITH CHECK (organization_id=security.current_organization());
GRANT SELECT ON audit.event TO kc_application,kc_ingestion,kc_readonly,kc_human_approver;
CREATE POLICY ai_read ON audit.event TO kc_ai_agent USING (organization_id=security.current_organization() AND actor_principal_id=security.current_principal());
GRANT SELECT ON audit.event TO kc_ai_agent;
CREATE POLICY platform_permissions ON security.configuration_permission TO kc_platform_admin USING (true) WITH CHECK (true);
GRANT EXECUTE ON FUNCTION governance.propose_configuration(uuid,uuid,jsonb,text,numeric,jsonb,jsonb)
  TO kc_ai_agent,kc_application,kc_ingestion,kc_human_approver;
GRANT EXECUTE ON FUNCTION governance.create_revision(uuid,text,integer,text,uuid),
  governance.approve_and_activate(uuid,uuid,uuid,timestamptz,timestamptz,text),
  governance.reject_proposal(uuid,uuid,text),governance.deactivate_configuration(uuid,uuid,timestamptz,text)
  TO kc_human_approver;
-- Helpers called by invoker triggers; approval functions remain separately restricted.
GRANT EXECUTE ON FUNCTION governance.snapshot_revision(uuid,uuid) TO kc_human_approver;
CREATE TRIGGER touch_updated_at BEFORE UPDATE ON core.organization FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();
CREATE TRIGGER touch_updated_at BEFORE UPDATE ON core.workspace FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();
CREATE TRIGGER touch_updated_at BEFORE UPDATE ON core.organization_setting FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();
CREATE TRIGGER touch_updated_at BEFORE UPDATE ON identity.account FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();
CREATE TRIGGER touch_updated_at BEFORE UPDATE ON identity.principal FOR EACH ROW EXECUTE FUNCTION core.touch_updated_at();
