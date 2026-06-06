import { defineAppConfigPattern, registerAppConfigPatterns } from '@/config/app-configure'
import { appConfigJsonRecordSchema } from '@/config/json-value-schema'

/**
 * Dynamic app-config key shape for per-agent channel adapter settings.
 *
 * Example: `agents.support_agent.slack`. The middle segment is the normalized
 * agent uid. Principal UIDs are human/operator-chosen text, so this pattern
 * keeps that segment broad while still requiring a normalized channel-name
 * suffix.
 */
export const agentChannelConfigKeyPattern = /^agents\.[^\r\n]+\.[a-z][a-z0-9_]*$/u

/**
 * Encrypted dynamic config pattern for all External Gateway agent/channel settings.
 *
 * The pattern allows plugin code to use `appConfigService.getByKey(...)` without
 * pre-registering every agent/channel pair. Unknown non-matching keys are still
 * rejected by the app-config registry.
 */
export const AgentChannelConfigPattern = defineAppConfigPattern({
  id: 'external_gateway.agent_channel_config',
  keyPattern: agentChannelConfigKeyPattern,
  encrypted: true,
  schema: appConfigJsonRecordSchema,
  defaultValue: {},
  description: 'Per-agent channel adapter configuration used by External Gateway adapter factories'
})

registerAppConfigPatterns([AgentChannelConfigPattern])

/**
 * Builds the dynamic config key for one agent channel.
 */
export function agentChannelConfigKey(agentUid: string, channelName: string): string {
  return `agents.${agentUid}.${channelName}`
}
