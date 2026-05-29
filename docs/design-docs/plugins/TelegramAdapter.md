# Telegram Adapter

The Telegram plugin connects configured Telegram bot sources to IMGateway.

The plugin id is `bullx_telegram`. Its channel adapter id is `telegram`.

## Extensions

`BullxTelegram.Plugin` declares:

- `:"bullx.im_gateway.channel_adapter"` with id `telegram` and module
  `BullxTelegram.ChannelAdapter`
- config module `BullxTelegram.Config`
- supervised child `BullxTelegram.SourceSupervisor`

Telegram does not currently expose a browser login provider extension.

## Source Config

Telegram source setup is implemented by `BullxTelegram.SourceSetup`.

Source config is stored under
`bullx.plugins.bullx_telegram.im_gateway_sources`.

The default source shape includes:

- `id`
- `enabled`
- `bot_token`
- `bot_username`
- `group_message_mode`
- `trusted_realm_by_default`

`bot_token` is required. Public projections mask it.
`trusted_realm_by_default` defaults to false.

## Inbound

Telegram updates are normalized by `BullxTelegram.ChannelAdapter` and
`BullxTelegram.UpdateMapper`.

Current event mapping includes:

- message updates -> `bullx.message.received`
- edited message updates -> `bullx.message.edited`
- agent commands -> `bullx.command.invoked`

Direct commands are handled before IMGateway handoff:

- `/root_init <code>`
- `/webauth`
- `/command`
- `/status`

Other slash commands, including unknown command names, are normalized to
`bullx.command.invoked`.

Telegram currently has no provider recall event mapping.

Addressed and ambient admission follows `group_message_mode` and Telegram
mention/private-chat policy. The adapter emits routing facts; IMGateway and
MailBox derive the delivered entry attention from those facts.

## Outbound

Regular visible AIAgent assistant output reaches Telegram through IMGateway:

```text
AIAgent
  -> BullX.IMGateway.send_message/2
  -> BullxTelegram.ChannelAdapter.deliver/4
  -> BullxTelegram.Outbound
```

The adapter supports send/edit-style output and stream accumulation. Delivery
outcomes return provider ids to IMGateway, which best-effort mirrors outbound
delivery status to `im_messages`.

## Setup

`BullxTelegram.SourceSetup.routing_sample/1` returns a MailBox routing-context
sample for setup validation. `reconcile_sources/0` updates the running source
supervisor after source config changes.

## Invariants

- Telegram adapter id in normalized mail is `telegram`, not `bullx_telegram`.
- IMGateway routes IM mail and mirrors inbound and outbound IM facts
  best-effort.
- MailBox delivery rules decide receivers.
- Direct commands are adapter-local.
