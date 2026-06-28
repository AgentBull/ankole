// btoa and atob need to be invoked as a function call, not as a method call.
// Otherwise CloudFlare will throw a
// "TypeError: Illegal invocation: function called with incorrect this reference"
const { btoa, atob } = globalThis

export function convertBase64ToUint8Array(base64String: string) {
  const base64Url = base64String.replace(/-/g, '+').replace(/_/g, '/')
  const latin1string = atob(base64Url)
  return Uint8Array.from(latin1string, byte => byte.codePointAt(0)!)
}

export function convertUint8ArrayToBase64(array: Uint8Array): string {
  let latin1string = ''

  // Note: regular for loop to support older JavaScript versions that
  // do not support for..of on Uint8Array
  for (let i = 0; i < array.length; i++) {
    latin1string += String.fromCodePoint(array[i])
  }

  return btoa(latin1string)
}

export function convertUint8ArrayToArrayBuffer(array: Uint8Array): ArrayBuffer {
  if (array.buffer instanceof ArrayBuffer) {
    return array.buffer.slice(array.byteOffset, array.byteOffset + array.byteLength)
  }

  const copy = new Uint8Array(array.byteLength)
  copy.set(array)
  return copy.buffer
}

export function convertToBase64(value: string | Uint8Array): string {
  return value instanceof Uint8Array ? convertUint8ArrayToBase64(value) : value
}
