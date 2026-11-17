import type { CDPSession, Frame, Page } from 'playwright-core'
import { BrowserDataError } from '../errors'

export type WebMCPToolSummary = {
  name: string
  description: string
  title?: string
  frame_id?: string
  input_schema?: unknown
  annotations?: Record<string, unknown>
}

export type WebMCPListResult = {
  supported: boolean
  protocol: 'cdp' | 'model_context' | 'declarative_dom' | 'none'
  tools: WebMCPToolSummary[]
}

export type WebMCPCallResult = {
  protocol: 'cdp' | 'model_context' | 'declarative_dom'
  tool: string
  output: unknown
}

type CDPWebMCPTool = {
  name?: unknown
  description?: unknown
  frameId?: unknown
  inputSchema?: unknown
  annotations?: unknown
}

type CDPToolsAddedEvent = {
  tools?: CDPWebMCPTool[]
}

type CDPToolsRemovedEvent = {
  tools?: Array<{ name?: unknown; frameId?: unknown }>
}

type CDPFrameTreeNode = {
  frame?: {
    id?: string
    name?: string
    url?: string
  }
  childFrames?: CDPFrameTreeNode[]
}

type CDPToolRespondedEvent = {
  invocationId?: unknown
  status?: unknown
  output?: unknown
  errorText?: unknown
}

type CDPWebMCPEmitter = {
  on(event: string, listener: (payload: never) => void): void
}

type WebMCPCDPContext = {
  cdp: CDPSession
  registry: CDPToolRegistry
  targetFrameId: string
  mainFrameId: string
}

const CDPSettleQuietWindowMs = 8
const CDPMaxDiscoveryWaitMs = 250

export async function listWebMCPTools(page: Page, frame: Frame, deadline: number): Promise<WebMCPListResult> {
  let pageRealmPromise: Promise<WebMCPListResult> | undefined
  const readPageRealm = (): Promise<WebMCPListResult> => {
    pageRealmPromise ??= listPageRealmWebMCPTools(frame, deadline)
    return pageRealmPromise
  }

  const cdpTools = await tryListCDPWebMCPTools(page, frame, deadline, readPageRealm)
  if (cdpTools && cdpTools.length > 0) {
    return { supported: true, protocol: 'cdp', tools: cdpTools }
  }
  const pageRealm = await readPageRealm()
  if (pageRealm.supported || cdpTools === undefined) {
    return pageRealm
  }
  return { supported: true, protocol: 'cdp', tools: cdpTools }
}

export async function callWebMCPTool(
  page: Page,
  frame: Frame,
  toolName: string,
  input: Record<string, unknown>,
  deadline: number
): Promise<WebMCPCallResult> {
  const cdpResult = await tryCallCDPWebMCPTool(page, frame, toolName, input, deadline)
  if (cdpResult !== undefined) return cdpResult
  return await callPageRealmWebMCPTool(frame, toolName, input, deadline)
}

async function openCDPSessionIfSupported(page: Page): Promise<CDPSession | undefined> {
  const context = typeof page.context === 'function' ? page.context() : undefined
  if (!context || typeof context.newCDPSession !== 'function') return undefined
  try {
    return await context.newCDPSession(page)
  } catch {
    return undefined
  }
}

class CDPToolRegistry {
  private readonly byFrameAndName = new Map<string, { rawFrameId?: string; summary: WebMCPToolSummary }>()
  private readonly listeners = new Set<() => void>()

  addEvent(event: CDPToolsAddedEvent): void {
    let changed = false
    for (const raw of event.tools ?? []) {
      const normalized = normalizeCDPTool(raw)
      if (!normalized) continue
      const key = this.keyOf(normalized.frame_id, normalized.name)
      this.byFrameAndName.set(key, { rawFrameId: normalized.frame_id, summary: normalized })
      changed = true
    }
    if (changed) this.notify()
  }

  removeEvent(event: CDPToolsRemovedEvent): void {
    let changed = false
    for (const raw of event.tools ?? []) {
      if (!raw || typeof raw.name !== 'string' || !raw.name) continue
      const rawFrameId = typeof raw.frameId === 'string' && raw.frameId ? raw.frameId : undefined
      if (this.byFrameAndName.delete(this.keyOf(rawFrameId, raw.name))) {
        changed = true
      }
    }
    if (changed) this.notify()
  }

