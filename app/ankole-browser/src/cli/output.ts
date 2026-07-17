import type { BrowserResponse } from '../protocol'

export function printResponse(response: BrowserResponse, json: boolean): number {
  if (json) {
    process.stdout.write(`${JSON.stringify(response)}\n`)
    return response.ok ? 0 : exitCode(response.error.code)
  }

  if (!response.ok) {
    process.stderr.write(`${response.error.message}\n`)
    return exitCode(response.error.code)
  }

  if (response.data !== undefined) {
    if (typeof response.data === 'string') process.stdout.write(`${response.data}\n`)
    else if (typeof response.data === 'number' || typeof response.data === 'boolean') {
      process.stdout.write(`${String(response.data)}\n`)
    } else process.stdout.write(`${JSON.stringify(response.data, null, 2)}\n`)
  }
  for (const warning of response.warnings) process.stderr.write(`warning: ${warning}\n`)
  return 0
}

export function exitCode(code: string): number {
  if (code === 'invalid_command') return 2
  if (code === 'missing_route' || code === 'invalid_material' || code === 'session_spec_conflict') return 3
  if (['stale_ref', 'dialog_blocked', 'no_page', 'invalid_result'].includes(code)) return 4
  if (['backend_unavailable', 'session_lost', 'session_busy', 'timeout'].includes(code)) return 5
  if (code === 'cancelled') return 130
  return 1
}

export const CLIHelp = `Usage: ankole-browser [--session NAME] [--json] [--timeout MS] <command> ...

Core commands:
  open [URL]                         Open or navigate the current page
  snapshot [-i] [-c] [-d N]         Print rendered page snapshot with @eN refs
  click|fill|type|hover|focus ...    Act on @eN refs or CSS selectors
  get|is|find|wait ...               Observe or wait for page state
  tab|frame|dialog ...               Manage browser-side state
  screenshot [PATH] [--full]        Save a PNG artifact
  batch [--bail] <COMMAND...>        Execute commands under one session lock
  run <FILE.mjs> [-- ARGS...]        Execute model-written Playwright code
  status|close                       Inspect or close the live browser
`
