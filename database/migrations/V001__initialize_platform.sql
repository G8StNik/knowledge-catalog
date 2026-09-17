CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE SCHEMA core;
CREATE SCHEMA identity;
CREATE SCHEMA catalog;
CREATE SCHEMA source;
CREATE SCHEMA governance;
CREATE SCHEMA security;
CREATE SCHEMA operations;
CREATE SCHEMA audit;
REVOKE CREATE ON SCHEMA public FROM PUBLIC;

-- Cluster-wide group roles: operators assign distinct LOGIN roles to these groups.
DO $$
DECLARE r text;
BEGIN
  FOREACH r IN ARRAY ARRAY['kc_application','kc_ingestion','kc_readonly',
    'kc_ai_agent','kc_human_approver','kc_platform_admin','kc_context_owner'] LOOP
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = r) THEN
      EXECUTE format('CREATE ROLE %I NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS', r);
    END IF;
  END LOOP;
END $$;
-- This NOLOGIN role owns only narrowly scoped context-validation functions.
-- Never grant membership in it to a runtime role.
ALTER ROLE kc_context_owner BYPASSRLS;

ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES REVOKE ALL ON TABLES FROM PUBLIC;

CREATE FUNCTION core.touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.updated_at := clock_timestamp(); RETURN NEW; END $$;
