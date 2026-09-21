# KC-005 — SOP draft, evidence, review, publication and revision

This milestone implements the requested vertical slice in PostgreSQL and a Python/CLI client. It does not create a production SOP or simulate a real person's approval. Automated tests use synthetic source material and separate test author/reviewer identities.

## Demonstrated outcome

| Step | Result |
|---|---|
| Create SOP-001 | Version 1 is a draft with title, content, type, domain, authority/classification and review-date metadata |
| Attach evidence | Citation points to a specific immutable artifact version, with locator and evidence note |
| Assign responsibilities | Owner and approver are explicit human principals; business roles do not grant workspace privileges |
| Submit | Required metadata, evidence and responsibilities are checked; content/evidence/responsibilities are frozen and hashed |
| Review | A separately authorized human who did not contribute content approves the exact snapshot and records a note |
| Publish | Version 1 becomes immutable and the item points to it as its current published version |
| Revise | Version 2 is a new draft with copied content, citations and responsibilities, new IDs, and no inherited approvals |
| Edit version 2 | Version 1, its citations, source contents, review and publication history remain unchanged |

The test SOP is “Request review SOP.” Version 1 says to verify a request, record approval and retain evidence. Version 2 adds an explicit owner-confirmation step. Its controlled test source contains all three instructions. This is demonstration content, not organizational policy.

## Files and data

- V010 adds knowledge items, versions, citations, responsibilities, reviews, source/artifact versions and explicit workspace/source entitlements.
- V011 adds the parameterized workflow command, snapshot digest, metadata/responsibility checks and approval counting.
- V012 tracks every content contributor to prevent co-author self-approval and pins review/responsibility references to the version's configuration.
- `packages/kc/knowledge.py` supplies application-generated UUIDv7 IDs and Python operations.
- `packages/kc/knowledge_cli.py` supplies explicit commands for each stage.
- `tests/test_sop_workflow.py` exercises the complete sequence and negative security/history cases on real PostgreSQL.

Publication states (`DRAFT`, `IN_REVIEW`, `APPROVED`, `PUBLISHED`) track the version's editing/publication contract. Lifecycle state IDs and allowed transitions come from the tenant's pinned configuration revision. The General Business starter supports `submit_for_review`, `approve`, `publish`, and `return_to_draft`. Other configurations must supply corresponding valid transitions; transition keys can be passed explicitly. Unsupported transition conditions fail closed.

## Setup and authorization

Apply migrations with `python -m kc.migrate`. Import and explicitly activate the General Business configuration through the existing authorized-human workflow. Resolve its SOP type, domain and role IDs. The current revision must be effective when creating, submitting or publishing knowledge.

A trusted provisioner grants direct principal entitlements in `security.workspace_access` and ingests records into `source.knowledge_source`, `source.source_artifact` and `source.artifact_version`. It materializes source permission decisions into `security.source_acl`, with a required validity deadline. Runtime editors cannot grant themselves source access or create authoritative source evidence. This milestone uses normalized direct-principal grants; connector-driven group/deny resolution remains the trusted provisioner's responsibility.

The author needs workspace `can_edit`. The reviewer needs workspace `can_review`, an assigned configured approval role and current access to every cited source. The review/publish connection must belong to `kc_human_approver`, while ordinary editing can use `kc_application`. Both use the existing authenticated ticket mechanism. No content contributor can approve the version, even if they hold the role and workspace permission. Approval counts recheck reviewer account/membership, workspace permission and source ACL freshness before publication.

Source access fails closed when absent, denied, expired or revoked. Reading a knowledge item and its versions conservatively requires access to all sources cited anywhere in its version history. Thus an inaccessible historical or draft source can hide the entire item, even if the current published version cites another source. This deliberately restrictive first implementation avoids deriving access from workspace visibility alone. Audit events expose action/opaque IDs, not SOP content, source text or review notes.

## Command-line walkthrough

