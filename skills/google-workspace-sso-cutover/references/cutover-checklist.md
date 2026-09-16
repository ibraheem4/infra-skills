# Cutover checklist

## Before

- [ ] Current app/export captured
- [ ] Protocol and exact SP identifiers confirmed
- [ ] Two administrative identities tested
- [ ] Root or break-glass recovery tested
- [ ] Target Google access group created; invite-only; external members off
- [ ] Rollback owner and window recorded

## Configure

- [ ] ACS URL and entity/audience copied from the target tenant
- [ ] Start URL uses the target organization/account slug
- [ ] NameID and required attributes match vendor documentation
- [ ] Provisioning configured independently, if supported and licensed
- [ ] Application enabled only for the target group

## Verify

- [ ] SP-initiated private-browser login works for identity A
- [ ] SP-initiated private-browser login works for identity B
- [ ] Both identities reach the intended organization/account
- [ ] Roles or permission sets are assigned and least-privilege
- [ ] Sign-in and administrative audit events exist
- [ ] Deprovision/suspend behavior is understood

## Cut over

- [ ] Old IdP assignment disabled, not deleted
- [ ] Residual usage monitored through rollback window
- [ ] Recovery, inventory, and evidence documentation updated
- [ ] Old integration deleted only after explicit approval

## Known diagnostic distinctions

- `app_not_configured_for_user` or `app_not_enabled_for_user`: check Google app assignment, group membership propagation, and the selected Workspace account before changing SAML fields.
- Authentication succeeds but no cloud accounts appear: assign the downstream account/role/permission set; SCIM-created identity is not authorization.
- AWS Google test produces an invalid request ID while access-portal login succeeds: use the AWS access portal as the acceptance path and retain the successful authentication audit event.
- Digest mismatch: re-check the exact tenant or enterprise slug, ACS/audience pair, and metadata/certificate currently active at the service provider.
