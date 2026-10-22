# Local Password Identity Provider

The local password identity provider lets people sign in to Ankole with an
email address and a password that Ankole stores itself. It is part of the
control plane, not a Plugin, so setup and the console always list it. It needs
no external service.

Read [Principal](Principal.md) for the shared identity rules.

## Current IDs and Features

| Item | Current value |
| --- | --- |
| Owner module | `Ankole.IdentityProviders.LocalPassword` |
| Plugin declaration | `principals.identity_provider` (built in) |
| Adapter ID | `local` |
| Catalog plugin ID | `control-plane` |
| Configuration key | `principals.identity_providers.local.<id>` |
| Default provider ID | `local-main` |

The adapter declares one capability: `password_login`. It has no OIDC and no
directory sync. Each tenant holds at most one local provider instance:
multiple instances in that tenant would read and write the same credentials, so
`save_provider` rejects a second instance instead of leaving the
retry-protection configuration ambiguous.

IdentityProviders.Config commits each provider configuration and its activation
list entry in one AppConfigure transaction. It merges against the current
PostgreSQL list under its key lock and checks the local-provider limit there,
including disabled instances. A rejected save leaves no new configuration.
Directory sync and realtime reconciliation run after the commit.

LocalPassword can provide the administrator sign-in method in a consumer IM
setup. It has no dependency on Telegram or any other Signal adapter, and it
does not control external identity mapping. An administrator can map a
Telegram account to any existing human Principal, whether that Principal has a
local password or not.

Local credentials and normalized login email belong to their Human's tenant.
Console recovery commands target the privileged tenant because their purpose is
to recover site administrator access. OAuth password verification uses the
Client's tenant, carried by its login transaction.

## Accounts and Credentials

Accounts only come from setup, the console, or the rescue command. There is no
self-service registration and no password recovery page. The email address
is not verified: it is the sign-in name, not evidence that the account holder
controls that mailbox.

The `human_user_local_credentials` table stores one row for each human user
with a local password:

| Column | Purpose |
| --- | --- |
| `principal_uid` | Primary key and foreign key to `human_users` |
| `password_hash` | Argon2id hash in PHC string format |
| `must_change_password` | When true, the next sign-in must set a new password |

Only a human user can hold a local credential; the foreign key enforces this.
`Ankole.Principals` owns the credential rows. `LocalPassword` hashes a new
password before the write transaction and gives the Principals domain only
the hash (`Principals.put_local_credential/3`,
`Principals.complete_forced_password_change/3`).
The kernel owns the Argon2id primitives (`argon2id_hash`, `argon2id_verify`).
The control plane never stores or logs a plain password, and the minimum
length is 6 characters. Local accounts create no
`principal_external_identities` rows; the lowercase email on `human_users` is
the sign-in key. A provider account that reports the same email as a
verified contact, such as a Slack or Google sign-in, resolves to the same
Principal through the usual contact ladder. Mail from that address does not:
the Email adapter matches only `email` identity bindings, so the local account
holder's first mail follows the Email adapter's unmatched-sender policy unless
an explicit binding already exists. `manual_review` holds it for an
administrator; `create_standalone` creates a separate Principal and binds the
address. The local account's email alone does not link that mail to the account.

## Sign-in Flow

`POST /.internal-apis/sessions/local-password` verifies the email and
password. A verified administrator gets the normal admin browser session. A
verified account whose credential carries `must_change_password` gets a
10-minute change ticket instead; `POST
/.internal-apis/sessions/local-password/change` sets the new password and then
opens the session. A missing account and a wrong password return the same
error, and a miss runs one verify against a throwaway hash so response time
does not reveal whether the account exists.

The change ticket carries the verified credential's `updated_at` value as a
scalar version. Completion locks the credential row and requires that version
and `must_change_password` to still match. A password reset changes the version,
so it invalidates earlier tickets and keeps the new one-time password in force.

Console-created accounts and password resets produce a generated 16-character
one-time password from an alphabet without look-alike characters. The console
shows it once. The setup administrator picks their own password and is not
forced to change it.

## Retry Protection

When `retry_protection.enabled` is true (the default), one normalized email
key gets at most five password attempts inside a sliding 30-minute window.
The guard reserves each attempt before the hash verification runs, in one
serialized call, so concurrent requests cannot pass the limit together and
verify without bound. A successful sign-in releases the account's attempts,
so only failures accumulate. A blocked attempt waits until the oldest counted
attempt leaves the window.

A password reset ends that email key's wait at once: attempts recorded before
the credential row's `updated_at` do not count, because guesses against a
replaced password prove nothing about the new one. The `updated_at` fact is
durable, so a rescue reset from another OS process also unlocks the account.
The guard and credential timestamps use the OS clock. The VM
system clock can differ from the OS clock during clock correction. The guard
compares credential and attempt times in microseconds. An attempt
at the credential timestamp still counts; only an earlier attempt is removed.

A capacity lock applies only to that tenant. The tenant can hold at most
10,000 fixed-size email hashes; its next new key waits until an admitted key
expires. Unexpired histories are not evicted. Other tenants retain their own
10,000 keys and are not subject to that tenant's capacity lock. A sweep once
per window removes old entries. Memory grows with the number of configured
tenants.

The node also limits actual Argon2 verification work, including the throwaway
hash for an unknown email. The global AppConfigure key
`principals.local_password.max_verifications` defaults to 2 and accepts a
positive integer. Restart the control plane after changing it. Each current
Argon2id hash uses `m=19456,t=2,p=1` (19 MiB of algorithm memory per verify).
The concurrency limit also applies when retry protection is disabled.

Each tenant can queue two sign-ins for up to one second. Tenants receive free
permits in round-robin order. A full or expired queue returns HTTP 429 with
`retry_busy`, `retryAfterSeconds: 1`, and `Retry-After: 1`. A busy request does
not reserve an account attempt. The five-attempt lock returns `retry_locked`
and the remaining wait in seconds. Shared CPU can still increase waits for
all tenants; this queue does not provide separate compute resources.

A supervised verifier keeps its permit if the HTTP caller exits. During a
guard restart, its supervisor sends a trapped shutdown and waits for all
verifications to return before creating a new guard. A dirty NIF can continue
after an untrapped process exit, so a process monitor alone cannot establish
that native work stopped. There is no API to force-kill verification tasks.

The counter lives in process memory (`LocalPassword.RetryGuard`). A restart
clears the counters and can allow another burst of attempts, but it cannot
lose an account or a credential. Successful sign-in also clears the history,
so the key limit does not bound total verification work per time window. The
node's separate concurrency limit bounds the number of running verifications.
This keeps the sign-in path free of counter writes to PostgreSQL.

## Rescue

`mix ankole.local_password.reset <email>` (development), `bun kit
local-password reset <email>` (devkit wrapper), and
`Ankole.Release.reset_local_password/1` (production release) replace the
password for one email with a new one-time password and print it. The command
warns when no enabled local provider exists, because sign-in stays closed
until an operator enables one.
