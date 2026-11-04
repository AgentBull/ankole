import type { PictureData } from '../state/spreadsheet-collaboration'

/** The kernel's limit for one picture. */
export const MAX_PICTURE_BYTES = 2 * 1024 * 1024
/** The longest edge a re-encoded picture keeps. */
const MAX_EDGE = 2048
/** A picture that keeps its own bytes may be this large on its longest edge. */
const MAX_KEPT_EDGE = 4096

export type PreparedPicture = { picture: PictureData; width: number; height: number }

/** Base64 text of `bytes`, in chunks so large pictures do not overflow the argument list. */
export function base64(bytes: Uint8Array): string {
  let binary = ''
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000))
  }
  return btoa(binary)
}

async function encode(bitmap: ImageBitmap, scale: number, type: string, quality: number): Promise<Blob> {
  const width = Math.max(1, Math.round(bitmap.width * scale))
  const height = Math.max(1, Math.round(bitmap.height * scale))
  const canvas = new OffscreenCanvas(width, height)
  const context = canvas.getContext('2d')
  if (!context) throw new Error('canvas unavailable')
  if (type === 'image/jpeg') {
    context.fillStyle = '#ffffff'
    context.fillRect(0, 0, width, height)
  }
  context.drawImage(bitmap, 0, 0, width, height)
  return canvas.convertToBlob({ type, quality })
}

/**
 * Turns a picked, pasted, or dropped image into what an operation carries. A PNG or JPEG within the
 * kernel's limits keeps its bytes; any other image, or a larger one, is drawn again at most 2048
 * pixels on its longest edge as PNG when it started as PNG and fits, else as JPEG, smaller until it
 * fits. Throws when the file is not an image the browser can decode.
 */
export async function preparePicture(file: Blob, alt = ''): Promise<PreparedPicture> {
  const bitmap = await createImageBitmap(file)
  try {
    const { width, height } = bitmap
    const kept =
      (file.type === 'image/png' || file.type === 'image/jpeg') &&
      file.size <= MAX_PICTURE_BYTES &&
      Math.max(width, height) <= MAX_KEPT_EDGE
    let blob: Blob = file
    if (!kept) {
      let scale = Math.min(1, MAX_EDGE / Math.max(width, height))
      blob = await encode(bitmap, scale, file.type === 'image/png' ? 'image/png' : 'image/jpeg', 0.86)
      for (let quality = 0.8; blob.size > MAX_PICTURE_BYTES && scale > 0.05; quality = Math.max(0.5, quality - 0.1)) {
        scale *= 0.8
        blob = await encode(bitmap, scale, 'image/jpeg', quality)
      }
      if (blob.size > MAX_PICTURE_BYTES) throw new Error('picture too large')
    }
    const mime = blob.type === 'image/png' ? 'image/png' : 'image/jpeg'
    const data = base64(new Uint8Array(await blob.arrayBuffer()))
    return { picture: { mime, data, ...(alt ? { alt } : {}) }, width, height }
  } finally {
    bitmap.close()
  }
}

/** A picture's size on the grid when it is inserted: its own size, shrunk to fit `limit` pixels. */
export function displaySize(width: number, height: number, limit = 400): { width: number; height: number } {
  const scale = Math.min(1, limit / Math.max(width, height, 1))
  return { width: Math.max(8, Math.round(width * scale)), height: Math.max(8, Math.round(height * scale)) }
}

/** The MIME type of picture bytes, from their signature. */
export function pictureType(bytes: Uint8Array): string {
  return bytes[0] === 0x89 && bytes[1] === 0x50 ? 'image/png' : 'image/jpeg'
}

/** Saves picture bytes as a file. */
export function downloadPicture(bytes: Uint8Array, name: string) {
  const type = pictureType(bytes)
  const url = URL.createObjectURL(new Blob([bytes as BlobPart], { type }))
  const link = document.createElement('a')
  link.href = url
  link.download = `${name}.${type === 'image/png' ? 'png' : 'jpg'}`
  link.click()
  setTimeout(() => URL.revokeObjectURL(url), 1000)
}
