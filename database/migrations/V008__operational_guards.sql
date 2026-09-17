-- Reject unsafe pre-existing group-role definitions rather than inheriting them silently.
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['kc_application','kc_ingestion','kc_readonly','kc_ai_agent','kc_human_approver','kc_platform_admin','kc_context_owner'] LOOP
    IF EXISTS(SELECT FROM pg_roles WHERE rolname=r AND (rolcanlogin OR rolsuper OR rolcreaterole OR rolcreatedb)) THEN
      RAISE EXCEPTION 'Unsafe pre-existing role: %',r;
    END IF;
    IF r<>'kc_context_owner' AND EXISTS(SELECT FROM pg_roles WHERE rolname=r AND rolbypassrls) THEN
      RAISE EXCEPTION 'Unexpected BYPASSRLS: %',r;
    END IF;
    IF r NOT IN ('kc_context_owner','kc_platform_admin') AND
      (pg_has_role(r,'kc_context_owner','MEMBER') OR pg_has_role(r,'kc_platform_admin','MEMBER')) THEN
      RAISE EXCEPTION 'Runtime role inherits privileged access: %',r;
    END IF;
  END LOOP;
END $$;

ALTER TABLE security.session_ticket ENABLE ROW LEVEL SECURITY;
ALTER TABLE security.session_ticket FORCE ROW LEVEL SECURITY;
CREATE POLICY broker_ticket ON security.session_ticket TO kc_platform_admin USING (true) WITH CHECK (true);
GRANT SELECT ON security.session_ticket TO kc_platform_admin;

ALTER TABLE governance.configuration_revision ADD UNIQUE (organization_id,configuration_revision_id,package_key);
ALTER TABLE governance.configuration_activation ADD FOREIGN KEY (organization_id,configuration_revision_id,package_key)
  REFERENCES governance.configuration_revision(organization_id,configuration_revision_id,package_key) ON DELETE RESTRICT;

CREATE FUNCTION governance.guard_proposal() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP='DELETE' OR OLD.status<>'PENDING' THEN
    RAISE EXCEPTION 'Proposal history is immutable' USING ERRCODE='23514';
  END IF;
  IF (to_jsonb(NEW)-ARRAY['status','reviewed_by','reviewed_at','review_note'])
     IS DISTINCT FROM (to_jsonb(OLD)-ARRAY['status','reviewed_by','reviewed_at','review_note']) THEN
    RAISE EXCEPTION 'Original proposal and provenance are immutable' USING ERRCODE='23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER proposal_history BEFORE UPDATE OR DELETE ON governance.configuration_proposal FOR EACH ROW EXECUTE FUNCTION governance.guard_proposal();
CREATE TRIGGER no_truncate BEFORE TRUNCATE ON audit.event FOR EACH STATEMENT EXECUTE FUNCTION audit.reject_mutation();
