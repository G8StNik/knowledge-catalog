-- Every configuration entity belongs to an immutable, complete package revision.
CREATE TABLE catalog.domain (
  domain_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL,
  key text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]*$'),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  description text,
  is_enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata)='object'),
  parent_domain_id uuid,
  workspace_id uuid,
  sort_order integer NOT NULL DEFAULT 0,
  UNIQUE (organization_id,configuration_revision_id,domain_id),
  UNIQUE (organization_id,configuration_revision_id,key),
  FOREIGN KEY (organization_id,configuration_revision_id) REFERENCES governance.configuration_revision(organization_id,configuration_revision_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,parent_domain_id) REFERENCES catalog.domain(organization_id,configuration_revision_id,domain_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,workspace_id) REFERENCES core.workspace(organization_id,workspace_id) ON DELETE RESTRICT,
  CHECK (parent_domain_id IS DISTINCT FROM domain_id)
);

CREATE TABLE catalog.taxonomy (
  taxonomy_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL,
  key text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]*$'),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  description text,
  is_enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata)='object'),
  UNIQUE (organization_id,configuration_revision_id,taxonomy_id),
  UNIQUE (organization_id,configuration_revision_id,key),
  FOREIGN KEY (organization_id,configuration_revision_id) REFERENCES governance.configuration_revision(organization_id,configuration_revision_id) ON DELETE RESTRICT
);

CREATE TABLE catalog.taxonomy_term (
  taxonomy_term_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL,
  key text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]*$'),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  description text,
  is_enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata)='object'),
  taxonomy_id uuid NOT NULL,
  parent_term_id uuid,
  sort_order integer NOT NULL DEFAULT 0,
  UNIQUE (organization_id,configuration_revision_id,taxonomy_term_id),
  UNIQUE (organization_id,configuration_revision_id,key),
  FOREIGN KEY (organization_id,configuration_revision_id) REFERENCES governance.configuration_revision(organization_id,configuration_revision_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,taxonomy_id) REFERENCES catalog.taxonomy(organization_id,configuration_revision_id,taxonomy_id) ON DELETE RESTRICT,
  UNIQUE (organization_id,configuration_revision_id,taxonomy_id,taxonomy_term_id),
  FOREIGN KEY (organization_id,configuration_revision_id,taxonomy_id,parent_term_id) REFERENCES catalog.taxonomy_term(organization_id,configuration_revision_id,taxonomy_id,taxonomy_term_id) ON DELETE RESTRICT,
  CHECK (parent_term_id IS DISTINCT FROM taxonomy_term_id)
);

CREATE TABLE catalog.term_alias (
  term_alias_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL,
  key text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]*$'),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  description text,
  is_enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata)='object'),
  taxonomy_term_id uuid NOT NULL,
  alias text NOT NULL,
  language text NOT NULL DEFAULT 'en',
  alias_kind text NOT NULL CHECK (alias_kind IN ('SYNONYM','ACRONYM','ALIAS','TRANSLATION')),
  UNIQUE (organization_id,configuration_revision_id,term_alias_id),
  UNIQUE (organization_id,configuration_revision_id,key),
  FOREIGN KEY (organization_id,configuration_revision_id) REFERENCES governance.configuration_revision(organization_id,configuration_revision_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,taxonomy_term_id) REFERENCES catalog.taxonomy_term(organization_id,configuration_revision_id,taxonomy_term_id) ON DELETE RESTRICT,
  UNIQUE (organization_id,configuration_revision_id,taxonomy_term_id,language,alias)
);

CREATE TABLE governance.authority_level (
  authority_level_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL,
  key text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]*$'),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  description text,
  is_enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata)='object'),
  trust_rank integer NOT NULL CHECK (trust_rank>0),
  requires_evidence boolean NOT NULL DEFAULT true,
  requires_human_approval boolean NOT NULL DEFAULT true,
  UNIQUE (organization_id,configuration_revision_id,authority_level_id),
  UNIQUE (organization_id,configuration_revision_id,key),
  FOREIGN KEY (organization_id,configuration_revision_id) REFERENCES governance.configuration_revision(organization_id,configuration_revision_id) ON DELETE RESTRICT
);

