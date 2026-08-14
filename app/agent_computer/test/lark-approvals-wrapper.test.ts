import { afterEach, describe, expect, it } from 'bun:test'
import { chmod, mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const wrapper = join(import.meta.dir, '../../library/agent-plugins/lark/skills/lark-approvals/scripts/lark-approvals')
const roots: string[] = []
const profile = `ankole-u-${'a'.repeat(43)}`
const otherProfile = `ankole-u-${'b'.repeat(43)}`
const longDeviceCode = `${'a'.repeat(170)}.${'b'.repeat(171)}.${'c'.repeat(171)}`

afterEach(async () => {
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })))
})

describe('lark-approvals wrapper', () => {
  it('uses the derived profile and removes bot credential providers from approval calls', async () => {
    const fixture = await wrapperFixture()
    const result = runWrapper(fixture, ['tasks', 'query', '--params', '{"topic":"1"}', '--format', 'json'])

    expect(result.exitCode).toBe(0)
    const trace = await readFile(fixture.trace, 'utf8')
    expect(trace).toContain(`--profile ${profile} approval tasks query --params {"topic":"1"} --format json --as user`)
    expect(trace).toContain('BOT_ENV=|||||||||')
    expect(trace).not.toContain('config strict-mode')
    expect(await Bun.file(join(fixture.home, '.lark-cli/.ankole-account.lock')).exists()).toBe(false)
  })

  it('keeps the exact login device code inside only the selected profile', async () => {
    const fixture = await wrapperFixture()
    const begun = runWrapper(fixture, ['auth', 'begin'])

    expect(begun.exitCode).toBe(0)
    expect(longDeviceCode).toHaveLength(514)
    expect(begun.stdout.toString()).not.toContain('device_code')
    expect(begun.stdout.toString()).not.toContain(longDeviceCode)

    const statePath = join(fixture.home, `.lark-cli/.ankole-profile-state/${profile}/auth-login.json`)
    expect(JSON.parse(await readFile(statePath, 'utf8')).device_code).toBe(longDeviceCode)

    const wrongProfile = runWrapper(fixture, ['auth', 'complete'], {
      ANKOLE_RUNTIME_LARK_PROFILE: otherProfile
    })
    expect(wrongProfile.exitCode).toBe(1)
    expect(wrongProfile.stderr.toString()).toContain('no pending user authorization')
    expect(JSON.parse(await readFile(statePath, 'utf8')).device_code).toBe(longDeviceCode)

    const completed = runWrapper(fixture, ['auth', 'complete'])
    expect(completed.exitCode).toBe(0)
    expect(completed.stdout.toString()).toContain('authorization_complete')
    expect(completed.stdout.toString()).not.toContain(longDeviceCode)
    expect(await Bun.file(statePath).exists()).toBe(false)

    const trace = await readFile(fixture.trace, 'utf8')
    expect(trace).toContain(`--profile ${profile} config strict-mode off`)
    expect(trace).toContain(`--profile ${profile} auth login --domain approval --no-wait --json`)
    expect(trace).toContain(`--profile ${profile} auth login --device-code ${longDeviceCode} --json`)
    expect(await Bun.file(join(fixture.home, '.lark-cli/.ankole-account.lock')).exists()).toBe(true)
  })

  it('repairs an existing profile policy during the locked profile preflight', async () => {
    const fixture = await wrapperFixture()
    const result = runWrapper(fixture, ['profile', 'status'])

    expect(result.exitCode).toBe(0)
    const trace = await readFile(fixture.trace, 'utf8')
    expect(trace).toContain(`--profile ${profile} config strict-mode off`)
    expect(await Bun.file(join(fixture.home, '.lark-cli/.ankole-account.lock')).exists()).toBe(true)
  })

  it('uploads one approval file with the selected profile app identity without the account lock', async () => {
    const fixture = await wrapperFixture()
    const result = runWrapper(fixture, [
      'files',
      'upload',
      '--file',
      'content=./invoice.pdf',
      '--data',
      '{"name":"invoice.pdf","type":"attachment"}',
      '--format',
      'json'
    ])

    expect(result.exitCode).toBe(0)
    const trace = await readFile(fixture.trace, 'utf8')
    expect(trace).toContain(
      `--profile ${profile} api POST /open-apis/approval/v4/files/upload --file content=./invoice.pdf --data {"name":"invoice.pdf","type":"attachment"} --format json --as bot`
    )
    expect(trace).toContain('BOT_ENV=|||||||||')
    expect(await Bun.file(join(fixture.home, '.lark-cli/.ankole-account.lock')).exists()).toBe(false)
  })

  it('rejects a non-derived profile before it invokes lark-cli', async () => {
    const fixture = await wrapperFixture()
    const result = runWrapper(fixture, ['tasks', 'query'], { ANKOLE_RUNTIME_LARK_PROFILE: 'human-alice' })

    expect(result.exitCode).toBe(2)
    expect(result.stderr.toString()).toContain('ANKOLE_RUNTIME_LARK_PROFILE is invalid')
    expect(await Bun.file(fixture.trace).exists()).toBe(false)
  })
})

