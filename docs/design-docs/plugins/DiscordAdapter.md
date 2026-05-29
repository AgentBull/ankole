# Discord Adapter

The Discord plugin connects configured Discord bot sources to IMGateway and
Principal login.

The plugin id is `discord`.

## Extensions

`Discord.Plugin` declares:

- `:"bullx.im_gateway.channel_adapter"` with id `discord` and module
  `Discord.ChannelAdapter`
- `:"bullx.principals.login_provider"` with id `discord` and module
  `Discord.OIDCProvider`
- config module `Discord.Config`
- supervised child `Discord.SourceSupervisor`

## Source Config

Discord source setup is implemented by `Discord.SourceSetup`.

Source config is stored under
`bullx.plugins.discord.im_gateway_sources`.

The default source shape includes:

- `id`
- `enabled`
- `application_id`
- `bot_token`
- `client_id`
- `client_secret`
- OAuth2 scopes
- `im_listen_mode`
- `trusted_realm_by_default`

`application_id` and `bot_token` are required. Public projections mask secrets.
`trusted_realm_by_default` defaults to false.

## Inbound

Discord gateway and interaction payloads are normalized by
`Discord.ChannelAdapter` and `Discord.EventMapper`.

Current event mapping includes:

- `MESSAGE_CREATE` -> `bullx.message.received`
- `MESSAGE_UPDATE` with an edit timestamp -> `bullx.message.edited`
- `INTERACTION_CREATE` -> command or action mail depending on payload

Direct commands are handled before IMGateway handoff:

- `/root_init <code>`
- `/webauth`
- `/command`
- `/status`

Other slash commands, including unknown command names, are normalized to
`bullx.command.invoked`.

Addressed and ambient admission follows the source listen mode and Discord
mention/DM policy. MailBox stores the selected attention on the delivered entry.

## Outbound

Visible AIAgent output reaches Discord through IMGateway:

```text
AIAgent
  -> BullX.IMGateway.send_message/2
  -> Discord.ChannelAdapter.deliver/4
  -> Discord.Outbound
```

The adapter supports send/edit-style output and stream accumulation. Delivery
outcomes return provider ids to IMGateway, which updates the outbound
`im_messages` row.

## Setup

`Discord.SourceSetup.routing_sample/1` returns a MailBox routing-context sample
for setup validation. `reconcile_sources/0` updates the running source
supervisor after source config changes.

## Invariants

- Discord adapter code owns provider normalization and transport calls.
- IMGateway stores inbound and outbound IM facts.
- MailBox delivery rules decide receivers.
- Direct commands are adapter-local.
