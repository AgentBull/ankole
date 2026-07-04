import type { JsonObject, TurnStart } from '../../lanes/actor_lane'
import type { CurrentChannelContext } from '../../prompts/system_prompt'
import {
  arrayPath,
  deepString,
  firstNumber,
  firstString,
  isRecord,
  objectPath,
  stringArg
} from '../../common/json-utils'

/**
 * Renders a journaled actor event into the primary user text for the model.
 *
 * Provider payloads are not perfectly uniform, so the extraction order is part
 * of the contract: commands prefer command args, normal entries prefer entry
 * text, and specialized wakeups get purpose-built text.
 */
export function actorEventText(payload: JsonObject | undefined, fallbackType: string): string {
  if (fallbackType === 'check_back_later.wakeup') {
    return checkBackLaterInputText(payload)
  }
  if (fallbackType === 'cron.fire') {
    return cronFireInputText(payload)
  }

  const text = fallbackType.startsWith('command.')
    ? deepString(payload, ['data', 'command', 'argsText']) ||
      deepString(payload, ['data', 'entry', 'text']) ||
      deepString(payload, ['data', 'internal', 'text'])
    : deepString(payload, ['data', 'entry', 'text']) ||
      deepString(payload, ['data', 'command', 'argsText']) ||
      deepString(payload, ['data', 'internal', 'text'])

  const attachments = attachmentText(payload)
  const base = text || `Handle actor event of type ${fallbackType}.`
  return attachments ? `${base}\n\nAttachments:\n${attachments}` : base
}

/**
 * Enables AIGateway truncation only for the overflow-retry path.
 */
export function statefulTruncationFromActorEventPayload(payload: JsonObject | undefined): 'auto' | undefined {
  const retryReason =
    deepString(payload, ['data', 'entry', 'retry_reason']) || deepString(payload, ['data', 'internal', 'retry_reason'])

  return retryReason === 'overflow_retry' ? 'auto' : undefined
}

/**
 * Builds the current-channel summary used by the system prompt.
 *
 * The worker projects channel facts for model context only; SignalsGateway and
 * the control plane still own provider routing and reply semantics.
 */
export function currentChannelFromTurnStart(turnStart: TurnStart): CurrentChannelContext | undefined {
  const input = turnStart.actor_event
  const channel = objectPath(input.payload_json, ['data', 'channel'])
  const kind = channelKind(stringArg(channel, 'kind'))
  const id = stringArg(channel, 'id') ?? deepString(input.payload_json, ['data', 'entry', 'signal_channel_id'])
  if (!kind && !id) return undefined

  const platform = sourcePlatform(input.payload_json)
  return {
    ...(stringArg(channel, 'name') || stringArg(channel, 'title')
      ? { name: stringArg(channel, 'name') ?? stringArg(channel, 'title') }
      : {}),
    ...(id ? { id } : {}),
    ...(platform ? { platform } : {}),
    ...(deepString(input.payload_json, ['data', 'session', 'binding_name'])
      ? {
          bindingName: deepString(input.payload_json, ['data', 'session', 'binding_name'])
        }
      : {}),
    kind: kind ?? 'external_room'
  }
}

/**
 * Renders a delayed self-wakeup into concise model input.
 */
function checkBackLaterInputText(payload: JsonObject | undefined): string {
  const wakePayload = objectPath(payload, ['data', 'wake_payload'])
  const reason = stringArg(wakePayload, 'reason')
  const check = stringArg(wakePayload, 'check')
  const contextSummary = stringArg(wakePayload, 'context_summary')

  return [
    'Scheduled checkback wakeup.',
    reason ? `Reason: ${reason}` : undefined,
    check ? `Check: ${check}` : undefined,
    contextSummary ? `Context: ${contextSummary}` : undefined
  ]
    .filter((line): line is string => Boolean(line))
    .join('\n')
}

/**
 * Renders a recurring schedule fire into concise model input.
 */
function cronFireInputText(payload: JsonObject | undefined): string {
  const wakePayload = objectPath(payload, ['data', 'wake_payload'])
  const scheduleName = stringArg(wakePayload, 'cron_schedule_name')
  const trigger = stringArg(wakePayload, 'trigger')
  const cronPayload = objectPath(wakePayload, ['payload'])

  return [
    'Recurring schedule fire.',
    scheduleName ? `Schedule: ${scheduleName}` : undefined,
    trigger ? `Trigger: ${trigger}` : undefined,
    Object.keys(cronPayload).length > 0 ? `Payload: ${JSON.stringify(cronPayload)}` : undefined
  ]
    .filter((line): line is string => Boolean(line))
    .join('\n')
}

/**
 * Maps provider channel kinds to the smaller prompt-facing channel vocabulary.
 */
function channelKind(kind: string | undefined): CurrentChannelContext['kind'] | undefined {
  switch (kind) {
    case 'im_dm':
      return 'external_dm'
    case 'im_group':
      return 'external_group'
    case undefined:
      return undefined
    default:
      return 'external_room'
  }
}

/**
 * Extracts the provider/platform name from a signal URI.
 */
function sourcePlatform(payload: JsonObject | undefined): string | undefined {
  const source = deepString(payload, ['source'])
  if (!source?.startsWith('signal://')) return undefined
  const withoutScheme = source.slice('signal://'.length)
  const separatorIndex = withoutScheme.indexOf('/')
  return separatorIndex >= 0 ? withoutScheme.slice(0, separatorIndex) : withoutScheme
}

/**
 * Renders attachment metadata into text when the model cannot directly inspect
 * the file bytes.
 */
function attachmentText(payload: JsonObject | undefined): string | undefined {
  const attachments = arrayPath(payload, ['data', 'entry', 'attachments'])
  if (attachments.length === 0) return undefined

  return (
    attachments
      .map((attachment, index) => attachmentLine(attachment, index))
      .filter((line): line is string => line !== undefined)
      .join('\n') || undefined
  )
}

/**
 * Formats one attachment line while preserving whether the file was
 * materialized into the worker workspace.
 */
function attachmentLine(value: unknown, index: number): string | undefined {
  if (!isRecord(value)) return undefined

  const name = firstString(value, ['name', 'filename', 'file_name', 'title'])
  const type = firstString(value, ['resource_type', 'mime_type', 'content_type', 'download_type'])
  const path = firstString(value, ['agent_computer_path', 'file_path', 'path'])
  const reference = firstString(value, ['provider_ref', 'provider_file_id', 'provider_uri', 'blob_ref', 'storage_ref'])
  const size = firstNumber(value, ['size', 'size_bytes', 'bytes'])
  const details: string[] = []

  if (type) details.push(`type=${type}`)
  if (size !== undefined) details.push(`size=${size}`)
  if (path) {
    details.push(`path=${path}`)
  } else if (reference) {
    details.push(`provider_ref=${reference}`)
    details.push('not_materialized_in_workspace=true')
  }

  if (details.length === 0 && !name) return undefined
  return `- ${name || `attachment ${index + 1}`}: ${details.join(', ')}`
}