  toolsForFrame(targetFrameId: string, mainFrameId: string): WebMCPToolSummary[] {
    const matches: WebMCPToolSummary[] = []
    for (const entry of this.byFrameAndName.values()) {
      const effectiveFrameId = entry.rawFrameId ?? mainFrameId
      if (effectiveFrameId === targetFrameId) {
        matches.push(entry.summary)
      }
    }
    return matches
  }

  findTool(targetFrameId: string, mainFrameId: string, toolName: string): WebMCPToolSummary | undefined {
    const exact = this.byFrameAndName.get(this.keyOf(targetFrameId, toolName))
    if (exact) return exact.summary
    if (targetFrameId === mainFrameId) {
      return this.byFrameAndName.get(this.keyOf(undefined, toolName))?.summary
    }
    return undefined
  }

  waitForChange(predicate: () => boolean, maxWaitMs: number, settleMs = 0): Promise<boolean> {
    if (predicate() && settleMs <= 0) return Promise.resolve(true)
    if (maxWaitMs <= 0) return Promise.resolve(predicate())

    return new Promise<boolean>(resolve => {
      let finished = false
      let settleTimer: ReturnType<typeof setTimeout> | undefined
      const budgetTimer = setTimeout(() => finish(predicate()), maxWaitMs)
      budgetTimer.unref()

      const finish = (matched: boolean) => {
        if (finished) return
        finished = true
        clearTimeout(budgetTimer)
        if (settleTimer) clearTimeout(settleTimer)
        this.listeners.delete(onUpdate)
        resolve(matched)
      }

      const scheduleSettle = () => {
        if (settleMs <= 0) {
          finish(true)
          return
        }
        if (settleTimer) clearTimeout(settleTimer)
        settleTimer = setTimeout(() => finish(true), Math.min(settleMs, Math.max(1, maxWaitMs)))
        settleTimer.unref()
      }

      const onUpdate = () => {
        if (predicate()) scheduleSettle()
      }

      this.listeners.add(onUpdate)
      if (predicate()) scheduleSettle()
    })
  }

  private keyOf(frameId: string | undefined, name: string): string {
    return `${frameId ?? ''}\u0000${name}`
  }

  private notify(): void {
    for (const listener of this.listeners) {
      listener()
    }
  }
}

function resolveTargetCDPFrameIds(
  page: Page,
  targetFrame: Frame,
  rootNode: CDPFrameTreeNode | undefined
): { targetFrameId: string; mainFrameId: string } {
  const mainFrameId = rootNode?.frame?.id || 'main'
  const explicitFrameId = (targetFrame as Frame & { _cdpFrameId?: string })._cdpFrameId
  if (typeof explicitFrameId === 'string' && explicitFrameId.length > 0) {
    return { targetFrameId: explicitFrameId, mainFrameId }
  }

  const mainFrame = typeof page.mainFrame === 'function' ? page.mainFrame() : undefined
  if (!mainFrame || targetFrame === mainFrame || !rootNode) {
    return { targetFrameId: mainFrameId, mainFrameId }
  }

  const matched = matchFrameInTree(mainFrame, rootNode, targetFrame)
  if (matched) {
    return { targetFrameId: matched, mainFrameId }
  }

  throw new BrowserDataError('stale_ref', 'unable to resolve CDP frame identity for selected frame')
}

function matchFrameInTree(pwParent: Frame, cdpParent: CDPFrameTreeNode, target: Frame): string | undefined {
  if (pwParent === target) return cdpParent.frame?.id
  const pwChildren = typeof pwParent.childFrames === 'function' ? pwParent.childFrames() : []
  const cdpChildren = cdpParent.childFrames ?? []
  if (pwChildren.length === 0 || cdpChildren.length === 0) return undefined

  const usedCdpIndices = new Set<number>()
  for (const pwChild of pwChildren) {
    const childName = typeof pwChild.name === 'function' ? pwChild.name() : ''
    const childUrl = typeof pwChild.url === 'function' ? pwChild.url() : ''

    let idx = -1
    if (childName) {
      idx = cdpChildren.findIndex((node, i) => !usedCdpIndices.has(i) && (node.frame?.name ?? '') === childName)
    }
    if (idx === -1 && childUrl) {
      idx = cdpChildren.findIndex(
        (node, i) =>
          !usedCdpIndices.has(i) && (node.frame?.name ?? '') === childName && (node.frame?.url ?? '') === childUrl
      )
    }
    if (idx === -1) {
      idx = cdpChildren.findIndex((_, i) => !usedCdpIndices.has(i))
    }
    if (idx === -1) continue

    usedCdpIndices.add(idx)
    const found = matchFrameInTree(pwChild, cdpChildren[idx]!, target)
    if (found) return found
  }
  return undefined
}

