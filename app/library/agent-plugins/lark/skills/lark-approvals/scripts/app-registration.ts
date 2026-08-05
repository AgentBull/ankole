const cliVersion = '1.0.84'
const registrationPath = '/oauth/v1/app/registration'
const registrationRequestTimeoutMs = 30_000

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
  const data = await postRegistration('feishu', body, fetcher)
  const error = text(data, 'error')
  if (error) throw new Error(text(data, 'error_description') || `app registration failed: ${error}`)
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

export async function pollAppRegistration(deviceCode: string, fetcher: Fetcher = fetch): Promise<RegistrationPoll> {
  let brand: LarkBrand = 'feishu'
  let data = await pollOnce(brand, deviceCode, fetcher)
  const reportedBrand = tenantBrand(data)

  if (reportedBrand && reportedBrand !== brand) {
    brand = reportedBrand
    data = await pollOnce(brand, deviceCode, fetcher)
  }

  const error = text(data, 'error')
  if (error === 'authorization_pending' || error === 'slow_down') {
    return { status: error, brand }
  }
  if (error === 'access_denied') throw new Error('app registration was denied')
  if (error === 'expired_token' || error === 'invalid_grant') {
    throw new Error('app registration device code expired')
  }
  if (error) throw new Error(text(data, 'error_description') || `app registration failed: ${error}`)

  const clientID = text(data, 'client_id')
  const clientSecret = text(data, 'client_secret')
  if (!clientID || !clientSecret) return { status: 'authorization_pending', brand }

  const finalBrand = tenantBrand(data)
  if (finalBrand && finalBrand !== brand) {
    throw new Error(`app registration returned credentials for contradictory brand ${finalBrand}`)
  }

  return { status: 'complete', brand, clientID, clientSecret }
}

async function pollOnce(brand: LarkBrand, deviceCode: string, fetcher: Fetcher): Promise<JSONObject> {
  return postRegistration(brand, new URLSearchParams({ action: 'poll', device_code: deviceCode }), fetcher)
}

async function postRegistration(brand: LarkBrand, body: URLSearchParams, fetcher: Fetcher): Promise<JSONObject> {
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
  return data
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

async function main(): Promise<number> {
  const [command, value] = process.argv.slice(2)

  if (command === 'begin') {
    process.stdout.write(`${JSON.stringify(await beginAppRegistration(parseBrand(value)))}\n`)
    return 0
  }

  if (command === 'complete') {
    if (!value) throw new Error('device code is required')
    const profile = Bun.env.ANKOLE_RUNTIME_LARK_PROFILE
    if (!profile) throw new Error('ANKOLE_RUNTIME_LARK_PROFILE is required')

    const result = await pollAppRegistration(value)
    if (result.status !== 'complete') {
      process.stdout.write(`${JSON.stringify(result)}\n`)
      return 3
    }

    await addProfile(result, profile)
    process.stdout.write(`${JSON.stringify({ status: 'configured', brand: result.brand, app_id: result.clientID })}\n`)
    return 0
  }

  throw new Error('usage: app-registration.ts begin <feishu|lark> | complete <device-code>')
}

if (import.meta.main) {
  try {
    process.exit(await main())
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    console.error(JSON.stringify({ status: 'error', error: message }))
    process.exit(1)
  }
}
