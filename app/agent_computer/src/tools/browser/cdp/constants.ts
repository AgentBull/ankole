export const workspaceRoot = process.env.ANKOLE_WORKSPACE_ROOT || '/workspace'
export const SNAPSHOT_TEXT_MAX = 6_000
export const SNAPSHOT_ELEMENT_MAX = 200
export const DEFAULT_BROWSER_COMMAND_TIMEOUT_MS = 30_000
export const DEFAULT_WAIT_MS = DEFAULT_BROWSER_COMMAND_TIMEOUT_MS
export const DEFAULT_CDP_CONNECT_TIMEOUT_MS = 30_000
export const REMOTE_CONFIG_ENV = 'ANKOLE_REMOTE_BROWSER_CDP_CONFIG_JSON'
export const DEFAULT_LOCAL_BROWSER_IDLE_TTL_MS = 30 * 60_000
export const LOCAL_BROWSER_READY_STABLE_MS = 750
export const BROWSER_NAVIGATION_ATTEMPTS = 2
export const LOCAL_CHROMIUM_SIDECAR_KEY = 'browser.chromium'
export const LOCAL_CHROMIUM_USER_AGENT =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36 Edg/150.0.4078.48'