async function hasPageRealmSupport(readPageRealm: () => Promise<WebMCPListResult>, deadline: number): Promise<boolean> {
  if (Date.now() >= deadline) return false
  try {
    const probe = await readPageRealm()
    return probe.supported
  } catch {
    return false
  }
}

async function withWebMCPCDPSession<T>(
  page: Page,
  frame: Frame,
  deadline: number,
  options: {
    beforeEnable?: (emitter: CDPWebMCPEmitter) => void
    run: (context: WebMCPCDPContext) => Promise<T>
  }
): Promise<{ supported: false } | { supported: true; value: T }> {
  const cdp = await openCDPSessionIfSupported(page)
  if (!cdp) return { supported: false }

  const registry = new CDPToolRegistry()
  const emitter: CDPWebMCPEmitter = {
    on: (event, listener) => {
      cdp.on(event as Parameters<CDPSession['on']>[0], listener as Parameters<CDPSession['on']>[1])
    }
  }
  emitter.on('WebMCP.toolsAdded', (payload => registry.addEvent(payload)) as (payload: never) => void)
  emitter.on('WebMCP.toolsRemoved', (payload => registry.removeEvent(payload)) as (payload: never) => void)
  options.beforeEnable?.(emitter)

  try {
    try {
      await sendWithDeadline(cdp, 'WebMCP.enable', {}, deadline)
    } catch (error) {
      if (isMethodUnsupported(error)) return { supported: false }
      throw toWebMCPError(error)
    }

    try {
      const frameTree = (await sendWithDeadline(cdp, 'Page.getFrameTree', {}, deadline).catch(() => undefined)) as
        | { frameTree?: CDPFrameTreeNode }
        | undefined
      const { targetFrameId, mainFrameId } = resolveTargetCDPFrameIds(page, frame, frameTree?.frameTree)
      const value = await options.run({ cdp, registry, targetFrameId, mainFrameId })
      return { supported: true, value }
    } finally {
      await cdp.send('WebMCP.disable' as Parameters<CDPSession['send']>[0]).catch(() => undefined)
    }
  } finally {
    await cdp.detach().catch(() => undefined)
  }
}

async function tryListCDPWebMCPTools(
  page: Page,
  frame: Frame,
  deadline: number,
  readPageRealm: () => Promise<WebMCPListResult>
): Promise<WebMCPToolSummary[] | undefined> {
  const session = await withWebMCPCDPSession(page, frame, deadline, {
    run: async ({ registry, targetFrameId, mainFrameId }) => {
      if (registry.toolsForFrame(targetFrameId, mainFrameId).length === 0) {
        const pageRealmSupported = await hasPageRealmSupport(readPageRealm, deadline)
        if (!pageRealmSupported) {
          const waitBudget = Math.min(CDPMaxDiscoveryWaitMs, Math.max(0, deadline - Date.now()))
          await registry.waitForChange(
            () => registry.toolsForFrame(targetFrameId, mainFrameId).length > 0,
            waitBudget,
            CDPSettleQuietWindowMs
          )
        }
      } else {
        const settleBudget = Math.min(CDPSettleQuietWindowMs, Math.max(0, deadline - Date.now()))
        await registry.waitForChange(() => true, settleBudget, settleBudget)
      }
      return registry.toolsForFrame(targetFrameId, mainFrameId)
    }
  })
  return session.supported ? session.value : undefined
}

