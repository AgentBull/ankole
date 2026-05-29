# Setup

Setup bootstraps a usable local BullX installation. It composes existing
subsystem facades; durable facts remain in Config, Principals, AuthZ, LLM
providers, plugin source config, AIAgent, and MailBox.

The implementation lives under `BullX.Setup.*` and Phoenix controllers under
`BullXWeb`.

## Steps

`BullX.Setup.steps/0` returns:

1. `plugins`
2. `llm_providers`
3. `channel_sources`
4. `ai_agents`
5. `event_routing`
6. `activate_admin`

`BullX.Setup.Projection.state_for_session/1` computes the current state and
clamps the requested step to the earliest incomplete step.

If `BullX.Principals.setup_required?/0` is false, setup is complete. Otherwise
the wizard requires a valid setup session created from the current bootstrap
activation code.

## Session

`GET /setup/sessions/new` creates or refreshes the process-local bootstrap
activation code when setup is still required and renders the setup session page.

`POST /setup/sessions` normalizes the submitted code, verifies it with
`BullX.Principals.verify_bootstrap_activation_code_for_setup/1`, stores the code
hash and plaintext command material in the encrypted session, applies the
selected locale, renews the session, and redirects to the first setup step.

The bootstrap activation code is not stored in PostgreSQL.

## Plugins

`BullX.Setup.Plugins` compares runtime enabled plugin ids with the persisted
plugin config. A pending restart state is possible when the saved ids differ
from the running plugin registry.

Setup-capable IM adapters come from enabled channel adapter extensions with
source setup modules.

## LLM Providers

`BullX.Setup.LLMProviders` stores provider rows through
`BullX.LLM.Writer.put_provider/1`.

Blank API keys for existing providers keep the existing key in the setup save
path. Connectivity checks validate the req_llm provider and may ping the chosen
test model.

Setup considers the LLM provider step complete when at least one provider row is
stored.

## Channel Sources

`BullX.Setup.ChannelSources` discovers enabled IM channel adapter setup modules.
Each setup module owns its public config projection, validation, optional
connectivity check, persistence, and runtime source reconciliation.

Current setup-backed adapters are Feishu, Discord, and Telegram. Generated
secret support exists in the setup API, but these adapters currently return no
generated secret fields.

## AIAgent

`BullX.Setup.AIAgents` creates or updates an active Agent Principal with an
`ai_agent` profile. It also ensures AuthZ has the built-in `all_humans`
computed group, grants `all_humans` ordinary `invoke` access to the agent, and
keeps the agent self `invoke` grant.

The setup default profile includes:

- main, compression, and heavy LLM selections;
- the default BullX harness soul;
- `conversation_isolation_mode = "scene"`;
- deny-by-default elevation strategy.

The step is complete when the selected agent has a valid profile, its main
model resolves, the self `invoke` grant exists, and `all_humans` has an
ordinary `invoke` grant on the agent.

## Event Routing

The setup event-routing step creates or updates one source-scoped MailBox
delivery rule for the selected agent.

The rule shape is:

- name: `setup.default.<adapter>.<source>.channel`
- active: `true`
- priority: existing rule priority, or the next priority at or above `1000`
- match expression:
  `(type == "bullx.message.received" || type == "bullx.message.edited" || type == "bullx.message.recalled" || type == "bullx.message.deleted" || type == "bullx.command.invoked") && channel.adapter == <adapter> && channel.id == <source_id>`
- receiver type: `ai_agent`
- receiver ref: selected Agent uid
- session key: derived by MailBox from `cloud_event.data.queue_key`

After saving, setup validates the live rule against the adapter setup module's
routing sample through `BullX.MailBox.Matcher`.

## Activation

The final step displays:

```text
/root_init <bootstrap_activation_code>
```

The command is handled by the IM adapter before IMGateway handoff. It verifies
the process-local bootstrap code, resolves or creates a verified Human
Principal for the channel actor, and calls `BullX.AuthZ.root_init_admin/1`.

Activation does not depend on MailBox delivery or AIAgent conversation state.

## Web Routes

Current setup routes are:

- `/setup`
- `/setup/sessions/new`
- `/setup/plugins`
- `/setup/llm/providers`
- `/setup/channel-sources`
- `/setup/ai-agents`
- `/setup/event-routing-rules`
- `/setup/activate-admin`
- `/setup/activation/status`

The internal channel API under `/.internal-apis/v1` is protected by login and
CSRF and delegates to the same channel source setup boundary.
