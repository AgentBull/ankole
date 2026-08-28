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
directory sync. One installation holds at most one local provider instance:
all instances would read and write the same credential table, so
`save_provider` rejects a second instance instead of leaving the
retry-protection configuration ambiguous.

LocalPassword can provide the administrator sign-in method in a consumer IM
setup. It has no dependency on Telegram or any other Signal adapter, and it
does not control external identity mapping. An administrator can map a
Telegram account to any existing human Principal, whether that Principal has a
local password or not.

## Accounts and Credentials

Accounts only come from setup, the console, or the rescue command. There is no
self-service registration and no password recovery page. Email addresses are
trusted without verification because only an operator can create them.

The `human_user_local_credentials` table stores one row for each human user
with a local password:

| Column | Purpose |
| --- | --- |
| `principal_uid` | Primary key and foreign key to `human_users` |
| `password_hash` | Argon2id hash in PHC string format |
| `must_change_password` | When true, the next sign-in must set a new password |

Only a human user can hold a local credential; the foreign key enforces this.
The kernel owns the Argon2id primitives (`argon2id_hash`, `argon2id_verify`).
The control plane never stores or logs a plain password, and the minimum
length is 6 characters. Local accounts create no
`principal_external_identities` rows; the lowercase email on `human_users` is
the sign-in key. A local account and a provider account with the same email
therefore resolve to the same Principal through the usual contact ladder.

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
A guard-wide saturation lock still applies to every email until one admitted
key expires, so saturation cannot reveal whether the reset account exists.

The counter lives in process memory (`LocalPassword.RetryGuard`) and stores
only fixed-size hashes for at most 10,000 email keys. The next new key locks
all email keys until one admitted key expires. A sweep once per window drops
aged-out entries. This fail-closed bound prevents an unknown-email spray from
growing memory or Argon2 work without limit, while the common lock response
does not expose whether an email exists. A control-plane restart clears the
counters and can let one extra burst of attempts through, but it cannot lose
an account or a credential. This trade keeps the sign-in path free of write
amplification.

## Rescue

`mix ankole.local_password.reset <email>` (development), `bun kit
local-password reset <email>` (devkit wrapper), and
`Ankole.Release.reset_local_password/1` (production release) replace the
password for one email with a new one-time password and print it. The command
warns when no enabled local provider exists, because sign-in stays closed
until an operator enables one.
