import { chmod, mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'

const cliVersion = '1.0.86'
const registrationPath = '/oauth/v1/app/registration'
const registrationRequestTimeoutMs = 30_000
const pendingStateDirectory = '.ankole-profile-state'

const profileSetupUsage =
  'usage: profile-setup.ts profile-begin <feishu|lark> | profile-complete | auth-begin | auth-complete | clear <app-registration|auth-login>'

export type LarkBrand = 'feishu' | 'lark'

export type RegistrationBegin = {
  status: 'authorization_required'
  brand: LarkBrand
  device_code: string
  user_code: string
  verification_url: string
  expires_in: number
  interval: number
}

export type RegistrationBeginOutput = Omit<RegistrationBegin, 'device_code'>

export type RegistrationPoll =
  | {
      status: 'authorization_pending' | 'slow_down'
      brand: LarkBrand
    }
  | {
      status: 'complete'
      brand: LarkBrand
      clientID: string
      clientSecret: string
    }

type Fetcher = (input: string | URL | Request, init?: RequestInit) => Promise<Response>
type JSONObject = Record<string, unknown>
type RegistrationResponse = { data: JSONObject; httpStatus: number }

export type PendingDeviceFlowKind = 'app-registration' | 'auth-login'

type PendingDeviceFlow = {
  device_code: string
  expires_at: number
}

class RegistrationProviderError extends Error {
  constructor(
    readonly providerError: string,
    readonly providerDescription: string,
    readonly httpStatus: number,
    readonly terminal: boolean
  ) {
    super(`app registration failed: ${providerError}${providerDescription ? ` (${providerDescription})` : ''}`)
  }
}
class ExpiredDeviceFlowError extends Error {}

type CLIResult = {
  exitCode: number
  stdout: string
  stderr: string
}

export type AuthBeginResult = {
  deviceCode: string
  expiresIn: number
  output: {
    status: 'authorization_required'
    verification_url: string
    expires_in: number
    hint: string
  }
}

const endpoints: Record<LarkBrand, { accounts: string; open: string }> = {
  feishu: { accounts: 'https://accounts.feishu.cn', open: 'https://open.feishu.cn' },
  lark: { accounts: 'https://accounts.larksuite.com', open: 'https://open.larksuite.com' }
}

export async function beginAppRegistration(brand: LarkBrand, fetcher: Fetcher = fetch): Promise<RegistrationBegin> {
  const body = new URLSearchParams({
    action: 'begin',
    archetype: 'PersonalAgent',
    auth_method: 'client_secret',
    request_user_info: 'open_id tenant_brand'
  })
  const { data, httpStatus } = await postRegistration('feishu', body, fetcher)
  const error = text(data, 'error')
  if (error) {
    throw new RegistrationProviderError(error, text(data, 'error_description'), httpStatus, false)
  }
  const deviceCode = text(data, 'device_code')
  const userCode = text(data, 'user_code')
  if (!deviceCode || !userCode) throw new Error('app registration response is missing a device or user code')

  const expiresIn = positiveInteger(data.expire_in) ?? positiveInteger(data.expires_in) ?? 600
  const interval = positiveInteger(data.interval) ?? 5
  const baseURL = `${endpoints[brand].open}/page/cli?user_code=${encodeURIComponent(userCode)}`

  return {
    status: 'authorization_required',
    brand,
    device_code: deviceCode,
    user_code: userCode,
    verification_url: appendTracking(baseURL),
    expires_in: expiresIn,
    interval
  }
}

export function registrationBeginOutput(result: RegistrationBegin): RegistrationBeginOutput {
  return {
    status: result.status,
    brand: result.brand,
    user_code: result.user_code,
    verification_url: result.verification_url,
    expires_in: result.expires_in,
    interval: result.interval
  }
}

export function pendingDeviceFlowPath(configDirectory: string, profile: string, kind: PendingDeviceFlowKind): string {
  validateProfile(profile)
  return join(configDirectory, pendingStateDirectory, profile, `${kind}.json`)
}

export async function savePendingDeviceFlow(
  statePath: string,
  deviceCode: string,
  expiresIn: number,
  nowMs = Date.now()
): Promise<void> {
  if (!deviceCode) throw new Error('device code is missing')
  if (!positiveInteger(expiresIn)) throw new Error('device code expiry is invalid')

  const stateDirectory = dirname(statePath)
  await mkdir(stateDirectory, { recursive: true, mode: 0o700 })
  await chmod(dirname(stateDirectory), 0o700)
  await chmod(stateDirectory, 0o700)

  const temporaryPath = `${statePath}.tmp`
  const state: PendingDeviceFlow = {
    device_code: deviceCode,
    expires_at: nowMs + expiresIn * 1_000
  }
  await writeFile(temporaryPath, `${JSON.stringify(state)}\n`, { encoding: 'utf8', mode: 0o600 })
  await chmod(temporaryPath, 0o600)
  await rename(temporaryPath, statePath)
}

export async function loadPendingDeviceFlow(
  statePath: string,
  kind: PendingDeviceFlowKind,
  nowMs = Date.now()
): Promise<string> {
  const { description, beginCommand } = pendingFlowMessages(kind)
  let raw: string
  try {
    raw = await readFile(statePath, 'utf8')
  } catch (error) {
    if (isJSONObject(error) && error.code === 'ENOENT') {
      throw new Error(`no pending ${description}; run ${beginCommand} first`)
    }
    throw error
  }

  let state: unknown
  try {
    state = JSON.parse(raw)
  } catch {
    await clearPendingDeviceFlow(statePath)
    throw new Error(`pending ${description} state is invalid; run ${beginCommand} again`)
  }

  if (
    !isJSONObject(state) ||
    typeof state.device_code !== 'string' ||
    state.device_code.length === 0 ||
    typeof state.expires_at !== 'number' ||
    !Number.isFinite(state.expires_at)
  ) {
    await clearPendingDeviceFlow(statePath)
    throw new Error(`pending ${description} state is invalid; run ${beginCommand} again`)
  }

  if (nowMs >= state.expires_at) {
    await clearPendingDeviceFlow(statePath)
    throw new ExpiredDeviceFlowError(`${description} failed: expired_token (device code expired)`)
  }

  return state.device_code
}

export async function clearPendingDeviceFlow(statePath: string): Promise<void> {
  await rm(statePath, { force: true })
}

export function parseAuthBeginResult(stdout: string): AuthBeginResult {
  let data: unknown
  try {
    data = JSON.parse(stdout)
  } catch {
    throw new Error('lark-cli auth begin did not return JSON')
  }
  if (!isJSONObject(data)) throw new Error('lark-cli auth begin did not return a JSON object')

  const deviceCode = text(data, 'device_code')
  const verificationURL = text(data, 'verification_url')
  const expiresIn = positiveInteger(data.expires_in) ?? 600
  if (!deviceCode || !verificationURL) {
    throw new Error('lark-cli auth begin response is missing a device code or verification URL')
  }

  return {
    deviceCode,
    expiresIn,
    output: {
      status: 'authorization_required',
      verification_url: verificationURL,
      expires_in: expiresIn,
      hint: "After the user confirms authorization, run this wrapper's auth complete command."
    }
  }
}

export async function pollAppRegistration(deviceCode: string, fetcher: Fetcher = fetch): Promise<RegistrationPoll> {
  let brand: LarkBrand = 'feishu'
  let response = await pollOnce(brand, deviceCode, fetcher)
  let { data } = response
  const reportedBrand = tenantBrand(data)

  if (reportedBrand && reportedBrand !== brand) {
    brand = reportedBrand
    response = await pollOnce(brand, deviceCode, fetcher)
    data = response.data
  }

  const error = text(data, 'error')
  if (error === 'authorization_pending' || error === 'slow_down') {
    return { status: error, brand }
  }
  if (error === 'access_denied') {
    throw registrationProviderError(response, true)
  }
  if (error === 'expired_token') {
    throw registrationProviderError(response, true, 'device code expired')
  }
  if (error === 'invalid_grant') {
    throw registrationProviderError(response, true, 'device code is invalid or no longer usable')
  }
  if (error) throw registrationProviderError(response, false)

  const clientID = text(data, 'client_id')
  const clientSecret = text(data, 'client_secret')
  if (!clientID || !clientSecret) return { status: 'authorization_pending', brand }

  const finalBrand = tenantBrand(data)
  if (finalBrand && finalBrand !== brand) {
    throw new Error(`app registration returned credentials for contradictory brand ${finalBrand}`)
  }

  return { status: 'complete', brand, clientID, clientSecret }
}

async function pollOnce(brand: LarkBrand, deviceCode: string, fetcher: Fetcher): Promise<RegistrationResponse> {
  return postRegistration(brand, new URLSearchParams({ action: 'poll', device_code: deviceCode }), fetcher)
}

async function postRegistration(
  brand: LarkBrand,
  body: URLSearchParams,
  fetcher: Fetcher
): Promise<RegistrationResponse> {
  const response = await fetcher(`${endpoints[brand].accounts}${registrationPath}`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body,
    signal: AbortSignal.timeout(registrationRequestTimeoutMs)
  })
  const data: unknown = await response.json()
  if (!isJSONObject(data)) throw new Error('app registration response is not a JSON object')

  const error = text(data, 'error')
  if (!response.ok && !error) throw new Error(`app registration failed with HTTP ${response.status}`)
  return { data, httpStatus: response.status }
}

