# Feishu Adapter

The Feishu plugin connects configured Feishu/Lark app sources to IMGateway and
Principal login.

The plugin id is `feishu`.

## Extensions

`Feishu.Plugin` declares:

- `:"bullx.im_gateway.channel_adapter"` with id `feishu` and module
  `Feishu.ChannelAdapter`
- `:"bullx.principals.login_provider"` with id `feishu` and module
  `Feishu.OIDCProvider`
- config module `Feishu.Config`
- supervised child `Feishu.SourceSupervisor`

## Source Config

Feishu source setup is implemented by `Feishu.SourceSetup`.

Source config is stored under
`bullx.plugins.feishu.im_gateway_sources`.

The default source shape includes:

- `id`
- `enabled`
- `domain`
- `app_type`
- `app_id`
- `app_secret`
- `encrypt_key`
- `verification_token`
- `oidc`
- `web_login_disabled`
- `group_message_mode`
- `trusted_realm_by_default`

`app_id` and `app_secret` are required. Public projections mask secrets.

`trusted_realm_by_default` defaults to true for Feishu sources, so channel actor
identities created from incoming Feishu messages can be verified immediately
when the source config chooses that trust model.

## Inbound

`Feishu.ChannelAdapter.normalize_inbound/2` delegates provider event mapping to
Feishu modules and returns IMGateway message events.

Current event mapping includes:

- message receive -> `bullx.message.received`
- message updated -> `bullx.message.edited`
- message recalled -> `bullx.message.recalled`
- card action -> `bullx.message.received` with an action content block

Direct commands are handled before IMGateway handoff:

- `/root_init <code>`
- `/webauth`
- `/command`
- `/status`

Other slash commands, including unknown command names, are normalized to
`bullx.command.invoked`.

Card actions that continue an AIAgent conversation are normalized as
`bullx.message.received`; AIAgent sees the selected action as user message
content instead of a separate action event type.

Self bot messages are ignored. Addressed and ambient admission follows the
source `group_message_mode` and mention/DM policy. Unsupported or empty inbound
Feishu message bodies are ignored; they are not converted into prompt-visible
fallback text.

Feishu `chat_id` is the stable external room id used by IMGateway. Feishu
documents `chat_id` as globally unique and the same group returns the same
`chat_id` to different apps, so multiple Feishu bot sources observing the same
group map to one canonical `im_rooms` row. Future adapters must state whether
their room ids are global, realm-scoped, or source-scoped fallback ids before
they write IMGateway mirror rows.

## Principal Binding

Feishu channel actors are represented as `principal_external_identities` with
kind `channel_actor`, adapter `feishu`, source id as `channel_id`, and Feishu
actor id as `external_id`.

Feishu OIDC login uses the login provider extension and stores login-subject
external identities through the Principals boundary.

The `/webauth` direct command is allowed only in direct/private contexts. It
issues a short-lived login auth code for a verified bound actor and replies with
the web login URL.

## Outbound

Regular visible AIAgent assistant output reaches Feishu through IMGateway:

```text
AIAgent
  -> BullX.IMGateway.send_message/2
  -> Feishu.ChannelAdapter.deliver/4
  -> Feishu.Outbound
```

The adapter supports normal send/edit/recall-style delivery outcomes. IMGateway
best-effort mirrors provider-confirmed message ids and lifecycle state to
`im_messages` after the adapter call completes. Failed delivery attempts and
reply-address state are runtime facts and are not stored as IM message rows.

Streaming output uses `Feishu.ChannelAdapter.consume_stream/4` and
Feishu streaming card support. The initial outbound card message is still sent
through IMGateway and mirrored on a best-effort basis.

## Setup

`Feishu.SourceSetup.routing_sample/1` returns a MailBox routing-context sample
for setup validation. The setup event-routing step uses it to verify the
generated delivery rule with `BullX.MailBox.Matcher`.

`Feishu.SourceSetup.reconcile_sources/0` updates the running source supervisor
after source config changes.

## Invariants

- Feishu adapter code normalizes provider payloads; IMGateway routes IM mail and
  mirrors IM facts best-effort.
- MailBox delivery rules decide which receiver gets the mail.
- Direct commands are adapter-local and do not depend on MailBox.
- Feishu secrets are stored through BullX config secret handling and masked in
  public setup projections.
