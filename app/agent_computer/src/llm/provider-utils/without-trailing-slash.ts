// @ts-nocheck
export function withoutTrailingSlash(url: string | undefined) {
  return url?.replace(/\/$/, '')
}
