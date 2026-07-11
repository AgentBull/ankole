import type { JsonObject as JSONObject } from '@pleisto/active-support'

export type BrowserBackend = 'chromium' | 'remote_cdp'
export type BrowserAdapterKind = 'chromium' | 'cdp_endpoint' | 'cdp_session_request'
export type RemoteSessionResponse = { type: 'text' } | { type: 'json'; path: string[] }

export interface BrowserSessionMeta {
  version: 1
  session: string
  backend: BrowserBackend
  adapter: BrowserAdapterKind
  local_sidecar_key?: string
  pid: number | null
  connect_url?: string
  connect_url_redacted?: string
  connect_url_source?: 'session' | 'config'
  browser_context_id?: string
  target_id?: string
  profile_dir?: string
  started_at_unix_ms: number
}

export type RemoteBrowserCDPConfig =
  | {
      adapter: 'cdp_endpoint'
      endpoint_url: string
      headers?: Record<string, string>
      connect_timeout_ms?: number
    }
  | {
      adapter: 'cdp_session_request'
      request: {
        url: string
        method?: 'GET' | 'POST'
        headers?: Record<string, string>
        body?: JSONObject
        response?: RemoteSessionResponse
      }
      headers?: Record<string, string>
      connect_timeout_ms?: number
    }

export interface BrowserRuntimeOptions {
  workspaceRoot?: string
  remoteCDPConfig?: JSONObject | RemoteBrowserCDPConfig | null
  localBrowserIdleTtlMs?: number
}

export interface BrowserConnection {
  backend: BrowserBackend
  adapter: BrowserAdapterKind
  connectURL: string
  redactedConnectURL: string
  headers?: Record<string, string>
}

export interface BrowserRef {
  ref: string
  selector: string
  tag: string
  role: string
  name: string
  disabled: boolean
}

export interface BrowserSnapshot {
  url: string
  title: string
  text: string
  elements: BrowserRef[]
}

export interface BrowserFindMatch {
  line: number
  text: string
  before: string[]
  after: string[]
}

export interface PageSession {
  targetID: string
  sessionID: string
  mainFrameID?: string
  mainContextID?: number
  domContentEventAtUnixMs?: number
  loadEventAtUnixMs?: number
  mainFrameStoppedLoadingAtUnixMs?: number
}

export interface TargetInfo {
  targetID: string
  type: string
  url: string
  title?: string
  attached?: boolean
  browserContextID?: string
}

export interface RuntimeEvaluateResult {
  result: {
    type: string
    value?: unknown
    description?: string
  }
  exceptionDetails?: {
    text?: string
    exception?: { description?: string }
  }
}

export interface PageNavigateResult {
  frameID: string
  loaderID?: string
  errorText?: string
}

export interface PageFrameTree {
  frameTree: {
    frame: { id: string }
    childFrames?: PageFrameTree['frameTree'][]
  }
}

export interface RuntimeExecutionContextCreatedEvent {
  context: {
    id: number
    auxData?: {
      isDefault?: boolean
      type?: string
      frameID?: string
    }
  }
}

export interface PageFrameNavigatedEvent {
  frame: { id: string }
}

export interface LocalChromiumSidecar {
  key: string
  port: number
  proc: Bun.Subprocess<'ignore', 'pipe', 'pipe'>
  connectURL: string
  cdpHTTPURL: string
  profileDir: string
  startedAtUnixMs: number
  lastUsedAtUnixMs: number
  idleTtlMs: number
  idleTimer?: ReturnType<typeof setTimeout>
}