CREATE TABLE governance.classification (
  classification_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL,
  key text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]*$'),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  description text,
  is_enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata)='object'),
  sensitivity_rank integer NOT NULL CHECK (sensitivity_rank>=0),
  is_ai_eligible boolean NOT NULL DEFAULT false,
  is_external_ai_allowed boolean NOT NULL DEFAULT false,
  handling_rules jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(handling_rules)='object'),
  UNIQUE (organization_id,configuration_revision_id,classification_id),
  UNIQUE (organization_id,configuration_revision_id,key),
  FOREIGN KEY (organization_id,configuration_revision_id) REFERENCES governance.configuration_revision(organization_id,configuration_revision_id) ON DELETE RESTRICT,
  CHECK (NOT is_external_ai_allowed OR is_ai_eligible)
);

CREATE TABLE governance.role (
  role_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL,
  key text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]*$'),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  description text,
  is_enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata)='object'),
  allowed_principal_types text[] NOT NULL DEFAULT ARRAY['USER','GROUP'],
  CHECK (cardinality(allowed_principal_types)>0 AND allowed_principal_types <@ ARRAY['USER','GROUP','SERVICE','AI_AGENT']),
  UNIQUE (organization_id,configuration_revision_id,role_id),
  UNIQUE (organization_id,configuration_revision_id,key),
  FOREIGN KEY (organization_id,configuration_revision_id) REFERENCES governance.configuration_revision(organization_id,configuration_revision_id) ON DELETE RESTRICT
);

CREATE TABLE governance.lifecycle_workflow (
  lifecycle_workflow_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL,
  key text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]*$'),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  description text,
  is_enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata)='object'),
  UNIQUE (organization_id,configuration_revision_id,lifecycle_workflow_id),
  UNIQUE (organization_id,configuration_revision_id,key),
  FOREIGN KEY (organization_id,configuration_revision_id) REFERENCES governance.configuration_revision(organization_id,configuration_revision_id) ON DELETE RESTRICT
);

CREATE TABLE governance.lifecycle_state (
  lifecycle_state_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL,
  key text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]*$'),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  description text,
  is_enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata)='object'),
  lifecycle_workflow_id uuid NOT NULL,
  is_initial boolean NOT NULL DEFAULT false,
  is_terminal boolean NOT NULL DEFAULT false,
  is_published boolean NOT NULL DEFAULT false,
  UNIQUE (organization_id,configuration_revision_id,lifecycle_state_id),
  UNIQUE (organization_id,configuration_revision_id,key),
  FOREIGN KEY (organization_id,configuration_revision_id) REFERENCES governance.configuration_revision(organization_id,configuration_revision_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,lifecycle_workflow_id) REFERENCES governance.lifecycle_workflow(organization_id,configuration_revision_id,lifecycle_workflow_id) ON DELETE RESTRICT,
  UNIQUE (organization_id,configuration_revision_id,lifecycle_workflow_id,lifecycle_state_id)
);

CREATE UNIQUE INDEX workflow_one_initial ON governance.lifecycle_state(organization_id,configuration_revision_id,lifecycle_workflow_id) WHERE is_initial;