async function tryCallCDPWebMCPTool(
  page: Page,
  frame: Frame,
  toolName: string,
  input: Record<string, unknown>,
  deadline: number
): Promise<WebMCPCallResult | undefined> {
  let targetInvocationId: string | undefined
  let resolveResponse: ((event: CDPToolRespondedEvent) => void) | undefined
  const bufferedResponses = new Map<string, CDPToolRespondedEvent>()
  const onResponded = (event: CDPToolRespondedEvent): void => {
    const id = typeof event.invocationId === 'string' ? event.invocationId : undefined
    if (!id) return
    if (targetInvocationId && id === targetInvocationId && resolveResponse) {
      resolveResponse(event)
      return
    }
    bufferedResponses.set(id, event)
  }

  const session = await withWebMCPCDPSession(page, frame, deadline, {
    beforeEnable: emitter => {
      emitter.on('WebMCP.toolResponded', onResponded as (payload: never) => void)
    },
    run: async ({ cdp, registry, targetFrameId, mainFrameId }) => {
      let matchedTool = registry.findTool(targetFrameId, mainFrameId, toolName)
      if (!matchedTool) {
        const pageRealmSupported = await hasPageRealmSupport(() => listPageRealmWebMCPTools(frame, deadline), deadline)
        if (!pageRealmSupported) {
          const waitBudget = Math.min(CDPMaxDiscoveryWaitMs, Math.max(0, deadline - Date.now()))
          await registry.waitForChange(
            () => registry.findTool(targetFrameId, mainFrameId, toolName) !== undefined,
            waitBudget
          )
          matchedTool = registry.findTool(targetFrameId, mainFrameId, toolName)
        }
      }

      // When a Chromium build exposes the CDP WebMCP domain without Blink's page-realm flags enabled,
      // WebMCP.toolsAdded stays empty for this frame; fall through to page-realm navigator.modelContext / declarative forms.
      if (!matchedTool) {
        return undefined
      }

      const frameId = matchedTool.frame_id ?? targetFrameId
      const invoked = (await sendWithDeadline(cdp, 'WebMCP.invokeTool', { frameId, toolName, input }, deadline)) as {
        invocationId?: unknown
      }
      const invocationId = typeof invoked?.invocationId === 'string' ? invoked.invocationId : undefined
      if (!invocationId) {
        throw new BrowserDataError('invalid_result', 'WebMCP.invokeTool did not return an invocationId')
      }
      targetInvocationId = invocationId

      let responded = bufferedResponses.get(invocationId)
      if (!responded) {
        let timer: ReturnType<typeof setTimeout> | undefined
        try {
          responded = await new Promise<CDPToolRespondedEvent>((resolve, reject) => {
            resolveResponse = resolve
            timer = setTimeout(
              () => {
                void cdp
                  .send('WebMCP.cancelInvocation' as Parameters<CDPSession['send']>[0], { invocationId } as never)
                  .catch(() => undefined)
                reject(new BrowserDataError('timeout', `WebMCP tool ${toolName} timed out`, { retryable: true }))
              },
              Math.max(1, deadline - Date.now())
            )
            timer.unref()
          })
        } finally {
          resolveResponse = undefined
          if (timer) clearTimeout(timer)
        }
      }

      if (responded.status !== 'Completed') {
        const errorMessage =
          typeof responded.errorText === 'string' && responded.errorText.length > 0
            ? responded.errorText
            : `WebMCP tool ${toolName} failed (${String(responded.status ?? 'Error')})`
        const code = /no such tool|not found/i.test(errorMessage) ? 'invalid_command' : 'invalid_result'
        throw new BrowserDataError(code, errorMessage)
      }
      return {
        protocol: 'cdp' as const,
        tool: toolName,
        output: responded.output ?? null
      }
    }
  })

  return session.supported ? session.value : undefined
}

