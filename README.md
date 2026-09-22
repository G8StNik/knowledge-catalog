# knowledge-catalog
A governed enterprise knowledge platform that captures, organizes, connects, secures, and retrieves organizational knowledge for people and AI agents using trusted sources, metadata, relationships, provenance, and permission-aware retrieval.

Knowledge Catalog transforms scattered organizational knowledge—documents, policies, SOPs, meetings, data definitions, reports, tickets, systems, and SME expertise—into a governed, continuously maintained knowledge layer that can be securely used by employees, applications, and AI agents.

Unlike a traditional document repository or RAG chatbot, Knowledge Catalog maintains provenance, ownership, authority, lifecycle, relationships, security classification, and AI-use eligibility for organizational knowledge. It provides permission-aware retrieval with source citations while using unanswered questions, stale content, conflicts, and user feedback to continuously identify and close knowledge gaps.

## Foundation: KC-001 through KC-004

This monorepo contains the company-agnostic architecture and physical model, plus an executable PostgreSQL tenant/identity foundation and governed configuration schema. KC-005 adds the SOP publication workflow described below. The product description above describes the target platform; connectors, search and generative retrieval remain later modules. A local SOP browser workspace is now available.

- [Architecture and product boundaries](docs/architecture.md)
- [Multi-tenant physical model](docs/physical-model.md)
- [Database setup, migrations, roles and configuration workflow](database/README.md)
- [Architecture decisions](docs/adr/001-platform-boundaries.md)
- [Implementation review and verification](docs/implementation-review.md)

The foundation uses shared-database OrganizationID isolation, forced row-level security, tenant-aware foreign keys, application-generated UUIDv7 IDs, and relational plus JSONB configuration. It supports separate human, group, service and AI principals. Governed configuration covers domains, taxonomies, aliases, knowledge types, custom fields, relationships, authority, classification, workflows, responsibilities and reusable templates.

Configuration imports create drafts. Approval freezes a revision and schedules its effective interval. AI has proposal-only access; activation requires a separate human approval connection and an authorized human identity. Source permission preservation and provider independence remain architectural requirements for subsequent modules.

For local setup, copy `.env.example` to `.env`, set a random development password, and run:

```sh
docker compose up -d postgres
docker compose run --rm migrate
docker compose --profile test run --rm test
```

See the database guide for native PostgreSQL setup, optional demo tenants, and configuration package import/export.

## KC-005: SOP workflow

The [SOP walkthrough](docs/sop-workflow.md) now implements creating a draft, attaching immutable source evidence, independent human review, publishing version 1, and creating version 2 without modifying published history. It includes workspace/source access checks, a command-line client and integration tests. See the walkthrough for the supported scope and remaining production integrations.

## SOP browser workspace

The [browser workspace guide](docs/sop-ui.md) covers drafting procedures, uploading and attaching source evidence, assigning responsibilities, independent review, publication and version history. The [Source Library](docs/source-uploads.md) lets readers search documents, inspect versions and citations, and lets authorized workspace editors manage source access. Uploaded PDF, text and Markdown evidence retains the original file and extracted searchable text as an immutable version. Normal sign-in now uses Auth0 with required MFA; follow the [Auth0 setup guide](docs/auth0-setup.md) to configure Microsoft, Google and email connections and link approved users. The app remains local-only; shared production hosting is separate work. Development ticket login requires the explicit `--dev-ticket-login` option.

[Organization onboarding and invitations](docs/organization-onboarding.md) add an administrator-led first organization setup and one-time codes for new members. Invitation acceptance requires Auth0 MFA and a verified email matching the invitation.
