import { aeadDecrypt, aeadEncrypt, deriveKey } from '@agentbull/bullx-native-addons'

export function sealText(value: string | Buffer, key: string): string {
  return aeadEncrypt(value, key)
}

export function unsealText(value: string, key: string): string {
  return aeadDecrypt(value, key).toString('utf-8')
}

export function sealJson(value: unknown, key: string): string {
  return sealText(JSON.stringify(value), key)
}

export function unsealJson<TValue = unknown>(value: string, key: string): TValue {
  return JSON.parse(unsealText(value, key)) as TValue
}

export function deriveSealKey(keySeed: string | Buffer, subKeyId: string, context?: string): string {
  return deriveKey(keySeed, subKeyId, context)
}
