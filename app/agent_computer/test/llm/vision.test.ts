import { describe, expect, it } from 'bun:test'
import { closeSync, ftruncateSync, mkdtempSync, openSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import type { ImageContent, ModelConfig } from '../../src/core/llm'
import {
  modelImageAdaptation,
  VISION_MAX_INPUT_IMAGE_BYTES,
  VISION_MAX_MODEL_IMAGE_DATA_URL_BYTES,
  VISION_MAX_MODEL_IMAGE_DIMENSION
} from '../../src/core/vision'
import { fallbackModelForTest } from '../support/llm'

const image: ImageContent = {
  type: 'image',
  image:
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII='
}

describe('@ankole/agent-computer vision helpers', () => {
  it('returns none when no images are present', async () => {
    await expect(modelImageAdaptation([], { input_modalities: ['text', 'image'] })).resolves.toEqual({ kind: 'none' })
  })

  it('normalizes direct model images to bounded WebP', async () => {
    const adaptation = await modelImageAdaptation([image], { input_modalities: ['text', 'image'] })
    expect(adaptation.kind).toBe('direct')
    if (adaptation.kind !== 'direct') throw new Error('expected direct image adaptation')

    expect(adaptation.images).toHaveLength(1)
    expect(adaptation.images[0]!.mimeType).toBe('image/webp')
    expect(adaptation.images[0]!.image).toMatch(/^data:image\/webp;base64,/)
    const dataURL = adaptation.images[0]!.image as string
    expect(Buffer.byteLength(dataURL)).toBeLessThanOrEqual(VISION_MAX_MODEL_IMAGE_DATA_URL_BYTES)
    const output = Buffer.from(dataURL.slice('data:image/webp;base64,'.length), 'base64')
    const metadata = await new Bun.Image(output).metadata()
    expect(Math.max(metadata.width, metadata.height)).toBeLessThanOrEqual(VISION_MAX_MODEL_IMAGE_DIMENSION)
  })

  it('does not silently truncate more than eight legal images', async () => {
    const adaptation = await modelImageAdaptation(
      Array.from({ length: 9 }, () => image),
      {
        input_modalities: ['text', 'image']
      }
    )
    expect(adaptation.kind).toBe('direct')
    if (adaptation.kind !== 'direct') throw new Error('expected direct image adaptation')
    expect(adaptation.images).toHaveLength(9)
  })

  it('rejects a file above the 50 MiB ingress boundary before decoding', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-vision-oversized-'))
    const path = join(root, 'oversized.png')
    const fd = openSync(path, 'w')
    ftruncateSync(fd, VISION_MAX_INPUT_IMAGE_BYTES + 1)
    closeSync(fd)

    try {
      await expect(
        modelImageAdaptation([{ type: 'image_file', path }], { input_modalities: ['text', 'image'] })
      ).resolves.toEqual({ kind: 'unavailable' })
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('summarizes normalized images through the configured fallback without a local output cap', async () => {
    const fallbackBodies: JSONObject[] = []
    const fallbackModel = fallbackModelForTest('A visible dashboard.', fallbackBodies)

    await expect(
      modelImageAdaptation([image], { input_modalities: ['text'] }, { visionFallbackModel: fallbackModel })
    ).resolves.toEqual({ kind: 'summary', summary: 'A visible dashboard.' })
    expect(fallbackBodies).toHaveLength(1)
    expect(JSON.stringify(fallbackBodies[0]!.input)).toContain('data:image/webp;base64,')
    expect(fallbackBodies[0]).not.toHaveProperty('max_output_tokens')
  })

  it('returns unavailable when no model path can inspect images', async () => {
    await expect(modelImageAdaptation([image], { input_modalities: ['text'] })).resolves.toEqual({
      kind: 'unavailable'
    })
  })

  it('returns unavailable when the fallback model fails', async () => {
    const failingFallback = {
      client: {
        responses: {
          create: async () => {
            throw new Error('fallback unavailable')
          }
        }
      },
      selector: 'vision_fallback',
      name: 'vision_fallback',
      provider: 'ai-gateway'
    } as unknown as ModelConfig

    await expect(
      modelImageAdaptation([image], { input_modalities: ['text'] }, { visionFallbackModel: failingFallback })
    ).resolves.toEqual({ kind: 'unavailable' })
  })

  it('propagates cancellation instead of degrading it to unavailable', async () => {
    const controller = new AbortController()
    controller.abort(new DOMException('cancelled', 'AbortError'))
    await expect(
      modelImageAdaptation([image], { input_modalities: ['text', 'image'] }, { abortSignal: controller.signal })
    ).rejects.toThrow('cancelled')
  })
})
