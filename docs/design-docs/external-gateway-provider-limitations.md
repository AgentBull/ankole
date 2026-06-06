# External Gateway provider limitations

External Gateway can mirror only provider-visible facts that a channel adapter can observe or fetch through an official provider surface. Adapter implementations must not invent lifecycle events from unofficial event names, third-party blog posts, or SDK folklore. When a provider does not expose a lifecycle event, External Gateway should document the gap and keep the latest-state guarantee limited to facts the provider actually delivers.

## Feishu and Lark

The first-party Lark adapter uses `@larksuiteoapi/node-sdk` `LarkChannel` for receive, reaction, and outbound message behavior. The adapter may register additional official Feishu/Lark events on the same SDK dispatcher when `LarkChannel` does not expose them directly.

| Capability | Provider surface | External Gateway behavior |
| --- | --- | --- |
| Message receive | `im.message.receive_v1` | Project the message according to `group_message_mode`, then deliver addressed or ambient events as configured. |
| Message recall | `im.message.recalled_v1` | Hard-delete the corresponding `external_messages` row and deliver a lifecycle event when the message had already reached the agent. The Feishu/Lark app must subscribe to this event in the developer console. |
| Message edit | No official event as of June 6, 2026 | Do not implement realtime edit handling for Feishu/Lark. The generic External Gateway contract currently has no inbound message-edit event. |
| Reactions | `im.message.reaction.created_v1` and `im.message.reaction.deleted_v1` | Update the projected reaction map for an already projected message. |

Feishu/Lark does not provide a message edit notification in the developer console or official event surface as of June 6, 2026. Event names such as `im.message.updated_v1` appear in third-party material, but they are not official Feishu/Lark events and must be treated as inaccurate. Do not add dispatcher handlers, adapter tests, or production code for those names unless Feishu/Lark exposes the event in official documentation and in the app event-subscription console.

Because Feishu/Lark cannot notify message edits, a group message that was projected through `observe_all` or `may_intervene` can remain stale after a user edits it in Feishu/Lark. This is a provider limitation, not an External Gateway audit or queue failure. The adapter should still handle recall events when the app has the required subscription enabled, because recall has an official event and represents a provider-visible removal.

Feishu/Lark long-connection delivery is cluster-mode, not broadcast-mode. If the same app ID opens multiple long-connection clients, each event is delivered to one randomly selected client. The Lark plugin must therefore keep a single long-connection consumer per app. In the current implementation, the plugin keeps one shared `LarkChannel` per `domain + appId`; External Gateway adapters and the Lark identity provider register their IM, recall, reaction, card, and contact handlers on that shared connection. Process startup initializes External Gateway adapters before identity-provider realtime sync so the shared connection has IM consumers before any identity listener can open or reuse it. Identity-provider startup attaches realtime transport before full sync, so new contact increments are observed while the startup full sync reconciles earlier contact facts. Identity realtime sync must not create a second `WSClient`.

## Implementation rule

Provider-specific limitations belong in adapter design and tests, not in generic External Gateway projection semantics. `external_messages` remains a latest-state mirror of observed facts. The table is not expected to converge to provider state for lifecycle changes that the provider never emits and the adapter never fetches through an official API.
