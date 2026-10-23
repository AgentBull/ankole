import type { ConfigFieldDefinition, LocalizedText } from '../../common/config-fields'
import type {
  ListSignalAdaptersResponse,
  ListSignalBindingsResponse,
  PutSignalBindingData,
  ListAgentFilesResponse,
  GetConsoleReadinessResponse,
  GetBackgroundAgentJobHealthResponse,
  GetBackgroundAgentJobTurnsResponse,
  BackgroundActivityJobsResponse,
  BackgroundActivityWorkflowResponse,
  BackgroundActivityAutomationRunsResponse
} from './v2/generated/types.gen'

export type SignalAdapterItem = Omit<
  ListSignalAdaptersResponse['signal_adapters'][number],
  'fields' | 'group_message_mode_field' | 'unmatched_sender_policy_field' | 'display_name'
> & {
  display_name?: LocalizedText
  fields: ConfigFieldDefinition[]
  group_message_mode_field?: ConfigFieldDefinition | null
  unmatched_sender_policy_field?: ConfigFieldDefinition | null
}
export type SignalBindingItem = ListSignalBindingsResponse['signal_bindings'][number]
export type SignalDeliveryFailureItem = ListSignalBindingsResponse['delivery_failures'][number]
export type SignalBindingWriteRequest = NonNullable<PutSignalBindingData['body']>['data']
export type AgentFileEntry = ListAgentFilesResponse['file_listing']['files'][number]
export type ConsoleReadinessResponse = GetConsoleReadinessResponse
export type BackgroundAgentJobHealthResponse = GetBackgroundAgentJobHealthResponse
export type BackgroundAgentJobTurnPageResponse = GetBackgroundAgentJobTurnsResponse
export type BackgroundAgentJobTurnItem = BackgroundAgentJobTurnPageResponse['turns'][number]
export type BackgroundAgentJobTurnPlanStep = NonNullable<
  BackgroundAgentJobTurnItem['progress']['plan']
>['steps'][number]
export type BackgroundAgentJobTurnUsageBreakdown = NonNullable<BackgroundAgentJobTurnItem['usage']>['thread_total']
export type BackgroundActivityJob = BackgroundActivityJobsResponse['jobs'][number]
export type BackgroundActivityWorkflowCall = BackgroundActivityWorkflowResponse['live_calls'][number]
export type BackgroundActivityWorkflowRun = BackgroundActivityWorkflowResponse['runs'][number]
export type BackgroundActivityAutomationRun = BackgroundActivityAutomationRunsResponse['runs'][number]
export type WorkflowActivityCounts = BackgroundActivityWorkflowRun['counts']
