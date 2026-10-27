# Passwordless authentication upgrade

Before running the migration, back up PostgreSQL and stop all old control-plane replicas. Keep that backup until login, tenant membership, and OIDC checks all pass on the upgraded release.

## Credential conversion

Before executing any upgrade writes or schema migrations, `Ankole.Migrations` runs a read-only preflight check for credential conflicts across both active and suspended Humans. If two retained Humans share the same tenant and email address, or if a single retained Human has multiple account emails, the preflight reports the conflict and halts the upgrade without touching hashes, links, or schema. It also validates single-tenant password releases before tenant columns exist, and rejects blank or missing login emails on retained accounts. If preflight stops the run, fix the reported records using the previous release and rerun the upgrade.

Once preflight passes, the migration creates the passwordless credential, ceremony, invitation, disposition, audit, and browser-evidence tables and columns. It converts retained local email bindings, releases departed contacts, sets up Pod administrator scaffolding, and flags any tenant that requires manual administrator assignment. During configuration migration, Ankole decrypts existing secrets under the source key context and re-encrypts them under the destination key context. Because this conversion is destructive once committed, rolling back requires restoring from your PostgreSQL backup.

The upgrade revokes legacy browser password proofs, while retaining their provider, verified email, and historical authentication method as evidence for existing offline OIDC sessions. If an offline session lacks a direct proof link, the migration links it only when the browser, provider, subject, and authentication timestamp uniquely match a single historical proof; any session without an unambiguous match is revoked and must re-authenticate.

Before users can sign in again, configure either SMTP or an allowed enterprise identity source. To store validated SMTP settings from the command line, run `mix ankole.authn.mail.put PATH`. If a Pod ends up without a usable administrator, recover access with:

```sh
mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified --tenant SLUG
```

The target Human must be active and hold a permitted login credential, and the command runs only when no active Pod administrator currently has a working login path. Omitting `--tenant` recovers site administration in the privileged tenant instead.
