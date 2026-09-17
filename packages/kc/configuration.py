"""Portable configuration packages. Import creates a draft; activation is always explicit."""
from copy import deepcopy
import json

from jsonschema import Draft202012Validator
from psycopg import sql
from psycopg.types.json import Jsonb

from kc.ids import uuid7

# Ordered by FK dependency. References in packages use stable keys, never database IDs.
TABLES = {
    'catalog.domain': ('parent_domain_id workspace_id sort_order', {'parent_domain_id':'catalog.domain','workspace_id':'core.workspace'}),
    'catalog.taxonomy': ('', {}),
    'catalog.taxonomy_term': ('taxonomy_id parent_term_id sort_order', {'taxonomy_id':'catalog.taxonomy','parent_term_id':'catalog.taxonomy_term'}),
    'catalog.term_alias': ('taxonomy_term_id alias language alias_kind', {'taxonomy_term_id':'catalog.taxonomy_term'}),
    'governance.authority_level': ('trust_rank requires_evidence requires_human_approval', {}),
    'governance.classification': ('sensitivity_rank is_ai_eligible is_external_ai_allowed handling_rules', {}),
    'governance.role': ('allowed_principal_types', {}),
    'governance.lifecycle_workflow': ('', {}),
    'governance.lifecycle_state': ('lifecycle_workflow_id is_initial is_terminal is_published', {'lifecycle_workflow_id':'governance.lifecycle_workflow'}),
    'governance.lifecycle_transition': ('lifecycle_workflow_id from_state_id to_state_id approval_role_id minimum_approvals requires_human_approval conditions',
        {'lifecycle_workflow_id':'governance.lifecycle_workflow','from_state_id':'governance.lifecycle_state','to_state_id':'governance.lifecycle_state','approval_role_id':'governance.role'}),
    'catalog.knowledge_type': ('default_authority_level_id default_classification_id lifecycle_workflow_id is_ai_eligible_default requires_approval',
        {'default_authority_level_id':'governance.authority_level','default_classification_id':'governance.classification','lifecycle_workflow_id':'governance.lifecycle_workflow'}),
    'catalog.custom_field_definition': ('data_type is_required is_searchable is_filterable is_ai_visible validation_schema conditional_rules calculation reference_target_type default_value', {}),
    'catalog.custom_field_choice': ('custom_field_definition_id value sort_order', {'custom_field_definition_id':'catalog.custom_field_definition'}),
    'catalog.knowledge_type_field': ('knowledge_type_id custom_field_definition_id is_required sort_order', {'knowledge_type_id':'catalog.knowledge_type','custom_field_definition_id':'catalog.custom_field_definition'}),
    'catalog.relationship_type': ('forward_label reverse_label is_symmetric allows_self_reference requires_evidence', {}),
    'catalog.relationship_type_restriction': ('relationship_type_id source_knowledge_type_id target_knowledge_type_id',
        {'relationship_type_id':'catalog.relationship_type','source_knowledge_type_id':'catalog.knowledge_type','target_knowledge_type_id':'catalog.knowledge_type'}),
    'governance.responsibility_requirement': ('knowledge_type_id role_id minimum_count maximum_count requires_human', {'knowledge_type_id':'catalog.knowledge_type','role_id':'governance.role'}),
    'catalog.knowledge_template': ('knowledge_type_id domain_id authority_level_id classification_id lifecycle_workflow_id default_metadata content_sections review_requirements',
        {'knowledge_type_id':'catalog.knowledge_type','domain_id':'catalog.domain','authority_level_id':'governance.authority_level','classification_id':'governance.classification','lifecycle_workflow_id':'governance.lifecycle_workflow'}),
    'catalog.template_responsibility': ('knowledge_template_id role_id minimum_count', {'knowledge_template_id':'catalog.knowledge_template','role_id':'governance.role'}),
    'catalog.template_field': ('knowledge_template_id custom_field_definition_id is_required default_value', {'knowledge_template_id':'catalog.knowledge_template','custom_field_definition_id':'catalog.custom_field_definition'}),
}
COMMON = 'key display_name description is_enabled metadata'.split()
JSON_FIELDS = set('metadata handling_rules conditions validation_schema conditional_rules calculation default_value default_metadata content_sections review_requirements'.split())
INTEGER_FIELDS = set('sort_order trust_rank sensitivity_rank minimum_approvals minimum_count maximum_count'.split())
REQUIRED = {
    'catalog.taxonomy_term':['taxonomy_key'], 'catalog.term_alias':['taxonomy_term_key','alias','alias_kind'],
    'governance.authority_level':['trust_rank'], 'governance.classification':['sensitivity_rank'],
    'governance.lifecycle_state':['lifecycle_workflow_key'],
    'governance.lifecycle_transition':['lifecycle_workflow_key','from_state_key','to_state_key'],
    'catalog.custom_field_definition':['data_type'],
    'catalog.custom_field_choice':['custom_field_definition_key','value'],
    'catalog.knowledge_type_field':['knowledge_type_key','custom_field_definition_key'],
    'catalog.relationship_type':['forward_label','reverse_label'],
    'catalog.relationship_type_restriction':['relationship_type_key','source_knowledge_type_key','target_knowledge_type_key'],
    'governance.responsibility_requirement':['knowledge_type_key','role_key'],
    'catalog.knowledge_template':['knowledge_type_key'],
    'catalog.template_responsibility':['knowledge_template_key','role_key'],
    'catalog.template_field':['knowledge_template_key','custom_field_definition_key'],
}


