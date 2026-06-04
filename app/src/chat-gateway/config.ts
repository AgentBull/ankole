import { defineAppConfigPattern, registerAppConfigPatterns } from '@/config/app-configure'
import { appConfigJsonRecordSchema } from '@/config/json-value-schema'

/**
 * Dynamic app-config key shape for per-agent channel adapter settings.
 *
 * Example: `agents.support_agent.slack`. The middle segment is the normalized
 * agent uid and may include punctuation already accepted by Principal UIDs; the
 * final segment is the channel name used in metadata and webhook URLs.
 */
export const agentChannelConfigKeyPattern = /^agents\.[a-z0-9._:-]+\.[a-z][a-z0-9_]*$/

/**
 * Encrypted dynamic config pattern for all Chat Gateway agent/channel settings.
 *
 * The pattern allows plugin code to use `appConfigService.getByKey(...)` without
 * pre-registering every agent/channel pair. Unknown non-matching keys are still
 * rejected by the app-config registry.
 */
export const AgentChannelConfigPattern = defineAppConfigPattern({
  id: 'chat_gateway.agent_channel_config',
  keyPattern: agentChannelConfigKeyPattern,
  encrypted: true,
  schema: appConfigJsonRecordSchema,
  defaultValue: {},
  description: 'Per-agent channel adapter configuration used by Chat Gateway adapter factories'
})

registerAppConfigPatterns([AgentChannelConfigPattern])

/**
 * Builds the dynamic config key for one agent channel.
 */
export function agentChannelConfigKey(agentUid: string, channelName: string): string {
  return `agents.${agentUid}.${channelName}`
}
