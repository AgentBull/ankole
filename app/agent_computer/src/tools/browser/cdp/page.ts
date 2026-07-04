import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'
import { CdpClient } from './client'
import { LOCAL_BROWSER_READY_STABLE_MS, SNAPSHOT_ELEMENT_MAX } from './constants'
import { writeRefs } from './session-store'
import { snapshotScript } from './snapshot'
import { isUnsupportedCdpMethod, safePath, sanitizeId, sleep, toWorkspacePath } from './utils'
import type {
  BrowserSnapshot,
  JsonObject,
  PageFrameNavigatedEvent,
  PageFrameTree,
  PageSession,
  RuntimeEvaluateResult,
  RuntimeExecutionContextCreatedEvent,
  TargetInfo
} from './types'

/**
 * Attaches to the preferred page target or creates a blank page.
 *
 * The target selection prefers the persisted target id, then the session's
 * BrowserContext, then a non-devtools page. This keeps existing sessions stable
 * while still recovering from missing page targets.
 */
export async function attachPage(
  cdp: CdpClient,
  preferredTargetId?: string,
  browserContextId?: string
): Promise<PageSession> {
  const targets = await cdp.send<{ targetInfos: TargetInfo[] }>('Target.getTargets')
  let target = preferredTargetId
    ? targets.targetInfos.find(info => info.targetId === preferredTargetId && info.type === 'page')
    : undefined
  if (!target && browserContextId) {
    target = targets.targetInfos.find(info => info.type === 'page' && info.browserContextId === browserContextId)
  }
  if (!browserContextId) {
    target ??= targets.targetInfos.find(
      info => info.type === 'page' && !info.url.startsWith('devtools://') && info.url !== 'about:blank'
    )
    target ??= targets.targetInfos.find(info => info.type === 'page' && !info.url.startsWith('devtools://'))
  }
  if (!target) {
    const created = await cdp.send<{ targetId: string }>('Target.createTarget', {
      url: 'about:blank',
      ...(browserContextId ? { browserContextId } : {})
    })
    target = { targetId: created.targetId, type: 'page', url: 'about:blank' }
  }

  const attached = await cdp.send<{ sessionId: string }>('Target.attachToTarget', {
    targetId: target.targetId,
    flatten: true
  })
  const page = { targetId: target.targetId, sessionId: attached.sessionId }
  await cdp.send('Page.enable', {}, page.sessionId)
  await refreshMainFrameId(cdp, page)
  installPageContextTracking(cdp, page)
  await cdp.send('Runtime.enable', {}, page.sessionId)
  await cdp.send('DOM.enable', {}, page.sessionId)
  await waitForMainExecutionContext(cdp, page, 1_500)
  return page
}

/**
 * Refreshes the main frame id from the CDP frame tree.
 */
async function refreshMainFrameId(cdp: CdpClient, page: PageSession): Promise<void> {
  const frameTree = await cdp.send<PageFrameTree>('Page.getFrameTree', {}, page.sessionId)
  page.mainFrameId = frameTree.frameTree.frame.id
}

/**
 * Tracks navigation and execution-context state for the attached page.
 */
function installPageContextTracking(cdp: CdpClient, page: PageSession): void {
  cdp.on('Runtime.executionContextsCleared', page.sessionId, () => {
    page.mainContextId = undefined
  })
  cdp.on('Page.frameNavigated', page.sessionId, params => {
    const event = params as unknown as PageFrameNavigatedEvent
    if (!page.mainFrameId || event.frame?.id === page.mainFrameId) {
      page.mainFrameId = event.frame?.id ?? page.mainFrameId
      page.mainContextId = undefined
    }
  })
  cdp.on('Page.frameStartedNavigating', page.sessionId, params => {
    const frameId = typeof params['frameId'] === 'string' ? params['frameId'] : undefined
    if (!page.mainFrameId || frameId === page.mainFrameId) page.mainContextId = undefined
  })
  cdp.on('Page.domContentEventFired', page.sessionId, () => {
    page.domContentEventAtUnixMs = Date.now()
  })
  cdp.on('Page.loadEventFired', page.sessionId, () => {
    page.loadEventAtUnixMs = Date.now()
  })
  cdp.on('Page.frameStoppedLoading', page.sessionId, params => {
    const frameId = typeof params['frameId'] === 'string' ? params['frameId'] : undefined
    if (!page.mainFrameId || frameId === page.mainFrameId) page.mainFrameStoppedLoadingAtUnixMs = Date.now()
  })
  cdp.on('Runtime.executionContextCreated', page.sessionId, params => {
    const event = params as unknown as RuntimeExecutionContextCreatedEvent
    const auxData = event.context?.auxData
    if (
      typeof event.context?.id === 'number' &&
      auxData?.isDefault === true &&
      auxData.frameId &&
      auxData.frameId === page.mainFrameId
    ) {
      page.mainContextId = event.context.id
    }
  })
}

/**
 * Captures the page snapshot and persists element refs for later actions.
 */
export async function captureSnapshot(cdp: CdpClient, page: PageSession, session: string): Promise<BrowserSnapshot> {
  const snapshot = await evaluate<BrowserSnapshot>(cdp, page, `(${snapshotScript.toString()})(${SNAPSHOT_ELEMENT_MAX})`)
  writeRefs(session, snapshot.elements)
  return snapshot
}

