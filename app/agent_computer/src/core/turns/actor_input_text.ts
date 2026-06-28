import type { JsonObject, TurnStart } from '../../actor_lane'
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

export function inputText(payload: JsonObject | undefined, fallbackType: string): string {
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
  const base = text || `Handle actor input of type ${fallbackType}.`
  return attachments ? `${base}\n\nAttachments:\n${attachments}` : base
}

export function currentChannelFromTurnStart(turnStart: TurnStart): CurrentChannelContext | undefined {
  for (const input of turnStart.inputs) {
    const channel = objectPath(input.payload_json, ['data', 'channel'])
    const kind = channelKind(stringArg(channel, 'kind'))
    const id = stringArg(channel, 'id') ?? deepString(input.payload_json, ['data', 'entry', 'signal_channel_id'])
    if (!kind && !id) continue

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
}

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

function sourcePlatform(payload: JsonObject | undefined): string | undefined {
  const source = deepString(payload, ['source'])
  if (!source?.startsWith('signal://')) return undefined
  const withoutScheme = source.slice('signal://'.length)
  const separatorIndex = withoutScheme.indexOf('/')
  return separatorIndex >= 0 ? withoutScheme.slice(0, separatorIndex) : withoutScheme
}

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
