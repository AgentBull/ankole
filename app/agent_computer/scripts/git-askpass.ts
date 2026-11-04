#!/usr/bin/env bun
const prompt = process.argv[2] ?? ''
const match = /(?:Username|Password) for '(https:\/\/[^']+)'/.exec(prompt)
const context = process.env.ANKOLE_MCP_CONTEXT_FILE
  ? ((await Bun.file(process.env.ANKOLE_MCP_CONTEXT_FILE).json()) as { token: string; origin: string })
  : { token: process.env.ANKOLE_MCP_TOKEN, origin: process.env.ANKOLE_MCP_ORIGIN }
if (!match || !context.token || !context.origin) {
  throw new Error('Git authentication requires an active Turn and an HTTPS repository URL')
}
const url = new URL(match[1]!)
url.username = ''
url.password = ''
if (prompt.startsWith('Username')) {
  process.stdout.write('x-access-token\n')
  process.exit(0)
}
const response = await fetch(new URL('/api/internal/connectors/git-credentials', context.origin), {
  method: 'POST',
  headers: { authorization: `Bearer ${context.token}`, 'content-type': 'application/json' },
  body: JSON.stringify({
    url: url.toString(),
    connection: process.env.ANKOLE_GITHUB_CONNECTION,
    account: process.env.ANKOLE_GITHUB_ACCOUNT
  })
})
const result = (await response.json()) as {
  username?: string
  password?: string
  error?: { code: string; authorization_url?: string }
}
if (!response.ok || !result.username || !result.password) {
  throw new Error(
    [result.error?.code ?? 'Git credential exchange failed', result.error?.authorization_url].filter(Boolean).join('\n')
  )
}
process.stdout.write(`${result.password}\n`)