async function wrapperFixture(): Promise<{ root: string; home: string; bin: string; trace: string }> {
  const root = await mkdtemp(join(tmpdir(), 'ankole-lark-approvals-'))
  roots.push(root)
  const home = join(root, 'home')
  const bin = join(root, 'bin')
  const trace = join(root, 'trace.log')
  await mkdir(home)
  await mkdir(bin)

  await writeFile(
    join(bin, 'lark-cli'),
    `#!/bin/sh
printf '%s\\n' "$*" >> "$TRACE_FILE"
printf 'BOT_ENV=%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\\n' \
  "\${LARKSUITE_CLI_APP_ID:-}" \
  "\${LARKSUITE_CLI_APP_SECRET:-}" \
  "\${LARKSUITE_CLI_BRAND:-}" \
  "\${LARKSUITE_CLI_USER_ACCESS_TOKEN:-}" \
  "\${LARKSUITE_CLI_TENANT_ACCESS_TOKEN:-}" \
  "\${LARKSUITE_CLI_DEFAULT_AS:-}" \
  "\${LARKSUITE_CLI_STRICT_MODE:-}" \
  "\${LARKSUITE_CLI_AUTH_PROXY:-}" \
  "\${LARKSUITE_CLI_PROXY_KEY:-}" \
  "\${ANKOLE_RUNTIME_LARK_TENANT_ACCESS_TOKEN_FILE:-}" >> "$TRACE_FILE"
case "$*" in
  *"config show"*) exit 0 ;;
  *"auth login --domain approval --no-wait --json"*)
    printf '{"verification_url":"https://accounts.feishu.cn/device","device_code":"%s","expires_in":600}\\n' "$FAKE_DEVICE_CODE"
    exit 0
    ;;
  *"auth login --device-code "*)
    device_code=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--device-code" ]; then
        shift
        device_code="$1"
        break
      fi
      shift
    done
    if [ "$device_code" != "$FAKE_DEVICE_CODE" ]; then
      echo "wrong device code" >&2
      exit 8
    fi
    printf '{"event":"authorization_complete","user_open_id":"ou_test"}\\n'
    exit 0
    ;;
esac
printf '{"ok":true}\\n'
`
  )
  await writeFile(join(bin, 'flock'), '#!/bin/sh\nexit 0\n')
  await chmod(join(bin, 'lark-cli'), 0o755)
  await chmod(join(bin, 'flock'), 0o755)
  return { root, home, bin, trace }
}

function runWrapper(
  fixture: { home: string; bin: string; trace: string },
  args: string[],
  overrides: Record<string, string> = {}
) {
  return Bun.spawnSync(['bash', wrapper, ...args], {
    env: {
      ...process.env,
      PATH: `${fixture.bin}:${process.env.PATH ?? ''}`,
      HOME: fixture.home,
      TRACE_FILE: fixture.trace,
      ANKOLE_RUNTIME_CURRENT_ACTOR_SENDER_PRINCIPAL: 'human-alice',
      ANKOLE_RUNTIME_LARK_PROFILE: profile,
      LARKSUITE_CLI_APP_ID: 'bot-app',
      LARKSUITE_CLI_APP_SECRET: 'bot-secret',
      LARKSUITE_CLI_BRAND: 'feishu',
      LARKSUITE_CLI_USER_ACCESS_TOKEN: 'bot-user-token',
      LARKSUITE_CLI_TENANT_ACCESS_TOKEN: 'bot-tenant-token',
      LARKSUITE_CLI_DEFAULT_AS: 'bot',
      LARKSUITE_CLI_STRICT_MODE: 'bot',
      LARKSUITE_CLI_AUTH_PROXY: 'http://127.0.0.1:1234',
      LARKSUITE_CLI_PROXY_KEY: 'proxy-key',
      ANKOLE_RUNTIME_LARK_TENANT_ACCESS_TOKEN_FILE: '/runtime/lark-token',
      FAKE_DEVICE_CODE: longDeviceCode,
      ...overrides
    },
    stdout: 'pipe',
    stderr: 'pipe'
  })
}
