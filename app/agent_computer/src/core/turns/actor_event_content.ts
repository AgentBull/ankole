import { stat } from 'node:fs/promises'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import type { TurnModelRef } from '../../lanes/actor_lane'
import { assertExistingPathWithin, workspacePhysicalRoots } from '../real-path-boundary'
import { resolveWorkspacePath } from '../workspace-paths'
import type { ContentPart, ModelConfig } from '../llm'
import { imageSummaryBlock, modelImageAdaptation, responseImageUnavailableText, type ModelImageSource } from '../vision'
import { arrayPath, firstString, isRecord } from '@pleisto/active-support'
import { actorEventText } from './actor_event_text'

/**
 * Builds the model-facing user content for one actor event.
 *
 * Text is always present. Image attachments are passed through when the selected
 * model supports images; otherwise the worker tries a vision fallback summary so
 * text-only models still receive useful context.
 */
export async function actorEventUserContent(
  payload: JSONObject | undefined,
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
  const adaptation = await modelImageAdaptation(imageParts, modelRef, {
    visionFallbackModel: opts.visionFallbackModel,
    abortSignal: opts.abortSignal
  })

  if (adaptation.kind === 'none') return baseText

  if (adaptation.kind === 'direct') {
    return [{ type: 'text', text: baseText }, ...adaptation.images]
  }

  if (adaptation.kind === 'summary') {
    return `${baseText}\n\n${imageSummaryBlock(adaptation.summary)}`
  }

  return `${baseText}\n\n${responseImageUnavailableText()}`
}

/**
 * Loads image attachments that have already been materialized into the worker
 * workspace.
 *
 * Provider references without an agent-computer path are ignored here because
 * the worker cannot fetch provider-owned blobs directly.
 */
async function actorEventImageParts(
  payload: JSONObject | undefined,
  workspaceRoot: string
): Promise<ModelImageSource[]> {
  const attachments = [
    ...arrayPath(payload, ['data', 'entry', 'attachments']),
    ...arrayPath(payload, ['data', 'entry', 'reply_to', 'attachments'])
  ]
  const paths = [...new Set(attachments.flatMap(visionEligibleAttachmentPath))]
  const parts: ModelImageSource[] = []

  for (const path of paths) {
    const part = await imageSourceFromWorkspacePath(path, workspaceRoot)
    if (part) parts.push(part)
  }

  return parts
}

/**
 * Returns a workspace path only for image-like attachment metadata.
 */
function visionEligibleAttachmentPath(value: unknown): string[] {
  if (!isRecord(value)) return []
  if (firstString(value, ['resource_type']) !== 'image') return []

  const path = firstString(value, ['agent_computer_path', 'file_path', 'path'])
  return path ? [path] : []
}

/**
 * Reads one workspace image as a Responses image content part.
 *
 * Missing or invalid files are ignored because attachment text still describes
 * the file; a single bad attachment should not drop the whole actor event.
 */
async function imageSourceFromWorkspacePath(
  path: string,
  workspaceRoot: string
): Promise<ModelImageSource | undefined> {
  let filePath: string
  try {
    filePath = workspaceFilePath(path, workspaceRoot)
  } catch {
    return undefined
  }

  try {
    const info = await stat(filePath)
    if (!info.isFile()) return undefined

    return { type: 'image_file', path: filePath }
  } catch {
    return undefined
  }
}

/**
 * Resolves a `/workspace/...` or relative attachment path under the session
 * workspace root.
 */
function workspaceFilePath(path: string, workspaceRoot: string): string {
  const lexicalPath = resolveWorkspacePath(workspaceRoot, path, { errorMessage: 'image path escapes workspace root' })
  return assertExistingPathWithin(
    workspacePhysicalRoots(workspaceRoot),
    lexicalPath,
    'image path resolves outside workspace roots'
  )
}
