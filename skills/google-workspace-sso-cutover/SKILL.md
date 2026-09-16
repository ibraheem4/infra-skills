---
name: google-workspace-sso-cutover
description: Safely migrate a SaaS application from Microsoft Entra or another workforce identity provider to Google Workspace SAML/OIDC, including inventory, group-scoped assignment, provisioning, dual-login verification, rollback, and deactivation. Use when configuring or troubleshooting Google SSO, SCIM provisioning, app assignment, or an IdP cutover.
---

# Google Workspace SSO cutover

Treat identity cutover as a reversible control change. Read `references/cutover-checklist.md`, verify current vendor documentation, and never infer production settings from a similarly named catalog app.

## Workflow

1. Inventory the current IdP application, users/groups, protocol, identifiers, certificates, provisioning, role mapping, recovery path, and dependent automation. Record secrets only in an approved secret store.
2. Confirm a second tested super-admin or break-glass path before changing the primary login route.
3. Configure Google with the service provider's exact current ACS URL, entity/audience ID, start URL, NameID, and required attributes. Keep application access off until configuration is complete.
4. Prefer an invite-only Google security/access group over whole-domain assignment. Do not allow external members unless a documented use case requires them.
5. Configure provisioning separately from authentication. Verify create/update/suspend behavior and remember that provisioning a user does not necessarily assign product roles, cloud accounts, or permission sets.
6. Enable the app for the test group, then test service-provider-initiated login in a private browser with two identities. Use the vendor's access portal when its Google “Test SAML login” path is not a valid SP-initiated flow.
7. Verify authorization after authentication: organization, account, role, permission set, and audit event. A successful SAML assertion alone is not acceptance.
8. Export configuration and evidence, then disable the old IdP integration. Do not delete it until the rollback window closes and logs show no residual use.
9. Update the system inventory, Evidence Plane scope, recovery runbook, and deprovisioning record.

## Safety rules

- Never paste private keys, client secrets, access tokens, recovery codes, or complete metadata containing secrets into source control or chat.
- Do not remove the last working administrator or root/break-glass path.
- Separate workforce identity from product-user identity.
- Do not represent provider certifications or a successful SSO setup as organizational compliance.
- Pause before any destructive deactivation if the replacement path has not passed two-user authorization testing.

## Output

Produce a concise cutover record: application, old/new IdP, assignment scope, authentication and provisioning state, tests performed, authorization result, rollback deadline, evidence location, residual dependencies, and next action.
