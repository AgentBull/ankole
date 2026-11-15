import crypto from 'node:crypto'
export const { createHash, createHmac, randomBytes, randomUUID, timingSafeEqual, webcrypto } = crypto

// Edge Runtime's Node compatibility predates crypto.hash. MCPorter's
// connection identity hashing uses the same digest provided by createHash.
export function hash(
  algorithm: string,
  data: string | Uint8Array,
  outputEncoding: crypto.BinaryToTextEncoding = 'hex'
) {
  return crypto.createHash(algorithm).update(data).digest(outputEncoding)
}
export default { ...crypto, hash }