async function listPageRealmWebMCPTools(frame: Frame, deadline: number): Promise<WebMCPListResult> {
  if (Date.now() >= deadline) {
    throw new BrowserDataError('timeout', 'WebMCP discovery timed out', { retryable: true })
  }
  return await frame.evaluate(async () => {
    const modelContext = (
      navigator as Navigator & {
        modelContext?: {
          getTools?: () => Promise<
            Array<{
              name?: string
              title?: string
              description?: string
              inputSchema?: unknown
              annotations?: Record<string, unknown>
            }>
          >
        }
      }
    ).modelContext

    if (modelContext && typeof modelContext.getTools === 'function') {
      const registered = await modelContext.getTools()
      const tools = (Array.isArray(registered) ? registered : [])
        .filter(item => item && typeof item.name === 'string' && item.name.length > 0)
        .map(item => ({
          name: String(item.name),
          description: typeof item.description === 'string' ? item.description : '',
          ...(typeof item.title === 'string' && item.title.length > 0 ? { title: item.title } : {}),
          ...(item.inputSchema !== undefined ? { input_schema: JSON.parse(JSON.stringify(item.inputSchema)) } : {}),
          ...(item.annotations && typeof item.annotations === 'object'
            ? { annotations: JSON.parse(JSON.stringify(item.annotations)) as Record<string, unknown> }
            : {})
        }))
      if (tools.length > 0) {
        return { supported: true, protocol: 'model_context' as const, tools }
      }
    }

    const forms = Array.from(document.querySelectorAll('form[toolname][tooldescription]'))
    if (forms.length === 0) {
      return { supported: false, protocol: 'none' as const, tools: [] }
    }

    const tools = forms
      .map(form => {
        const name = form.getAttribute('toolname')?.trim() ?? ''
        const description = form.getAttribute('tooldescription')?.trim() ?? ''
        if (!name || !description) return null
        const title = form.getAttribute('tooltitle')?.trim() ?? ''
        const autosubmit = form.hasAttribute('toolautosubmit')
        const properties: Record<string, Record<string, unknown>> = {}
        const required: string[] = []
        const htmlForm = form as HTMLFormElement
        for (const element of Array.from(htmlForm.elements)) {
          const control = element as HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement
          const fieldName = control.name?.trim()
          if (!fieldName || control.disabled) continue
          const tag = control.tagName.toLowerCase()
          const type = 'type' in control ? String(control.type || '').toLowerCase() : ''
          if (tag === 'button' || ['submit', 'reset', 'button', 'image', 'hidden', 'file'].includes(type)) continue
          let prop: Record<string, unknown> = { type: 'string' }
          if (type === 'checkbox') prop = { type: 'boolean' }
          else if (type === 'number' || type === 'range') prop = { type: 'number' }
          else if (tag === 'select') {
            const values = Array.from((control as HTMLSelectElement).options)
              .filter(option => !option.disabled)
              .map(option => option.value)
            prop = { type: 'string', ...(values.length > 0 ? { enum: values } : {}) }
          }
          const paramDesc = control.getAttribute('toolparamdescription')
          if (paramDesc) prop.description = paramDesc
          properties[fieldName] = prop
          if (control.required && !required.includes(fieldName)) required.push(fieldName)
        }
        return {
          name,
          description,
          ...(title ? { title } : {}),
          input_schema: {
            type: 'object',
            properties,
            ...(required.length > 0 ? { required } : {})
          },
          ...(autosubmit ? { annotations: { autosubmit: true } } : {})
        }
      })
      .filter((item): item is NonNullable<typeof item> => item !== null)

    return {
      supported: tools.length > 0,
      protocol: tools.length > 0 ? ('declarative_dom' as const) : ('none' as const),
      tools
    }
  })
}

