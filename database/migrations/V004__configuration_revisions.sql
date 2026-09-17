CREATE TABLE governance.configuration_proposal (
  configuration_proposal_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES core.organization ON DELETE RESTRICT,
  generated_by uuid NOT NULL, origin text NOT NULL CHECK (origin IN ('HUMAN','AI_AGENT','SERVICE')),
  rationale text NOT NULL, confidence numeric CHECK (confidence BETWEEN 0 AND 1),
  evidence jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(evidence)='array'),
  proposed_package jsonb NOT NULL CHECK (jsonb_typeof(proposed_package)='object'),
  generator_metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(generator_metadata)='object'),
  status text NOT NULL DEFAULT 'PENDING' CHECK (status IN ('PENDING','APPROVED','REJECTED')),
  reviewed_by uuid, reviewed_at timestamptz, review_note text,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (organization_id,configuration_proposal_id),
  FOREIGN KEY (organization_id,generated_by) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,reviewed_by) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT,
  CHECK ((status='PENDING' AND reviewed_by IS NULL AND reviewed_at IS NULL) OR
         (status<>'PENDING' AND reviewed_by IS NOT NULL AND reviewed_at IS NOT NULL))
);
CREATE TABLE governance.configuration_revision (
  configuration_revision_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES core.organization ON DELETE RESTRICT,
  package_key text NOT NULL, version integer NOT NULL CHECK (version>0),
  status text NOT NULL DEFAULT 'DRAFT' CHECK (status IN ('DRAFT','APPROVED')),
  description text, source_proposal_id uuid,
  created_by uuid NOT NULL, created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  approved_by uuid, approved_at timestamptz, approved_digest text,
  UNIQUE (organization_id,configuration_revision_id), UNIQUE (organization_id,package_key,version),
  FOREIGN KEY (organization_id,source_proposal_id) REFERENCES governance.configuration_proposal(organization_id,configuration_proposal_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,created_by) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,approved_by) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT,
  CHECK ((status='DRAFT' AND approved_by IS NULL AND approved_at IS NULL AND approved_digest IS NULL) OR
         (status='APPROVED' AND approved_by IS NOT NULL AND approved_at IS NOT NULL AND approved_digest IS NOT NULL))
);
CREATE UNIQUE INDEX proposal_one_revision ON governance.configuration_revision(organization_id,source_proposal_id) WHERE source_proposal_id IS NOT NULL;
CREATE TABLE governance.configuration_activation (
  configuration_activation_id uuid PRIMARY KEY, organization_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL, package_key text NOT NULL,
  effective_from timestamptz NOT NULL, effective_to timestamptz,
  activated_by uuid NOT NULL, activated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  FOREIGN KEY (organization_id,configuration_revision_id) REFERENCES governance.configuration_revision(organization_id,configuration_revision_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,activated_by) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT,
  CHECK (effective_to IS NULL OR effective_to>effective_from),
  EXCLUDE USING gist (organization_id WITH =,package_key WITH =,tstzrange(effective_from,effective_to,'[)') WITH &&)
);
-- Administrative permissions are separate from configurable business responsibility roles.
CREATE TABLE security.configuration_permission (
  configuration_permission_id uuid PRIMARY KEY, organization_id uuid NOT NULL,
  principal_id uuid NOT NULL,
  can_approve boolean NOT NULL DEFAULT false,
  effective_from timestamptz NOT NULL DEFAULT clock_timestamp(), effective_to timestamptz,
  FOREIGN KEY (organization_id,principal_id) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT,
  UNIQUE (organization_id,principal_id), CHECK (effective_to IS NULL OR effective_to>effective_from)
);
CREATE TABLE audit.event (
  audit_event_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES core.organization ON DELETE RESTRICT,
  occurred_at timestamptz NOT NULL DEFAULT clock_timestamp(), actor_principal_id uuid NOT NULL,
  action text NOT NULL, entity_type text NOT NULL, entity_id uuid NOT NULL,
  request_id uuid, correlation_id uuid, before_state jsonb, after_state jsonb,
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata)='object'),
  FOREIGN KEY (organization_id,actor_principal_id) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT
);
CREATE INDEX audit_tenant_time ON audit.event(organization_id,occurred_at);

CREATE FUNCTION security.require_configuration_approver() RETURNS uuid
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog AS $$
DECLARE actor uuid;
BEGIN
  SELECT c.principal_id INTO actor FROM security.context() c
  JOIN security.configuration_permission p USING (organization_id,principal_id)
  WHERE c.principal_type='USER' AND p.can_approve AND p.effective_from<=statement_timestamp()
    AND (p.effective_to IS NULL OR p.effective_to>statement_timestamp());
  IF actor IS NULL THEN RAISE EXCEPTION 'Authorized human approval required' USING ERRCODE='42501'; END IF;
  RETURN actor;
END $$;
GRANT USAGE ON SCHEMA governance TO kc_platform_admin;
GRANT SELECT,INSERT,UPDATE ON security.configuration_permission TO kc_platform_admin;
