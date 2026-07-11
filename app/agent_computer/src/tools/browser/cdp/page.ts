import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'
import type { JsonObject as JSONObject } from '@pleisto/active-support'
import { CDPClient } from './client'
import { LOCAL_BROWSER_READY_STABLE_MS, SNAPSHOT_ELEMENT_MAX } from './constants'
import { writeRefs } from './session-store'
import { snapshotScript } from './snapshot'
import { isUnsupportedCDPMethod, safePath, sanitizeID, sleep, toWorkspacePath } from './utils'
import type {
  BrowserSnapshot,
  BrowserRuntimeOptions,
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
  cdp: CDPClient,
  preferredTargetID?: string,
  browserContextID?: string
): Promise<PageSession> {
  const targets = await cdp.send<{ targetInfos: TargetInfo[] }>('Target.getTargets')
  let target = preferredTargetID
    ? targets.targetInfos.find(info => info.targetID === preferredTargetID && info.type === 'page')
    : undefined
  if (!target && browserContextID) {
    target = targets.targetInfos.find(info => info.type === 'page' && info.browserContextID === browserContextID)
  }
  if (!browserContextID) {
    target ??= targets.targetInfos.find(
      info => info.type === 'page' && !info.url.startsWith('devtools://') && info.url !== 'about:blank'
    )
    target ??= targets.targetInfos.find(info => info.type === 'page' && !info.url.startsWith('devtools://'))
  }
  if (!target) {
    const created = await cdp.send<{ targetID: string }>('Target.createTarget', {
      url: 'about:blank',
      ...(browserContextID ? { browserContextID } : {})
    })
    target = { targetID: created.targetID, type: 'page', url: 'about:blank' }
  }

  const attached = await cdp.send<{ sessionID: string }>('Target.attachToTarget', {
    targetID: target.targetID,
    flatten: true
  })
  const page = { targetID: target.targetID, sessionID: attached.sessionID }
  await cdp.send('Page.enable', {}, page.sessionID)
  await refreshMainFrameID(cdp, page)
  installPageContextTracking(cdp, page)
  await cdp.send('Runtime.enable', {}, page.sessionID)
  await cdp.send('DOM.enable', {}, page.sessionID)
  await waitForMainExecutionContext(cdp, page, 1_500)
  return page
}

/**
 * Refreshes the main frame id from the CDP frame tree.
 */
async function refreshMainFrameID(cdp: CDPClient, page: PageSession): Promise<void> {
  const frameTree = await cdp.send<PageFrameTree>('Page.getFrameTree', {}, page.sessionID)
  page.mainFrameID = frameTree.frameTree.frame.id
}

/**
 * Tracks navigation and execution-context state for the attached page.
 */
function installPageContextTracking(cdp: CDPClient, page: PageSession): void {
  cdp.on('Runtime.executionContextsCleared', page.sessionID, () => {
    page.mainContextID = undefined
  })
  cdp.on('Page.frameNavigated', page.sessionID, params => {
    const event = params as unknown as PageFrameNavigatedEvent
    if (!page.mainFrameID || event.frame?.id === page.mainFrameID) {
      page.mainFrameID = event.frame?.id ?? page.mainFrameID
      page.mainContextID = undefined
    }
  })
  cdp.on('Page.frameStartedNavigating', page.sessionID, params => {
    const frameID = typeof params['frameId'] === 'string' ? params['frameId'] : undefined
    if (!page.mainFrameID || frameID === page.mainFrameID) page.mainContextID = undefined
  })
  cdp.on('Page.domContentEventFired', page.sessionID, () => {
    page.domContentEventAtUnixMs = Date.now()
  })
  cdp.on('Page.loadEventFired', page.sessionID, () => {
    page.loadEventAtUnixMs = Date.now()
  })
  cdp.on('Page.frameStoppedLoading', page.sessionID, params => {
    const frameID = typeof params['frameId'] === 'string' ? params['frameId'] : undefined
    if (!page.mainFrameID || frameID === page.mainFrameID) page.mainFrameStoppedLoadingAtUnixMs = Date.now()
  })
  cdp.on('Runtime.executionContextCreated', page.sessionID, params => {
    const event = params as unknown as RuntimeExecutionContextCreatedEvent
    const auxData = event.context?.auxData
    if (
      typeof event.context?.id === 'number' &&
      auxData?.isDefault === true &&
      auxData.frameID &&
      auxData.frameID === page.mainFrameID
    ) {
      page.mainContextID = event.context.id
    }
  })
}

/**
 * Captures the page snapshot and persists element refs for later actions.
 */
export async function captureSnapshot(
  cdp: CDPClient,
  page: PageSession,
  session: string,
  options?: BrowserRuntimeOptions
): Promise<BrowserSnapshot> {
  const snapshot = await evaluate<BrowserSnapshot>(cdp, page, `(${snapshotScript.toString()})(${SNAPSHOT_ELEMENT_MAX})`)
  writeRefs(session, snapshot.elements, options)
  return snapshot
}

/**
 * Captures a PNG screenshot into the worker workspace.
 *
 * Unsupported CDP backends report a structured unsupported result instead of
 * failing the whole browser tool call.
 */
export async function captureScreenshot(
  cdp: CDPClient,
  page: PageSession,
  session: string,
  taskID?: string,
  explicitPath?: string,
  options?: BrowserRuntimeOptions
): Promise<JSONObject> {
  let result: { data: string }
  try {
    result = await cdp.send<{ data: string }>(
      'Page.captureScreenshot',
      { format: 'png', fromSurface: true },
      page.sessionID,
      30_000
    )
  } catch (error) {
    if (isUnsupportedCDPMethod(error)) {
      return {
        screenshot_unsupported: true,
        error: 'browser backend does not support Page.captureScreenshot'
      }
    }
    throw error
  }
  const outputPath = explicitPath
    ? safePath(explicitPath, options)
    : safePath(`/workspace/user-files/browser/${session}/${sanitizeID(taskID || 'latest')}/screenshot.png`, options)
  mkdirSync(dirname(outputPath), { recursive: true })
  writeFileSync(outputPath, Buffer.from(result.data, 'base64'))
  return { screenshot_path: toWorkspacePath(outputPath, options) }
}

/**
 * Waits for a page-load signal and then a short stable period.
 *
 * Some pages miss one of the CDP lifecycle events, so the loop falls back to a
 * document.readyState probe after a short delay.
 */
export async function waitForReadyState(cdp: CDPClient, page: PageSession, timeoutMs: number): Promise<void> {
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
  cdp: CDPClient,
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
  cdp: CDPClient,
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
export async function evaluate<T>(cdp: CDPClient, page: PageSession, expression: string): Promise<T> {
  const contextID = await waitForMainExecutionContext(cdp, page, 1_500)
  const response = await cdp.send<RuntimeEvaluateResult>(
    'Runtime.evaluate',
    {
      expression,
      awaitPromise: true,
      returnByValue: true,
      userGesture: true,
      ...(contextID === undefined ? {} : { contextID })
    },
    page.sessionID
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
  cdp: CDPClient,
  page: PageSession,
  timeoutMs: number
): Promise<number | undefined> {
  if (page.mainContextID !== undefined) return page.mainContextID

  if (!page.mainFrameID) {
    try {
      await refreshMainFrameID(cdp, page)
    } catch {
      return undefined
    }
  }

  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (page.mainContextID !== undefined) return page.mainContextID
    await sleep(50)
  }
  return page.mainContextID
}
