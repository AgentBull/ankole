# User runtime

One Ankole digital coworker can serve many people. On each Agent Computer, this Skill uses one Lark CLI profile and one PersonalAgent app for each human sender. The current Turn selects the sender's profile. Never use one sender's profile, approval state, or identity data for another sender.

The profile name is an opaque HMAC-derived value. Do not read, print, change, or guess the Principal UID or profile name.

One Agent Computer keeps every human's profile in one Lark CLI configuration
directory, and that directory lists them. A profile name cannot be derived, but
it can be read there, so separation between senders holds because this Skill
always calls the wrapper. It is not a sandbox boundary. Never call `lark-cli`
directly and never pass `--profile`.

The wrapper removes these bot credential values before it starts Lark CLI:

- app ID and app secret
- tenant and user access tokens
- brand, default identity, and strict-mode overrides
- auth proxy credentials and an inherited profile

This removal is required. Lark CLI gives its environment credential provider priority over stored profiles, so the Agent's bot environment would otherwise ignore the selected user profile. The selected profile supplies both the PersonalAgent app credentials and that app's user token.

The wrapper stores the new app secret through `lark-cli profile add --app-secret-stdin`. It does not ask the user for an app secret, put the secret in a command argument, or print it.

## Preflight and first use

1. Check the profile.

   ```bash
   /repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals profile status
   ```

2. If the result is `not_configured`, start PersonalAgent app registration.

   ```bash
   /repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals profile begin feishu
   ```

   Use `lark` instead of `feishu` only for a Lark tenant. Give the exact `verification_url` to the user and end the Turn. Keep the returned `device_code` in the conversation only.

3. After the user confirms authorization, complete app registration.

   ```bash
   /repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals profile complete '<device_code>'
   ```

   A pending result means that authorization has not reached the provider. Wait for the user; do not start another registration.

4. Before the first approval file upload, the user must approve and publish the `approval:approval` and `approval:instance.file` application scopes for this PersonalAgent app in the Lark developer console. These are app scopes. User OAuth login does not grant them. Do not try to change app permissions automatically.

5. Check user login.

   ```bash
   /repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals auth status --verify
   ```

6. If user identity is unavailable, start approval-scope login.

   ```bash
   /repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals auth begin
   ```

   Give the exact `verification_url` to the user and end the Turn.

7. After the user confirms authorization, complete login.

   ```bash
   /repo/app/library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals auth complete '<device_code>'
   ```

Profile creation, profile preflight, login completion, and logout use a file lock in the shared CLI configuration directory. Profile preflight sets profile strict mode to `off` because one PersonalAgent profile must support both identities. The wrapper pins approval commands to user identity and file upload to the same profile's app identity. Approval reads, file uploads, and approval writes do not take this lock, so different profiles can run in parallel.

If file upload returns `99991672` or `app_scope_not_applied`, give the provider's developer-console scope link to the user and stop. After the user confirms that the app scopes are published, retry only the failed upload. Do not retry a successful upload or a submission with an unknown result.

Do not run account setup for a scheduled, background, system, or otherwise unattended Turn. The wrapper rejects a Turn without an active human sender.
