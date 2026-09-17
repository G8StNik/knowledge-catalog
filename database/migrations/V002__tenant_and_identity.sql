CREATE TABLE core.organization (
  organization_id uuid PRIMARY KEY,
  organization_key citext NOT NULL UNIQUE,
  organization_name text NOT NULL CHECK (btrim(organization_name) <> ''),
  display_name text, description text, industry text,
  default_language text NOT NULL DEFAULT 'en', default_timezone text NOT NULL DEFAULT 'UTC',
  status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('PROVISIONING','ACTIVE','SUSPENDED','DEACTIVATED')),
  configuration jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(configuration) = 'object'),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  updated_at timestamptz NOT NULL DEFAULT clock_timestamp(), deleted_at timestamptz, deleted_by uuid
);
CREATE TABLE core.workspace (
  workspace_id uuid PRIMARY KEY, organization_id uuid NOT NULL REFERENCES core.organization ON DELETE RESTRICT,
  workspace_key citext NOT NULL, workspace_name text NOT NULL,
  description text, status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','ARCHIVED')),
  configuration jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(configuration) = 'object'),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(), updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  deleted_at timestamptz, deleted_by uuid,
  UNIQUE (organization_id, workspace_id), UNIQUE (organization_id, workspace_key)
);
CREATE TABLE core.organization_setting (
  organization_setting_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES core.organization ON DELETE RESTRICT,
  setting_key text NOT NULL, setting_value jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(), updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (organization_id, setting_key)
);
CREATE TABLE identity.account (
  account_id uuid PRIMARY KEY, display_name text, primary_email citext UNIQUE,
  status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','DEACTIVATED')),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(), updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE TABLE identity.organization_membership (
  organization_membership_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES core.organization ON DELETE RESTRICT,
  account_id uuid NOT NULL REFERENCES identity.account ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('INVITED','ACTIVE','SUSPENDED','LEFT')),
  joined_at timestamptz NOT NULL DEFAULT clock_timestamp(), left_at timestamptz,
  UNIQUE (organization_id, account_id), CHECK (left_at IS NULL OR left_at >= joined_at)
);
CREATE TABLE identity.principal (
  principal_id uuid PRIMARY KEY, organization_id uuid NOT NULL REFERENCES core.organization ON DELETE RESTRICT,
  account_id uuid, principal_type text NOT NULL CHECK (principal_type IN ('USER','GROUP','SERVICE','AI_AGENT')),
  display_name text NOT NULL, email citext,
  status text NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','SUSPENDED','DEACTIVATED')),
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(), updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  UNIQUE (organization_id, principal_id), UNIQUE (organization_id, account_id),
  FOREIGN KEY (organization_id, account_id) REFERENCES identity.organization_membership(organization_id,account_id) ON DELETE RESTRICT,
  CHECK ((principal_type = 'USER') = (account_id IS NOT NULL))
);
CREATE TABLE identity.external_identity (
  external_identity_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL REFERENCES core.organization ON DELETE RESTRICT, principal_id uuid NOT NULL,
  provider text NOT NULL, provider_tenant_id text NOT NULL DEFAULT '', provider_object_id text NOT NULL,
  provider_email citext, metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  FOREIGN KEY (organization_id, principal_id) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT,
  UNIQUE (organization_id, provider, provider_tenant_id, provider_object_id)
);
CREATE TABLE identity.group_membership (
  group_membership_id uuid PRIMARY KEY, organization_id uuid NOT NULL REFERENCES core.organization ON DELETE RESTRICT,
  group_principal_id uuid NOT NULL, member_principal_id uuid NOT NULL,
  effective_from timestamptz NOT NULL DEFAULT clock_timestamp(), effective_to timestamptz,
  created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  FOREIGN KEY (organization_id, group_principal_id) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id, member_principal_id) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT,
  UNIQUE (organization_id,group_principal_id,member_principal_id,effective_from),
  CHECK (group_principal_id <> member_principal_id), CHECK (effective_to IS NULL OR effective_to > effective_from)
);
CREATE INDEX group_membership_member ON identity.group_membership(organization_id,member_principal_id);
ALTER TABLE core.organization ADD FOREIGN KEY (organization_id,deleted_by) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT;
ALTER TABLE core.workspace ADD FOREIGN KEY (organization_id,deleted_by) REFERENCES identity.principal(organization_id,principal_id) ON DELETE RESTRICT;

CREATE FUNCTION identity.check_group() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  -- Serialize graph edits per tenant, including concurrent opposing edges.
  PERFORM 1 FROM core.organization WHERE organization_id = NEW.organization_id FOR UPDATE;
  IF NOT EXISTS (SELECT FROM identity.principal WHERE organization_id = NEW.organization_id
    AND principal_id = NEW.group_principal_id AND principal_type = 'GROUP') THEN
    RAISE EXCEPTION 'Parent principal must be GROUP' USING ERRCODE = '23514';
  END IF;
  -- Conservatively reject cycles even across historical membership intervals.
  IF EXISTS (WITH RECURSIVE descendants(id) AS (
    SELECT NEW.member_principal_id UNION
    SELECT m.member_principal_id FROM identity.group_membership m JOIN descendants d ON m.group_principal_id = d.id
    WHERE m.organization_id = NEW.organization_id AND m.group_membership_id <> NEW.group_membership_id
  ) SELECT FROM descendants WHERE id = NEW.group_principal_id) THEN
    RAISE EXCEPTION 'Group membership cycle' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER group_integrity BEFORE INSERT OR UPDATE ON identity.group_membership FOR EACH ROW EXECUTE FUNCTION identity.check_group();

CREATE FUNCTION identity.prevent_principal_retyping() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF (NEW.organization_id,NEW.principal_id,NEW.principal_type,NEW.account_id)
    IS DISTINCT FROM (OLD.organization_id,OLD.principal_id,OLD.principal_type,OLD.account_id) THEN
    RAISE EXCEPTION 'Principal identity and kind are immutable' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER principal_identity BEFORE UPDATE ON identity.principal FOR EACH ROW EXECUTE FUNCTION identity.prevent_principal_retyping();
