import { BrowserDataError } from '../errors'

export function compileQueryFilter(pattern: string): (line: string) => boolean {
  const slashMatch = /^\/(.+)\/([a-z]*)$/.exec(pattern)
  if (slashMatch) {
    try {
      const flags = (slashMatch[2] || 'i').replace(/[gy]/g, '')
      const regex = new RegExp(slashMatch[1]!, flags)
      return line => regex.test(line)
    } catch {
      throw new BrowserDataError('invalid_command', `invalid regular expression: ${pattern}`)
    }
  }
  const needle = pattern.toLowerCase()
  return line => line.toLowerCase().includes(needle)
}
