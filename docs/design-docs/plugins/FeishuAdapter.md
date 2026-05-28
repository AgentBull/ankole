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
- `im_listen_mode`
- `trusted_realm_by_default`

`app_id` and `app_secret` are required. Public projections mask secrets.

`trusted_realm_by_default` defaults to true for Feishu sources, so channel actor
identities created from incoming Feishu messages can be verified immediately
when the source config chooses that trust model.

## Inbound

`Feishu.ChannelAdapter.normalize_inbound/2` delegates provider event mapping to
Feishu modules and returns CloudEvents maps for IMGateway.

Current event mapping includes:

- message receive -> `bullx.im.message.addressed` or
  `bullx.im.message.ambient`
- message updated -> `bullx.message.edited`
- message recalled -> `bullx.message.recalled`
- card action -> `bullx.action.submitted`
- reaction changed -> `bullx.reaction.changed`

Direct commands are handled before IMGateway handoff:

- `/root_init <code>`
- `/webauth`

Other agent commands are normalized to `bullx.command.invoked`.

Self bot messages are ignored. Addressed and ambient admission follows the
source listen mode and mention/DM policy.

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

Visible AIAgent output reaches Feishu through IMGateway:

```text
AIAgent
  -> BullX.IMGateway.send_message/2
  -> Feishu.ChannelAdapter.deliver/4
  -> Feishu.Outbound
```

The adapter supports normal send/edit/recall-style delivery outcomes and stores
the provider message id back on the outbound `im_messages` row through
IMGateway.

Streaming output uses `Feishu.ChannelAdapter.consume_stream/4` and
Feishu streaming card support. The initial outbound card message is still
persisted through IMGateway.

## Setup

`Feishu.SourceSetup.routing_sample/1` returns a MailBox routing-context sample
for setup validation. The setup event-routing step uses it to verify the
generated delivery rule with `BullX.MailBox.Matcher`.

`Feishu.SourceSetup.reconcile_sources/0` updates the running source supervisor
after source config changes.

## Invariants

- Feishu adapter code normalizes provider payloads; IMGateway stores IM facts.
- MailBox delivery rules decide which receiver gets the mail.
- Direct setup/auth commands are adapter-local and do not depend on MailBox.
- Feishu secrets are stored through BullX config secret handling and masked in
  public setup projections.
