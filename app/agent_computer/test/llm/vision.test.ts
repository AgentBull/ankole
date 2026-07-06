import { describe, expect, it } from 'bun:test'
import type { JsonObject } from '@pleisto/active-support'
import type { ImageContent, ModelConfig } from '../../src/core/llm'
import { modelImageAdaptation } from '../../src/core/vision'
import { fallbackModelForTest } from '../support/llm'

const image: ImageContent = { type: 'image', image: 'data:image/png;base64,AAA=' }

describe('@ankole/agent-computer vision helpers', () => {
  it('returns none when no images are present', async () => {
    await expect(modelImageAdaptation([], { input_modalities: ['text', 'image'] })).resolves.toEqual({ kind: 'none' })
  })

  it('passes images directly to image-capable models', async () => {
    await expect(modelImageAdaptation([image], { input_modalities: ['text', 'image'] })).resolves.toEqual({
      kind: 'direct',
      images: [image]
    })
  })

  it('summarizes images through the configured fallback for text-only models', async () => {
    const fallbackBodies: JsonObject[] = []
    const fallbackModel = fallbackModelForTest('A visible dashboard.', fallbackBodies)

    await expect(
      modelImageAdaptation([image], { input_modalities: ['text'] }, { visionFallbackModel: fallbackModel })
    ).resolves.toEqual({
      kind: 'summary',
      summary: 'A visible dashboard.'
    })
    expect(fallbackBodies).toHaveLength(1)
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
})