/**
 * Captures a PNG screenshot into the worker workspace.
 *
 * Unsupported CDP backends report a structured unsupported result instead of
 * failing the whole browser tool call.
 */
export async function captureScreenshot(
  cdp: CdpClient,
  page: PageSession,
  session: string,
  taskId?: string,
  explicitPath?: string
): Promise<JsonObject> {
  let result: { data: string }
  try {
    result = await cdp.send<{ data: string }>(
      'Page.captureScreenshot',
      { format: 'png', fromSurface: true },
      page.sessionId,
      30_000
    )
  } catch (error) {
    if (isUnsupportedCdpMethod(error)) {
      return {
        screenshot_unsupported: true,
        error: 'browser backend does not support Page.captureScreenshot'
      }
    }
    throw error
  }
  const outputPath = explicitPath
    ? safePath(explicitPath)
    : safePath(`/workspace/user-files/browser/${session}/${sanitizeId(taskId || 'latest')}/screenshot.png`)
  mkdirSync(dirname(outputPath), { recursive: true })
  writeFileSync(outputPath, Buffer.from(result.data, 'base64'))
  return { screenshot_path: toWorkspacePath(outputPath) }
}

/**
 * Waits for a page-load signal and then a short stable period.
 *
 * Some pages miss one of the CDP lifecycle events, so the loop falls back to a
 * document.readyState probe after a short delay.
 */
export async function waitForReadyState(cdp: CdpClient, page: PageSession, timeoutMs: number): Promise<void> {
  const started = Date.now()
  let nextFallbackProbeAt = started + 2_000
  while (Date.now() - started < timeoutMs) {
    if (await pageReady(cdp, page, { sinceUnixMs: started, allowProbe: false })) {
      await sleep(LOCAL_BROWSER_READY_STABLE_MS)
      return
    }

    if (Date.now() >= nextFallbackProbeAt) {
      nextFallbackProbeAt = Date.now() + 1_000
      if (await pageReady(cdp, page, { sinceUnixMs: started, allowProbe: true })) {
        await sleep(LOCAL_BROWSER_READY_STABLE_MS)
        return
      }
    }
    await sleep(250)
  }
}

/**
 * Checks whether the page appears ready according to tracked events or a direct
 * DOM probe.
 */
async function pageReady(
  cdp: CdpClient,
  page: PageSession,
  opts: { sinceUnixMs?: number; allowProbe?: boolean } = {}
): Promise<boolean> {
  const sinceUnixMs = opts.sinceUnixMs ?? 0
  if (
    (page.loadEventAtUnixMs !== undefined && page.loadEventAtUnixMs >= sinceUnixMs) ||
    (page.domContentEventAtUnixMs !== undefined && page.domContentEventAtUnixMs >= sinceUnixMs) ||
    (page.mainFrameStoppedLoadingAtUnixMs !== undefined && page.mainFrameStoppedLoadingAtUnixMs >= sinceUnixMs)
  ) {
    return true
  }

  if (opts.allowProbe !== true) return false

  const readyState = await evaluate<string>(cdp, page, 'document.readyState')
  return readyState === 'complete' || readyState === 'interactive'
}

/**
 * Waits for the requested browser_wait condition.
 */
export async function waitPredicate(
  cdp: CdpClient,
  page: PageSession,
  args: { kind?: string; text?: string; selector?: string },
  opts: { allowReadyProbe?: boolean } = {}
): Promise<boolean> {
  if (args.kind === 'text') {
    const text = args.text ?? ''
    return await evaluate<boolean>(cdp, page, `(document.body?.innerText || '').includes(${JSON.stringify(text)})`)
  }

  if (args.kind === 'selector') {
    const selector = args.selector ?? ''
    return await evaluate<boolean>(cdp, page, `Boolean(document.querySelector(${JSON.stringify(selector)}))`)
  }

  return await pageReady(cdp, page, { allowProbe: opts.allowReadyProbe === true })
}

/**
 * Evaluates JavaScript in the main page context and returns the by-value result.
 */
export async function evaluate<T>(cdp: CdpClient, page: PageSession, expression: string): Promise<T> {
  const contextId = await waitForMainExecutionContext(cdp, page, 1_500)
  const response = await cdp.send<RuntimeEvaluateResult>(
    'Runtime.evaluate',
    {
      expression,
      awaitPromise: true,
      returnByValue: true,
      userGesture: true,
      ...(contextId === undefined ? {} : { contextId })
    },
    page.sessionId
  )

  if (response.exceptionDetails) {
    throw new Error(
      response.exceptionDetails.exception?.description || response.exceptionDetails.text || 'browser evaluation failed'
    )
  }

  return response.result.value as T
}

/**
 * Waits briefly for the main execution context after navigation.
 *
 * Returning undefined is acceptable because CDP can still evaluate in the
 * default context; using the context id is a best-effort stability improvement.
 */
async function waitForMainExecutionContext(
  cdp: CdpClient,
  page: PageSession,
  timeoutMs: number
): Promise<number | undefined> {
  if (page.mainContextId !== undefined) return page.mainContextId

  if (!page.mainFrameId) {
    try {
      await refreshMainFrameId(cdp, page)
    } catch {
      return undefined
    }
  }

  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (page.mainContextId !== undefined) return page.mainContextId
    await sleep(50)
  }
  return page.mainContextId
}
