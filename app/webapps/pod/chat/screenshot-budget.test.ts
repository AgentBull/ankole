import { describe, expect, test } from 'bun:test'
import {
  planScreenshotPixelRatio,
  SCREENSHOT_MAX_PIXELS,
  SCREENSHOT_MAX_SIDE,
  validateScreenshotPng
} from './screenshot-budget'

function buildPngHeaderBytes(width: number, height: number, totalByteLength = 128): Uint8Array {
  const bytes = new Uint8Array(totalByteLength)
  bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 0)
  const view = new DataView(bytes.buffer)
  view.setUint32(8, 13, false)
  bytes.set([0x49, 0x48, 0x44, 0x52], 12) // IHDR
  view.setUint32(16, width, false)
  view.setUint32(20, height, false)
  return bytes
}

describe('planScreenshotPixelRatio', () => {
  test('selects 3x for compact cards and steps down 3x -> 2x -> 1x as height grows', () => {
    const compact = planScreenshotPixelRatio(720, 1200)
    expect(compact).toEqual({
      kind: 'ok',
      pixelRatio: 3,
      pixelWidth: 2160,
      pixelHeight: 3600
    })

    // At 3x: 2160 * 8100 = 17,496,000 > 16MP -> steps down to 2x (1440 * 5400 = 7,776,000 <= 16MP)
    const medium = planScreenshotPixelRatio(720, 2700)
    expect(medium).toEqual({
      kind: 'ok',
      pixelRatio: 2,
      pixelWidth: 1440,
      pixelHeight: 5400
    })

    // At 2x: 1440 * 12000 = 17,280,000 > 16MP -> steps down to 1x (720 * 6000 = 4,320,000 <= 16MP)
    const tall = planScreenshotPixelRatio(720, 6000)
    expect(tall).toEqual({
      kind: 'ok',
      pixelRatio: 1,
      pixelWidth: 720,
      pixelHeight: 6000
    })
  })

  test('returns needsPagination when even 1x exceeds 16MP or 16,384px max side', () => {
    const overSide = planScreenshotPixelRatio(720, SCREENSHOT_MAX_SIDE + 10)
    expect(overSide).toEqual({
      kind: 'needsPagination',
      cssWidth: 720,
      cssHeight: SCREENSHOT_MAX_SIDE + 10
    })

    const overPixels = planScreenshotPixelRatio(4000, Math.ceil(SCREENSHOT_MAX_PIXELS / 4000) + 5)
    expect(overPixels.kind).toBe('needsPagination')
  })
})

describe('validateScreenshotPng', () => {
  test('accepts valid PNG headers within canvas bounds and rejects empty/corrupt/oversized PNGs', () => {
    expect(validateScreenshotPng(buildPngHeaderBytes(1440, 2400))).toEqual({
      valid: true,
      width: 1440,
      height: 2400
    })
    expect(validateScreenshotPng(new Uint8Array(16)).valid).toBe(false)
    expect(validateScreenshotPng(buildPngHeaderBytes(0, 200)).valid).toBe(false)
    expect(validateScreenshotPng(buildPngHeaderBytes(SCREENSHOT_MAX_SIDE + 1, 100)).valid).toBe(false)
  })
})