def package_schema():
    entities = {}
    for table, (fields, refs) in TABLES.items():
        properties = {}
        for field in COMMON + fields.split():
            name = field[:-3] + '_key' if field in refs else field
            if field == 'default_value':
                definition = {}
            elif field in JSON_FIELDS:
                definition = {'type':'array' if field == 'content_sections' else 'object'}
            elif field == 'allowed_principal_types':
                definition = {'type':'array','minItems':1,'uniqueItems':True,'items':{'enum':['USER','GROUP','SERVICE','AI_AGENT']}}
            elif field in INTEGER_FIELDS:
                definition = {'type':'integer'}
            elif field.startswith(('is_','requires_','allows_')):
                definition = {'type':'boolean'}
            else:
                definition = {'type':'string'}
            properties[name] = definition
        properties['key'] = {'type':'string','pattern':'^[a-z][a-z0-9_]*$','maxLength':100}
        properties['display_name'] = {'type':'string','minLength':1,'maxLength':500}
        entities[table] = {'type':'array','maxItems':10000,'items':{'type':'object','additionalProperties':False,
            'required':['key','display_name']+REQUIRED.get(table,[]),'properties':properties}}
    return {'$schema':'https://json-schema.org/draft/2020-12/schema','type':'object','additionalProperties':False,
            'required':['format_version','package_key','version','entities'],
            'properties':{'format_version':{'const':1},'package_key':{'type':'string','pattern':'^[a-z][a-z0-9_]*$'},
                          'version':{'type':'integer','minimum':1},'description':{'type':'string'},
                          'entities':{'type':'object','additionalProperties':False,'properties':entities}}}


def validate_package(package):
    if len(json.dumps(package).encode()) > 1_048_576:
        raise ValueError('Package exceeds 1 MiB limit')
    Draft202012Validator(package_schema()).validate(package)
    entities = package['entities']
    keys = {table:{row['key'] for row in entities.get(table,[])} for table in TABLES}
    for table, (_, refs) in TABLES.items():
        rows = entities.get(table,[])
        if len(rows) != len(keys[table]):
            raise ValueError(f'Duplicate key in {table}')
        for row in rows:
            for column,target in refs.items():
                field = column[:-3]+'_key'
                if field in row and target != 'core.workspace' and row[field] not in keys[target]:
                    raise ValueError(f'Unresolved reference: {table}.{field}={row[field]}')
            if table=='catalog.custom_field_definition':
                schema = row.get('validation_schema',{})
                Draft202012Validator.check_schema(schema)
                # Never resolve network/local-file references from an imported schema.
                def check_refs(value):
                    if isinstance(value,dict):
                        if '$ref' in value and not value['$ref'].startswith('#'):
                            raise ValueError('Only local JSON Schema references are supported')
                        for nested in value.values(): check_refs(nested)
                    elif isinstance(value,list):
                        for nested in value: check_refs(nested)
                check_refs(schema)
    return package