CREATE TABLE governance.lifecycle_transition (
  lifecycle_transition_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL,
  key text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]*$'),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  description text,
  is_enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata)='object'),
  lifecycle_workflow_id uuid NOT NULL,
  from_state_id uuid NOT NULL,
  to_state_id uuid NOT NULL,
  approval_role_id uuid,
  minimum_approvals integer NOT NULL DEFAULT 0 CHECK (minimum_approvals>=0),
  requires_human_approval boolean NOT NULL DEFAULT false,
  conditions jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(conditions)='object'),
  UNIQUE (organization_id,configuration_revision_id,lifecycle_transition_id),
  UNIQUE (organization_id,configuration_revision_id,key),
  FOREIGN KEY (organization_id,configuration_revision_id) REFERENCES governance.configuration_revision(organization_id,configuration_revision_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,lifecycle_workflow_id) REFERENCES governance.lifecycle_workflow(organization_id,configuration_revision_id,lifecycle_workflow_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,approval_role_id) REFERENCES governance.role(organization_id,configuration_revision_id,role_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,lifecycle_workflow_id,from_state_id) REFERENCES governance.lifecycle_state(organization_id,configuration_revision_id,lifecycle_workflow_id,lifecycle_state_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,lifecycle_workflow_id,to_state_id) REFERENCES governance.lifecycle_state(organization_id,configuration_revision_id,lifecycle_workflow_id,lifecycle_state_id) ON DELETE RESTRICT,
  CHECK (from_state_id<>to_state_id),
  CHECK (minimum_approvals=0 OR approval_role_id IS NOT NULL),
  CHECK (NOT requires_human_approval OR minimum_approvals>0),
  UNIQUE (organization_id,configuration_revision_id,from_state_id,to_state_id)
);

CREATE TABLE catalog.knowledge_type (
  knowledge_type_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL,
  key text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]*$'),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  description text,
  is_enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata)='object'),
  default_authority_level_id uuid,
  default_classification_id uuid,
  lifecycle_workflow_id uuid,
  is_ai_eligible_default boolean NOT NULL DEFAULT false,
  requires_approval boolean NOT NULL DEFAULT true,
  UNIQUE (organization_id,configuration_revision_id,knowledge_type_id),
  UNIQUE (organization_id,configuration_revision_id,key),
  FOREIGN KEY (organization_id,configuration_revision_id) REFERENCES governance.configuration_revision(organization_id,configuration_revision_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,default_authority_level_id) REFERENCES governance.authority_level(organization_id,configuration_revision_id,authority_level_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,default_classification_id) REFERENCES governance.classification(organization_id,configuration_revision_id,classification_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,lifecycle_workflow_id) REFERENCES governance.lifecycle_workflow(organization_id,configuration_revision_id,lifecycle_workflow_id) ON DELETE RESTRICT
);

CREATE TABLE catalog.custom_field_definition (
  custom_field_definition_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL,
  key text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]*$'),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  description text,
  is_enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata)='object'),
  data_type text NOT NULL CHECK (data_type IN ('TEXT','NUMBER','BOOLEAN','DATE','DATETIME','CHOICE','MULTICHOICE','CURRENCY','URL','EMAIL','RICHTEXT','PERSON','GROUP','KNOWLEDGE_REFERENCE','SOURCE_REFERENCE','CALCULATED')),
  is_required boolean NOT NULL DEFAULT false,
  is_searchable boolean NOT NULL DEFAULT false,
  is_filterable boolean NOT NULL DEFAULT false,
  is_ai_visible boolean NOT NULL DEFAULT false,
  validation_schema jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(validation_schema)='object'),
  conditional_rules jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(conditional_rules)='object'),
  calculation jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(calculation)='object'),
  reference_target_type text,
  default_value jsonb,
  UNIQUE (organization_id,configuration_revision_id,custom_field_definition_id),
  UNIQUE (organization_id,configuration_revision_id,key),
  FOREIGN KEY (organization_id,configuration_revision_id) REFERENCES governance.configuration_revision(organization_id,configuration_revision_id) ON DELETE RESTRICT
);

CREATE TABLE catalog.custom_field_choice (
  custom_field_choice_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL,
  key text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]*$'),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  description text,
  is_enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata)='object'),
  custom_field_definition_id uuid NOT NULL,
  value text NOT NULL,
  sort_order integer NOT NULL DEFAULT 0,
  UNIQUE (organization_id,configuration_revision_id,custom_field_choice_id),
  UNIQUE (organization_id,configuration_revision_id,key),
  FOREIGN KEY (organization_id,configuration_revision_id) REFERENCES governance.configuration_revision(organization_id,configuration_revision_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,custom_field_definition_id) REFERENCES catalog.custom_field_definition(organization_id,configuration_revision_id,custom_field_definition_id) ON DELETE RESTRICT,
  UNIQUE (organization_id,configuration_revision_id,custom_field_definition_id,value)
);

