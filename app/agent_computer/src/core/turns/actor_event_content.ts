import { stat } from 'node:fs/promises'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import type { TurnModelRef } from '../../lanes/actor_lane'
import { assertExistingPathWithin, workspacePhysicalRoots } from '../real-path-boundary'
import { resolveAgentHomePath } from '../agent-home-paths'
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
    agentHome?: string
    workspaceRoot: string
    visionFallbackModel?: ModelConfig
    abortSignal?: AbortSignal
  }
): Promise<string | ContentPart[]> {
  const baseText = actorEventText(payload, fallbackType)
  const imageParts = await actorEventImageParts(payload, opts.agentHome ?? opts.workspaceRoot, opts.workspaceRoot)
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
  agentHome: string,
  workspaceRoot: string
): Promise<ModelImageSource[]> {
  const attachments = [
    ...arrayPath(payload, ['data', 'entry', 'attachments']),
    ...arrayPath(payload, ['data', 'entry', 'reply_to', 'attachments'])
  ]
  const paths = [...new Set(attachments.flatMap(visionEligibleAttachmentPath))]
  const parts: ModelImageSource[] = []

  for (const path of paths) {
    const part = await imageSourceFromAgentPath(path, agentHome, workspaceRoot)
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
async function imageSourceFromAgentPath(
  path: string,
  agentHome: string,
  workspaceRoot: string
): Promise<ModelImageSource | undefined> {
  let filePath: string
  try {
    filePath = agentFilePath(path, agentHome, workspaceRoot)
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
 * Resolves a real Agent Home path or a workspace-relative attachment path.
 */
function agentFilePath(path: string, agentHome: string, workspaceRoot: string): string {
  const lexicalPath = resolveAgentHomePath(agentHome, path, {
    cwd: workspaceRoot,
    errorMessage: 'image path escapes Agent Home'
  })
  return assertExistingPathWithin(
    workspacePhysicalRoots(agentHome),
    lexicalPath,
    'image path resolves outside Agent Home'
  )
}
