import { readFile, stat } from 'node:fs/promises'
import { normalize, resolve } from 'node:path'
import type { JsonObject, TurnModelRef } from '../../actor_lane'
import type { ContentPart, ImageContent, ModelConfig } from '../llm'
import {
  describeImagesWithFallback,
  imageContentPartFromBuffer,
  imageSummaryBlock,
  modelSupportsImage,
  responseImageUnavailableText,
  VISION_MAX_IMAGES_PER_TURN
} from '../vision'
import { arrayPath, firstString, isRecord } from '../../common/json-utils'
import { actorEventText } from './actor_event_text'

export async function actorEventUserContent(
  payload: JsonObject | undefined,
  fallbackType: string,
  modelRef: TurnModelRef,
  opts: {
    workspaceRoot: string
    visionFallbackModel?: ModelConfig
    abortSignal?: AbortSignal
  }
): Promise<string | ContentPart[]> {
  const baseText = actorEventText(payload, fallbackType)
  const imageParts = await actorEventImageParts(payload, opts.workspaceRoot)

  if (imageParts.length === 0) return baseText

  if (modelSupportsImage(modelRef)) {
    return [{ type: 'text', text: baseText }, ...imageParts]
  }

  const summary = await fallbackSummary(opts.visionFallbackModel, imageParts, opts.abortSignal)
  if (summary) return `${baseText}\n\n${imageSummaryBlock(summary)}`

  return `${baseText}\n\n${responseImageUnavailableText()}`
}

async function actorEventImageParts(payload: JsonObject | undefined, workspaceRoot: string): Promise<ImageContent[]> {
  const attachments = arrayPath(payload, ['data', 'entry', 'attachments'])
  const paths = attachments.flatMap(visionEligibleAttachmentPath).slice(0, VISION_MAX_IMAGES_PER_TURN)
  const parts: ImageContent[] = []

  for (const path of paths) {
    const part = await imagePartFromWorkspacePath(path, workspaceRoot)
    if (part) parts.push(part)
  }

  return parts
}

function visionEligibleAttachmentPath(value: unknown): string[] {
  if (!isRecord(value)) return []
  if (firstString(value, ['resource_type']) !== 'image') return []

  const path = firstString(value, ['agent_computer_path', 'file_path', 'path'])
  return path ? [path] : []
}

async function imagePartFromWorkspacePath(path: string, workspaceRoot: string): Promise<ImageContent | undefined> {
  let filePath: string
  try {
    filePath = workspaceFilePath(path, workspaceRoot)
  } catch {
    return undefined
  }

  try {
    const info = await stat(filePath)
    if (!info.isFile()) return undefined

    const bytes = await readFile(filePath)
    return imageContentPartFromBuffer(bytes)
  } catch {
    return undefined
  }
}

function workspaceFilePath(path: string, workspaceRoot: string): string {
  const root = resolve(workspaceRoot)
  const normalized = normalize(path)
  const resolved = normalized.startsWith('/workspace')
    ? resolve(root, `.${normalized.slice('/workspace'.length)}`)
    : normalized.startsWith('/')
      ? resolve(root, `.${normalized}`)
      : resolve(root, normalized)

  if (resolved !== root && !resolved.startsWith(`${root}/`)) {
    throw new Error('image path escapes workspace root')
  }

  return resolved
}

async function fallbackSummary(
  fallbackModel: ModelConfig | undefined,
  images: ImageContent[],
  abortSignal: AbortSignal | undefined
): Promise<string | undefined> {
  if (!fallbackModel) return undefined

  try {
    return await describeImagesWithFallback(fallbackModel, images, { abortSignal })
  } catch {
    return undefined
  }
}