function registrationProviderError(
  response: RegistrationResponse,
  terminal: boolean,
  fallbackDescription = ''
): RegistrationProviderError {
  const providerError = text(response.data, 'error') || 'unknown_error'
  const providerDescription = text(response.data, 'error_description') || fallbackDescription
  return new RegistrationProviderError(providerError, providerDescription, response.httpStatus, terminal)
}

export function profileAddArgv(result: Extract<RegistrationPoll, { status: 'complete' }>, profile: string): string[] {
  return [
    'lark-cli',
    'profile',
    'add',
    '--name',
    profile,
    '--app-id',
    result.clientID,
    '--app-secret-stdin',
    '--brand',
    result.brand
  ]
}

async function addProfile(result: Extract<RegistrationPoll, { status: 'complete' }>, profile: string): Promise<void> {
  const child = Bun.spawn(profileAddArgv(result, profile), {
    env: Bun.env,
    stdin: 'pipe',
    stdout: 'ignore',
    stderr: 'pipe'
  })
  child.stdin.write(`${result.clientSecret}\n`)
  child.stdin.end()

  const [exitCode, stderr] = await Promise.all([child.exited, new Response(child.stderr).text()])
  if (exitCode !== 0) {
    throw new Error(
      `lark-cli could not add the registered profile: ${stderr.replaceAll(result.clientSecret, '[redacted]').trim()}`
    )
  }
}