CREATE TABLE catalog.knowledge_type_field (
  knowledge_type_field_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL,
  key text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]*$'),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  description text,
  is_enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata)='object'),
  knowledge_type_id uuid NOT NULL,
  custom_field_definition_id uuid NOT NULL,
  is_required boolean NOT NULL DEFAULT false,
  sort_order integer NOT NULL DEFAULT 0,
  UNIQUE (organization_id,configuration_revision_id,knowledge_type_field_id),
  UNIQUE (organization_id,configuration_revision_id,key),
  FOREIGN KEY (organization_id,configuration_revision_id) REFERENCES governance.configuration_revision(organization_id,configuration_revision_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,knowledge_type_id) REFERENCES catalog.knowledge_type(organization_id,configuration_revision_id,knowledge_type_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,custom_field_definition_id) REFERENCES catalog.custom_field_definition(organization_id,configuration_revision_id,custom_field_definition_id) ON DELETE RESTRICT,
  UNIQUE (organization_id,configuration_revision_id,knowledge_type_id,custom_field_definition_id)
);

CREATE TABLE catalog.relationship_type (
  relationship_type_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL,
  key text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]*$'),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  description text,
  is_enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata)='object'),
  forward_label text NOT NULL,
  reverse_label text NOT NULL,
  is_symmetric boolean NOT NULL DEFAULT false,
  allows_self_reference boolean NOT NULL DEFAULT false,
  requires_evidence boolean NOT NULL DEFAULT true,
  UNIQUE (organization_id,configuration_revision_id,relationship_type_id),
  UNIQUE (organization_id,configuration_revision_id,key),
  FOREIGN KEY (organization_id,configuration_revision_id) REFERENCES governance.configuration_revision(organization_id,configuration_revision_id) ON DELETE RESTRICT
);

CREATE TABLE catalog.relationship_type_restriction (
  relationship_type_restriction_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL,
  key text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]*$'),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  description text,
  is_enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata)='object'),
  relationship_type_id uuid NOT NULL,
  source_knowledge_type_id uuid NOT NULL,
  target_knowledge_type_id uuid NOT NULL,
  UNIQUE (organization_id,configuration_revision_id,relationship_type_restriction_id),
  UNIQUE (organization_id,configuration_revision_id,key),
  FOREIGN KEY (organization_id,configuration_revision_id) REFERENCES governance.configuration_revision(organization_id,configuration_revision_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,relationship_type_id) REFERENCES catalog.relationship_type(organization_id,configuration_revision_id,relationship_type_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,source_knowledge_type_id) REFERENCES catalog.knowledge_type(organization_id,configuration_revision_id,knowledge_type_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,target_knowledge_type_id) REFERENCES catalog.knowledge_type(organization_id,configuration_revision_id,knowledge_type_id) ON DELETE RESTRICT,
  UNIQUE (organization_id,configuration_revision_id,relationship_type_id,source_knowledge_type_id,target_knowledge_type_id)
);

CREATE TABLE governance.responsibility_requirement (
  responsibility_requirement_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL,
  key text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]*$'),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  description text,
  is_enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata)='object'),
  knowledge_type_id uuid NOT NULL,
  role_id uuid NOT NULL,
  minimum_count integer NOT NULL DEFAULT 1 CHECK (minimum_count>0),
  maximum_count integer,
  requires_human boolean NOT NULL DEFAULT true,
  UNIQUE (organization_id,configuration_revision_id,responsibility_requirement_id),
  UNIQUE (organization_id,configuration_revision_id,key),
  FOREIGN KEY (organization_id,configuration_revision_id) REFERENCES governance.configuration_revision(organization_id,configuration_revision_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,knowledge_type_id) REFERENCES catalog.knowledge_type(organization_id,configuration_revision_id,knowledge_type_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,role_id) REFERENCES governance.role(organization_id,configuration_revision_id,role_id) ON DELETE RESTRICT,
  CHECK (maximum_count IS NULL OR maximum_count>=minimum_count),
  UNIQUE (organization_id,configuration_revision_id,knowledge_type_id,role_id)
);

