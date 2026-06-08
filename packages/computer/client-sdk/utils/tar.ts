/**
 * Minimal, dependency-free USTAR writer + gzip, used by {@link FileWriter} to pack
 * `writeFiles` uploads. The Rust worker untars with `tar` + `flate2`, so we only
 * need to *produce* a valid `tar.gz`. Paths are expected pre-normalized (relative,
 * no `..`). Names up to 255 bytes are supported via the USTAR name/prefix split.
 */

const BLOCK = 512
const encoder = new TextEncoder()

export interface TarEntry {
  name: string
  data: Uint8Array
  mode?: number
  mtimeMs?: number
}

function writeString(block: Uint8Array, offset: number, value: string, max: number): void {
  const bytes = encoder.encode(value)
  if (bytes.length > max) throw new Error(`tar field exceeds ${max} bytes: ${value}`)
  block.set(bytes, offset)
}

/** Write a NUL-terminated octal number into `width` bytes (width-1 digits + NUL). */
function writeOctal(block: Uint8Array, offset: number, value: number, width: number): void {
  const text = value.toString(8).padStart(width - 1, '0')
  writeString(block, offset, text, width - 1)
}

function splitName(name: string): { name: string; prefix: string } {
  if (encoder.encode(name).length <= 100) return { name, prefix: '' }
  const slash = name.lastIndexOf('/', name.length - 1)
  for (let cut = slash; cut > 0; cut = name.lastIndexOf('/', cut - 1)) {
    const prefix = name.slice(0, cut)
    const rest = name.slice(cut + 1)
    if (encoder.encode(prefix).length <= 155 && encoder.encode(rest).length <= 100) return { name: rest, prefix }
  }
  throw new Error(`tar entry name too long for USTAR: ${name}`)
}

function header(entry: TarEntry): Uint8Array {
  const block = new Uint8Array(BLOCK)
  const { name, prefix } = splitName(entry.name)
  writeString(block, 0, name, 100)
  writeOctal(block, 100, (entry.mode ?? 0o644) & 0o7777, 8)
  writeOctal(block, 108, 0, 8) // uid
  writeOctal(block, 116, 0, 8) // gid
  writeOctal(block, 124, entry.data.length, 12)
  writeOctal(block, 136, Math.floor((entry.mtimeMs ?? 0) / 1000), 12)
  for (let i = 148; i < 156; i++) block[i] = 0x20 // checksum field starts as spaces
  block[156] = 0x30 // typeflag '0' = regular file
  writeString(block, 257, 'ustar', 6) // magic "ustar\0"
  block[263] = 0x30 // version "00"
  block[264] = 0x30
  if (prefix) writeString(block, 345, prefix, 155)

  let checksum = 0
  for (let i = 0; i < BLOCK; i++) checksum += block[i]!
  writeString(block, 148, checksum.toString(8).padStart(6, '0'), 6)
  block[154] = 0
  block[155] = 0x20
  return block
}

export function createTar(entries: TarEntry[]): Uint8Array<ArrayBuffer> {
  const blocks: Uint8Array[] = []
  for (const entry of entries) {
    blocks.push(header(entry))
    const padded = new Uint8Array(Math.ceil(entry.data.length / BLOCK) * BLOCK)
    padded.set(entry.data, 0)
    blocks.push(padded)
  }
  blocks.push(new Uint8Array(BLOCK)) // two trailing zero blocks
  blocks.push(new Uint8Array(BLOCK))

  const total = blocks.reduce((sum, block) => sum + block.length, 0)
  const out = new Uint8Array(total)
  let offset = 0
  for (const block of blocks) {
    out.set(block, offset)
    offset += block.length
  }
  return out
}

export function createTarGz(entries: TarEntry[]): Uint8Array {
  return Bun.gzipSync(createTar(entries))
}