function appendTracking(baseURL: string): string {
  return `${baseURL}&lpv=${encodeURIComponent(cliVersion)}&ocv=${encodeURIComponent(cliVersion)}&from=cli`
}

function tenantBrand(data: JSONObject): LarkBrand | undefined {
  const userInfo = data.user_info
  if (!isJSONObject(userInfo)) return undefined
  const brand = text(userInfo, 'tenant_brand').toLowerCase()
  return brand === 'lark' || brand === 'feishu' ? brand : undefined
}

function text(data: JSONObject, key: string): string {
  const value = data[key]
  return typeof value === 'string' ? value : ''
}

function positiveInteger(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isInteger(value) && value > 0 ? value : undefined
}

function isJSONObject(value: unknown): value is JSONObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function parseBrand(value: string | undefined): LarkBrand {
  if (value === 'feishu' || value === 'lark') return value
  throw new Error('brand must be feishu or lark')
}

function validateProfile(profile: string): void {
  if (!/^ankole-u-[A-Za-z0-9_-]{43}$/.test(profile)) {
    throw new Error('ANKOLE_RUNTIME_LARK_PROFILE is invalid')
  }
}

function runtimeProfile(): string {
  const profile = Bun.env.ANKOLE_RUNTIME_LARK_PROFILE
  if (!profile) throw new Error('ANKOLE_RUNTIME_LARK_PROFILE is required')
  validateProfile(profile)
  return profile
}

function runtimePendingDeviceFlowPath(kind: PendingDeviceFlowKind): string {
  const configDirectory = Bun.env.LARKSUITE_CLI_CONFIG_DIR
  if (!configDirectory) throw new Error('LARKSUITE_CLI_CONFIG_DIR is required')
  return pendingDeviceFlowPath(configDirectory, runtimeProfile(), kind)
}

function pendingFlowMessages(kind: PendingDeviceFlowKind): { description: string; beginCommand: string } {
  return kind === 'app-registration'
    ? { description: 'app registration', beginCommand: 'profile begin' }
    : { description: 'user authorization', beginCommand: 'auth begin' }
}

async function runLarkCLI(profile: string, args: string[]): Promise<CLIResult> {
  const child = Bun.spawn(['lark-cli', '--profile', profile, ...args], {
    env: Bun.env,
    stdin: 'ignore',
    stdout: 'pipe',
    stderr: 'pipe'
  })
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    new Response(child.stdout).text(),
    new Response(child.stderr).text()
  ])
  return { exitCode, stdout, stderr }
}

