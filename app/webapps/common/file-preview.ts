export const TEXT_PREVIEW_BYTES = 64 * 1024

export function isTextFile(name: string, mime?: string) {
  return Boolean(
    mime?.startsWith('text/') ||
    ['application/json', 'application/xml', 'application/javascript'].includes(mime ?? '') ||
    /\.(txt|md|markdown|json|xml|ya?ml|[cm]?[jt]sx?|py|exs?|rs|go|rb|sh|css|html|sql|toml)$/i.test(name)
  )
}
