# ADR-004: Immutable configuration snapshots and human activation

Status: accepted principle; package-wide snapshots are an implementation refinement for review.

A package revision is a complete set of vocabulary, metadata, governance and template definitions. References resolve inside that revision. Stable keys support portable import; UUIDs support internal integrity. Approval freezes the entire snapshot and stores a SHA-256 digest plus an audit snapshot. Effective intervals cannot overlap for one organization/package. Applications must choose a package namespace explicitly.

This favors reproducibility over fine-grained per-entity versioning. A small field change requires a successor snapshot, but historical knowledge can reference an unambiguous configuration version. References across package namespaces are deliberately unsupported in format v1; compose starter configurations into one package when they need shared references.

AI proposals remain separate, immutable input. Human reviewers may modify a linked draft, then explicitly approve its exact content. Database permissions and current human administrative authorization control both edits and activation. Business responsibility roles do not grant this administrative permission.

The package format excludes platform tenant IDs, user assignments, credentials, ACL grants and approval state. Free-text and JSON defaults/metadata require organizational review before export; the exporter is not a secret detector. Imports always create drafts, never execute SQL or activate. Future dependency resolution, patch packages and schema migration of existing knowledge values require new package format/ADRs.

Conditional/calculated enterprise fields are defined as data now; their runtime evaluation is deferred. Source ACLs and classification handling must constrain future field/reference access, independently of display/search/AI flags.