async function callPageRealmWebMCPTool(
  frame: Frame,
  toolName: string,
  input: Record<string, unknown>,
  deadline: number
): Promise<WebMCPCallResult> {
  if (Date.now() >= deadline) {
    throw new BrowserDataError('timeout', `WebMCP tool ${toolName} timed out`, { retryable: true })
  }
  const outcome = await frame.evaluate(
    async ({ name, args }) => {
      const forms = Array.from(document.querySelectorAll('form[toolname][tooldescription]')) as HTMLFormElement[]
      const form = forms.find(candidate => candidate.getAttribute('toolname')?.trim() === name)

      const modelContext = (
        navigator as Navigator & {
          modelContext?: {
            getTools?: () => Promise<Array<{ name?: string; origin?: string }>>
            executeTool?: (
              tool: { origin: string; name: string },
              inputObject?: Record<string, unknown>
            ) => Promise<unknown>
          }
        }
      ).modelContext

      let registeredTools: Array<{ name?: string; origin?: string }> | undefined
      if (modelContext && typeof modelContext.executeTool === 'function') {
        try {
          if (typeof modelContext.getTools === 'function') {
            const rawTools = await modelContext.getTools()
            registeredTools = Array.isArray(rawTools) ? rawTools : []
          }
          const entry = registeredTools?.find(item => item?.name === name)
          if (registeredTools === undefined || entry !== undefined) {
            const origin = typeof entry?.origin === 'string' && entry.origin ? entry.origin : location.origin
            const raw = await modelContext.executeTool({ origin, name }, args)
            let parsed: unknown = raw
            if (typeof raw === 'string' && raw.trim().length > 0) {
              try {
                parsed = JSON.parse(raw)
              } catch {
                parsed = raw
              }
            }
            return { ok: true as const, protocol: 'model_context' as const, output: parsed }
          }
        } catch (error) {
          const message = error instanceof Error ? error.message : String(error)
          return {
            ok: false as const,
            code: /no tool named|not found/i.test(message) ? ('invalid_command' as const) : ('invalid_result' as const),
            message
          }
        }
      }

      if (!form) {
        return {
          ok: false as const,
          code: 'invalid_command' as const,
          message:
            forms.length === 0 && (!registeredTools || registeredTools.length === 0)
              ? 'WebMCP is not available on the current page or browser backend'
              : `WebMCP tool not found: ${name}`
        }
      }

      const applied: string[] = []
      for (const [fieldName, rawValue] of Object.entries(args)) {
        const matching = Array.from(form.elements).filter(
          (el): el is HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement =>
            'name' in el && (el as { name?: string }).name === fieldName && !(el as { disabled?: boolean }).disabled
        )
        if (matching.length === 0) continue
        const first = matching[0]!
        if (first instanceof HTMLInputElement && first.type === 'checkbox') {
          first.checked = Boolean(rawValue)
          first.dispatchEvent(new Event('input', { bubbles: true }))
          first.dispatchEvent(new Event('change', { bubbles: true }))
        } else if (first instanceof HTMLInputElement && first.type === 'radio') {
          const targetRadio = matching.find(el => el instanceof HTMLInputElement && el.value === String(rawValue)) as
            | HTMLInputElement
            | undefined
          if (targetRadio) {
            targetRadio.checked = true
            targetRadio.dispatchEvent(new Event('input', { bubbles: true }))
            targetRadio.dispatchEvent(new Event('change', { bubbles: true }))
          }
        } else {
          const nextValue = rawValue === null || rawValue === undefined ? '' : String(rawValue)
          const proto =
            first instanceof HTMLSelectElement
              ? HTMLSelectElement.prototype
              : first instanceof HTMLTextAreaElement
                ? HTMLTextAreaElement.prototype
                : HTMLInputElement.prototype
          const descriptor = Object.getOwnPropertyDescriptor(proto, 'value')
          if (descriptor?.set) descriptor.set.call(first, nextValue)
          else first.value = nextValue
          first.dispatchEvent(new Event('input', { bubbles: true }))
          first.dispatchEvent(new Event('change', { bubbles: true }))
        }
        applied.push(fieldName)
      }

      const autosubmitted = form.hasAttribute('toolautosubmit')
      if (autosubmitted) {
        if (typeof form.requestSubmit === 'function') form.requestSubmit()
        else form.dispatchEvent(new SubmitEvent('submit', { bubbles: true, cancelable: true }))
      }
      return {
        ok: true as const,
        protocol: 'declarative_dom' as const,
        output: { filled: applied, autosubmitted }
      }
    },
    { name: toolName, args: input }
  )

  if (!outcome.ok) {
    throw new BrowserDataError(outcome.code, outcome.message)
  }
  return {
    protocol: outcome.protocol,
    tool: toolName,
    output: outcome.output
  }
}

function normalizeCDPTool(raw: CDPWebMCPTool): WebMCPToolSummary | undefined {
  if (!raw || typeof raw.name !== 'string' || raw.name.length === 0) return undefined
  return {
    name: raw.name,
    description: typeof raw.description === 'string' ? raw.description : '',
    ...(typeof raw.frameId === 'string' && raw.frameId.length > 0 ? { frame_id: raw.frameId } : {}),
    ...(raw.inputSchema !== undefined ? { input_schema: raw.inputSchema } : {}),
    ...(raw.annotations && typeof raw.annotations === 'object'
      ? { annotations: raw.annotations as Record<string, unknown> }
      : {})
  }
}

async function sendWithDeadline(
  cdp: CDPSession,
  method: string,
  params: Record<string, unknown>,
  deadline: number
): Promise<unknown> {
  const remaining = deadline - Date.now()
  if (remaining <= 0) {
    throw new BrowserDataError('timeout', `${method} timed out before execution`, { retryable: true })
  }
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    return await Promise.race([
      cdp.send(method as Parameters<CDPSession['send']>[0], params as never),
      new Promise<never>((_, reject) => {
        timer = setTimeout(
          () => reject(new BrowserDataError('timeout', `${method} timed out`, { retryable: true })),
          remaining
        )
        timer.unref()
      })
    ])
  } finally {
    if (timer) clearTimeout(timer)
  }
}

function isMethodUnsupported(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error)
  return /wasn't found|Method not found|not a recognized|unknown method|not supported|-32601/i.test(message)
}

function toWebMCPError(error: unknown): BrowserDataError {
  if (error instanceof BrowserDataError) return error
  const message = error instanceof Error ? error.message : String(error)
  return new BrowserDataError('invalid_result', message, { cause: error })
}