def import_package(conn, package, source_proposal_id=None):
    """Create one complete draft atomically. Caller must establish a human ticket context."""
    package = validate_package(deepcopy(package))
    revision = uuid7()
    with conn.transaction():
        tenant = conn.execute('SELECT security.current_organization()').fetchone()[0]
        conn.execute('SELECT governance.create_revision(%s,%s,%s,%s,%s)',
                     (revision,package['package_key'],package['version'],package.get('description',''),source_proposal_id))
        ids = {t:{r['key']:uuid7() for r in package['entities'].get(t,[])} for t in TABLES}
        ids['core.workspace'] = dict(conn.execute('SELECT workspace_key::text,workspace_id FROM core.workspace'))
        for table,(_,refs) in TABLES.items():
            pending = list(package['entities'].get(table,[]))
            written = set()
            while pending:
                eligible = [row for row in pending if all(target!=table or col[:-3]+'_key' not in row or
                            row[col[:-3]+'_key'] in written for col,target in refs.items())]
                if not eligible:
                    raise ValueError(f'Hierarchy cycle in {table}')
                for row in eligible:
                    values = {table.split('.')[1]+'_id':ids[table][row['key']],
                              'organization_id':tenant,'configuration_revision_id':revision}
                    for name,value in row.items():
                        column = name[:-4]+'_id' if name.endswith('_key') and name[:-4]+'_id' in refs else name
                        if column in refs:
                            try: value=ids[refs[column]][value]
                            except KeyError: raise ValueError(f'Unresolved reference {name}={value}') from None
                        values[column]=Jsonb(value) if column in JSON_FIELDS else value
                    conn.execute("SELECT set_config('kc.change_event_id',%s,true)",(str(uuid7()),))
                    conn.execute(sql.SQL('INSERT INTO {} ({}) VALUES ({})').format(sql.Identifier(*table.split('.')),
                        sql.SQL(',').join(map(sql.Identifier,values)),sql.SQL(',').join(sql.Placeholder()*len(values))),list(values.values()))
                    written.add(row['key']); pending.remove(row)
    return revision


def export_package(conn, revision):
    """Strip tenant IDs, principal IDs, approvals and audit data. Resolve references by key."""
    record=conn.execute('SELECT package_key,version,description FROM governance.configuration_revision WHERE configuration_revision_id=%s',(revision,)).fetchone()
    if record is None: raise ValueError('Revision not found in current tenant')
    entities={}; key_by_id={}
    for table in TABLES:
        rows=conn.execute(sql.SQL('SELECT to_jsonb(t) FROM {} t WHERE configuration_revision_id=%s ORDER BY key').format(sql.Identifier(*table.split('.'))),(revision,)).fetchall()
        entities[table]=[r[0] for r in rows]
        key_by_id[table]={r[table.split('.')[1]+'_id']:r['key'] for r in entities[table]}
    key_by_id['core.workspace']={str(i):k for i,k in conn.execute('SELECT workspace_id,workspace_key::text FROM core.workspace')}
    for table,(fields,refs) in TABLES.items():
        exported=[]
        for row in entities[table]:
            item={}
            for column in COMMON+fields.split():
                if row[column] is None: continue
                if column in refs:
                    item[column[:-3]+'_key']=key_by_id[refs[column]][row[column]]
                else: item[column]=row[column]
            exported.append(item)
        entities[table]=exported
    return validate_package({'format_version':1,'package_key':record[0],'version':record[1],
                             'description':record[2] or '', 'entities':entities})
