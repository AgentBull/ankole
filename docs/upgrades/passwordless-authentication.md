# Passwordless authentication upgrade

Back up PostgreSQL and stop the old control-plane replicas before migration.
Keep the backup until login, tenant membership, and OIDC checks pass.

## Credential conversion

`Ankole.Migrations` runs a read-only credential conflict preflight before it
executes upgrade writes or migrations. The preflight includes active and purely
suspended Humans. It reports a tenant/email owned by different retained Humans,
or multiple account emails for one retained Human. A conflict stops the run.

The core migration creates the credential, ceremony, invitation, disposition,
audit, and browser evidence fields. It converts retained local email bindings,
releases departed contacts, creates Pod administrator scaffolding, and identifies
tenants that need manual administrator assignment. Configuration migration
decrypts with the source key context and encrypts with the destination key
context. Recovery for a completed destructive conversion uses a database backup.

The preflight runs before any migration write. It rejects blank or missing retained login
emails and normalized email conflicts without changing hashes, links, or schema.
It also checks single-tenant password releases before tenant columns exist.
Correct the reported records with the old release and repeat the upgrade.

Browser password proofs are revoked. Their provider, verified email, and
historical authentication method remain available as evidence for offline OIDC
sessions. A session with no proof link is connected only when browser, provider,
subject, and authentication time identify exactly one original proof. Sessions
without that evidence are revoked and require authorization again.

Operators must configure SMTP or a permitted enterprise source before users can
sign in. Use `mix ankole.authn.mail.put PATH` to save validated SMTP settings.
A Pod without a usable administrator can be repaired with
`mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified --tenant SLUG`.
The target Human must be active and have a permitted login credential. The command
requires that no active Pod administrator has a permitted login path. Without
`--tenant`, the command recovers site administration in the privileged tenant.
