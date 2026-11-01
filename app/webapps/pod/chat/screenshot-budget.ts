export const SCREENSHOT_MAX_PIXELS = 16_000_000
export const SCREENSHOT_MAX_SIDE = 16_384
export const CANDIDATE_PIXEL_RATIOS = [3, 2, 1] as const

export type ScreenshotPixelRatioPlan =
  | {
      kind: 'ok'
      pixelRatio: number
      pixelWidth: number
      pixelHeight: number
    }
  | {
      kind: 'needsPagination'
      cssWidth: number
      cssHeight: number
    }

/**
 * Plans the highest crisp device pixel ratio (`3x -> 2x -> 1x`) that stays within
 * browser canvas rasterization budgets (`<= 16 MP` and `<= 16,384 px` per side).
 * Returns `{ kind: 'needsPagination' }` when even `1x` exceeds safe canvas bounds.
 */
export function planScreenshotPixelRatio(cssWidth: number, cssHeight: number): ScreenshotPixelRatioPlan {
  const width = Math.max(1, Math.ceil(cssWidth))
  const height = Math.max(1, Math.ceil(cssHeight))

  for (const ratio of CANDIDATE_PIXEL_RATIOS) {
    const pixelWidth = Math.ceil(width * ratio)
    const pixelHeight = Math.ceil(height * ratio)
    if (
      pixelWidth <= SCREENSHOT_MAX_SIDE &&
      pixelHeight <= SCREENSHOT_MAX_SIDE &&
      pixelWidth * pixelHeight <= SCREENSHOT_MAX_PIXELS
    ) {
      return {
        kind: 'ok',
        pixelRatio: ratio,
        pixelWidth,
        pixelHeight
      }
    }
  }

  return {
    kind: 'needsPagination',
    cssWidth: width,
    cssHeight: height
  }
}

const PNG_SIGNATURE = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])

export function validateScreenshotPng(bytes: Uint8Array): { valid: boolean; width: number; height: number } {
  if (bytes.byteLength < 33) return { valid: false, width: 0, height: 0 }
  for (let i = 0; i < PNG_SIGNATURE.length; i += 1) {
    if (bytes[i] !== PNG_SIGNATURE[i]) return { valid: false, width: 0, height: 0 }
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  if (bytes[12] !== 0x49 || bytes[13] !== 0x48 || bytes[14] !== 0x44 || bytes[15] !== 0x52) {
    return { valid: false, width: 0, height: 0 }
  }
  const width = view.getUint32(16, false)
  const height = view.getUint32(20, false)
  const valid =
    width > 0 &&
    height > 0 &&
    width <= SCREENSHOT_MAX_SIDE &&
    height <= SCREENSHOT_MAX_SIDE &&
    width * height <= SCREENSHOT_MAX_PIXELS &&
    bytes.byteLength > 64
  return { valid, width, height }
}