CREATE TABLE catalog.knowledge_template (
  knowledge_template_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL,
  key text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]*$'),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  description text,
  is_enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata)='object'),
  knowledge_type_id uuid NOT NULL,
  domain_id uuid,
  authority_level_id uuid,
  classification_id uuid,
  lifecycle_workflow_id uuid,
  default_metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(default_metadata)='object'),
  content_sections jsonb NOT NULL DEFAULT '[]' CHECK (jsonb_typeof(content_sections)='array'),
  review_requirements jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(review_requirements)='object'),
  UNIQUE (organization_id,configuration_revision_id,knowledge_template_id),
  UNIQUE (organization_id,configuration_revision_id,key),
  FOREIGN KEY (organization_id,configuration_revision_id) REFERENCES governance.configuration_revision(organization_id,configuration_revision_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,knowledge_type_id) REFERENCES catalog.knowledge_type(organization_id,configuration_revision_id,knowledge_type_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,domain_id) REFERENCES catalog.domain(organization_id,configuration_revision_id,domain_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,authority_level_id) REFERENCES governance.authority_level(organization_id,configuration_revision_id,authority_level_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,classification_id) REFERENCES governance.classification(organization_id,configuration_revision_id,classification_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,lifecycle_workflow_id) REFERENCES governance.lifecycle_workflow(organization_id,configuration_revision_id,lifecycle_workflow_id) ON DELETE RESTRICT
);

CREATE TABLE catalog.template_responsibility (
  template_responsibility_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL,
  key text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]*$'),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  description text,
  is_enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata)='object'),
  knowledge_template_id uuid NOT NULL,
  role_id uuid NOT NULL,
  minimum_count integer NOT NULL DEFAULT 1 CHECK (minimum_count>0),
  UNIQUE (organization_id,configuration_revision_id,template_responsibility_id),
  UNIQUE (organization_id,configuration_revision_id,key),
  FOREIGN KEY (organization_id,configuration_revision_id) REFERENCES governance.configuration_revision(organization_id,configuration_revision_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,knowledge_template_id) REFERENCES catalog.knowledge_template(organization_id,configuration_revision_id,knowledge_template_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,role_id) REFERENCES governance.role(organization_id,configuration_revision_id,role_id) ON DELETE RESTRICT,
  UNIQUE (organization_id,configuration_revision_id,knowledge_template_id,role_id)
);

CREATE TABLE catalog.template_field (
  template_field_id uuid PRIMARY KEY,
  organization_id uuid NOT NULL,
  configuration_revision_id uuid NOT NULL,
  key text NOT NULL CHECK (key ~ '^[a-z][a-z0-9_]*$'),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  description text,
  is_enabled boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(metadata)='object'),
  knowledge_template_id uuid NOT NULL,
  custom_field_definition_id uuid NOT NULL,
  is_required boolean NOT NULL DEFAULT true,
  default_value jsonb,
  UNIQUE (organization_id,configuration_revision_id,template_field_id),
  UNIQUE (organization_id,configuration_revision_id,key),
  FOREIGN KEY (organization_id,configuration_revision_id) REFERENCES governance.configuration_revision(organization_id,configuration_revision_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,knowledge_template_id) REFERENCES catalog.knowledge_template(organization_id,configuration_revision_id,knowledge_template_id) ON DELETE RESTRICT,
  FOREIGN KEY (organization_id,configuration_revision_id,custom_field_definition_id) REFERENCES catalog.custom_field_definition(organization_id,configuration_revision_id,custom_field_definition_id) ON DELETE RESTRICT,
  UNIQUE (organization_id,configuration_revision_id,knowledge_template_id,custom_field_definition_id)
);