Set `KC_RUNTIME_DSN` and `KC_SESSION_TICKET` securely for the appropriate authenticated actor. Do not put tickets in files or commands. The examples below use placeholder IDs; resolve actual IDs from your tenant. They are not an instruction to share identities between humans.

Create `sop.json` with these fields:

```json
{
  "workspace_id": "WORKSPACE_UUID",
  "configuration_revision_id": "CONFIGURATION_UUID",
  "knowledge_type_id": "SOP_TYPE_UUID",
  "domain_id": "DOMAIN_UUID",
  "knowledge_key": "SOP-001",
  "title": "Request review SOP",
  "content": "1. Verify the request.\n2. Record approval and retain evidence.",
  "metadata": {"review_date": "2027-09-17"}
}
```

As the author:

```sh
python -m kc.knowledge_cli create sop.json
python -m kc.knowledge_cli attach VERSION_1_UUID ARTIFACT_VERSION_UUID --locator "Full procedure" --note "Controlled source supports these steps"
python -m kc.knowledge_cli assign VERSION_1_UUID OWNER_ROLE_UUID AUTHOR_PRINCIPAL_UUID
python -m kc.knowledge_cli assign VERSION_1_UUID APPROVER_ROLE_UUID REVIEWER_PRINCIPAL_UUID
python -m kc.knowledge_cli submit VERSION_1_UUID
```

Using the independent reviewer's authenticated approval connection:

```sh
python -m kc.knowledge_cli show VERSION_1_UUID
python -m kc.knowledge_cli review VERSION_1_UUID --note "Verified the procedure against its cited source"
python -m kc.knowledge_cli publish VERSION_1_UUID
```

Back on the author's connection:

```sh
python -m kc.knowledge_cli revise VERSION_1_UUID
# Save {"content":"1. Verify the request.\n2. Confirm the owner.\n3. Record approval and retain evidence."} as revision.json.
python -m kc.knowledge_cli edit VERSION_2_UUID revision.json
python -m kc.knowledge_cli show VERSION_1_UUID
python -m kc.knowledge_cli show VERSION_2_UUID
```

The item still points to published version 1. Version 2 must repeat submission/review/publication before that pointer changes. Only one open draft/review version per item is allowed. Returning an in-review version to draft requires a configured return transition, increments the review round, and invalidates the previous snapshot; historical review rows are retained.

## Current limits

This milestone introduced the backend/CLI slice. The [local browser workspace](sop-ui.md) now exposes that workflow. Source connectors, search indexing and generative retrieval remain separate work. It does not activate AI eligibility, export content to a model, or implement a complete classification-policy engine. Provisioners must apply classification and source restrictions when assigning entitlements. There is no content deletion/purge endpoint.

The database validates required/unknown metadata and basic TEXT, RICHTEXT, NUMBER, BOOLEAN, DATE and CHOICE values. Supplied values requiring unsupported field evaluators, nonempty validation-schema/conditional/calculation rules, or workflow conditions block submission/publication rather than being silently ignored. Multi-domain assignment, templates as creation inputs, reference/calculated fields, complex workflows, connectors, evidence replacement and workspace sharing remain subsequent work. Draft creation requires explicit IDs; authority/classification defaults come from the configured knowledge type.

Existing migrations V001–V009 remain unchanged. The previous foundation's GitHub Actions run was successful before this work began. The workflow was presented for review, and the user authorized committing and pushing these changes.

## Verification

On September 17, 2026, the complete real-PostgreSQL suite passed **42 tests in 54.49 seconds**: the 28 foundation tests plus 14 SOP tests. The SOP suite includes the complete CLI sequence, preservation of version 1 after editing version 2, frozen review inputs, contributor/self-approval rejection, missing metadata/evidence/responsibilities, revoked reviewer/source access, tenant/AI isolation, and rejection of a second open draft. CLI help and `git diff --check` also passed. The previous foundation [GitHub Actions run](https://github.com/G8StNik/knowledge-catalog/actions/runs/35239335220) succeeded. These are local verification results; the workflow's GitHub CI result is reported separately after pushing.