function writeCLIResult(result: CLIResult, redactedValue = ''): void {
  const redact = (value: string): string =>
    redactedValue ? value.replaceAll(redactedValue, '[redacted device code]') : value
  process.stdout.write(redact(result.stdout))
  process.stderr.write(redact(result.stderr))
}

async function beginUserAuthorization(profile: string): Promise<number> {
  const result = await runLarkCLI(profile, ['auth', 'login', '--domain', 'approval', '--no-wait', '--json'])
  if (result.exitCode !== 0) {
    writeCLIResult(result)
    return result.exitCode
  }

  const parsed = parseAuthBeginResult(result.stdout)
  await savePendingDeviceFlow(runtimePendingDeviceFlowPath('auth-login'), parsed.deviceCode, parsed.expiresIn)
  process.stderr.write(result.stderr.replaceAll(parsed.deviceCode, '[redacted device code]'))
  process.stdout.write(`${JSON.stringify(parsed.output)}\n`)
  return 0
}

async function completeUserAuthorization(profile: string): Promise<number> {
  const statePath = runtimePendingDeviceFlowPath('auth-login')
  const deviceCode = await loadPendingDeviceFlow(statePath, 'auth-login')
  const result = await runLarkCLI(profile, ['auth', 'login', '--device-code', deviceCode, '--json'])
  writeCLIResult(result, deviceCode)

  if (result.exitCode === 0 || !`${result.stdout}\n${result.stderr}`.includes('Polling was cancelled')) {
    await clearPendingDeviceFlow(statePath)
  }
  return result.exitCode
}

async function beginProfileRegistration(brand: LarkBrand): Promise<number> {
  const result = await beginAppRegistration(brand)
  await savePendingDeviceFlow(runtimePendingDeviceFlowPath('app-registration'), result.device_code, result.expires_in)
  process.stdout.write(`${JSON.stringify(registrationBeginOutput(result))}\n`)
  return 0
}

async function completeProfileRegistration(profile: string): Promise<number> {
  const statePath = runtimePendingDeviceFlowPath('app-registration')
  const deviceCode = await loadPendingDeviceFlow(statePath, 'app-registration')

  let result: RegistrationPoll
  try {
    result = await pollAppRegistration(deviceCode)
  } catch (error) {
    if (error instanceof RegistrationProviderError && error.terminal) {
      await clearPendingDeviceFlow(statePath)
    }
    throw error
  }
  if (result.status !== 'complete') {
    process.stdout.write(`${JSON.stringify(result)}\n`)
    return 3
  }

  try {
    await addProfile(result, profile)
  } finally {
    await clearPendingDeviceFlow(statePath)
  }
  process.stdout.write(`${JSON.stringify({ status: 'configured', brand: result.brand, app_id: result.clientID })}\n`)
  return 0
}

async function main(): Promise<number> {
  const [command, value, ...rest] = process.argv.slice(2)
  const profile = runtimeProfile()

  if (command === 'profile-begin') {
    if (rest.length > 0) throw new Error(profileSetupUsage)
    return beginProfileRegistration(parseBrand(value))
  }

  if (command === 'profile-complete') {
    if (value || rest.length > 0) throw new Error(profileSetupUsage)
    return completeProfileRegistration(profile)
  }

  if (command === 'auth-begin') {
    if (value || rest.length > 0) throw new Error(profileSetupUsage)
    return beginUserAuthorization(profile)
  }

  if (command === 'auth-complete') {
    if (value || rest.length > 0) throw new Error(profileSetupUsage)
    return completeUserAuthorization(profile)
  }

  if (command === 'clear') {
    if ((value !== 'app-registration' && value !== 'auth-login') || rest.length > 0) {
      throw new Error(profileSetupUsage)
    }
    await clearPendingDeviceFlow(runtimePendingDeviceFlowPath(value))
    return 0
  }

  throw new Error(profileSetupUsage)
}

if (import.meta.main) {
  try {
    process.exit(await main())
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    const output: JSONObject = { status: 'error', error: message }
    if (error instanceof RegistrationProviderError) {
      output.provider_error = error.providerError
      output.provider_error_description = error.providerDescription
      output.http_status = error.httpStatus
    }
    console.error(JSON.stringify(output))
    process.exit(1)
  }
}
