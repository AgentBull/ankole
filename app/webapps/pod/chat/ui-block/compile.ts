import {
  applySpecStreamPatch,
  conditionUsesItemScope,
  getByPath,
  parseSpecStreamLine,
  resolveActionParam,
  resolveElementProps,
  resolvePropValue,
  resolveRepeatItemStatePath,
  resolveRepeatStatePath,
  setByPath,
  VisibilityConditionStrictSchema,
  type ActionBinding,
  type PropResolutionContext,
  type Spec,
  type StateModel,
  type UIElement
} from '@json-render/core'
import { z } from 'zod'
import { cell, uiBlockCatalog } from './catalog'

/**
 * A block may expand to this many elements. A committed message renders for every reader on every visit, so a
 * larger tree, or one that contains itself, would freeze the room.
 */
const ELEMENT_BUDGET = 500
const MAX_JSON_DEPTH = 32
const MAX_POINTER_INDEX = 1000
const FORBIDDEN_SEGMENTS = new Set(['__proto__', 'constructor', 'prototype'])

const ACTIONS = new Set(['setState', ...uiBlockCatalog.actionNames])
const SET_STATE_SCHEMA = z.strictObject({
  statePath: z.string(),
  value: cell
})
const ACTION_SCHEMAS: Record<string, { params: z.ZodType }> = {
  setState: { params: SET_STATE_SCHEMA },
  ...uiBlockCatalog.data.actions
}
const COMPONENTS: Record<
  string,
  { props: z.ZodType; slots?: string[]; switcherOptionsProp?: string; autoBindUncontrolled?: boolean }
> = uiBlockCatalog.data.components

const REPEAT_SCHEMA = z.strictObject({
  statePath: z.union([z.string(), z.strictObject({ $item: z.string() })]),
  key: z.string().min(1).optional()
})

type WalkScope = {
  repeatItem: unknown
  repeatIndex: number
  repeatBasePath: string
  emptyRepeat: boolean
}

type RepeatSpec = { statePath: string | { $item: string }; key?: string }

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value)

const escapePointerSegment = (segment: string) => segment.replaceAll('~', '~0').replaceAll('/', '~1')

function isSafePointer(pointer: unknown): pointer is string {
  if (typeof pointer !== 'string' || !pointer.startsWith('/')) return false
  for (const raw of pointer.slice(1).split('/')) {
    const segment = raw.replaceAll('~1', '/').replaceAll('~0', '~')
    if (!segment || FORBIDDEN_SEGMENTS.has(segment)) return false
    if (/^\d+$/.test(segment) && Number(segment) > MAX_POINTER_INDEX) return false
  }
  return true
}

function safeSetByPath(target: Record<string, unknown>, pointer: string, value: unknown) {
  const segments = pointer
    .slice(1)
    .split('/')
    .map(raw => raw.replaceAll('~1', '/').replaceAll('~0', '~'))
  let cursor: unknown = target
  for (let i = 0; i < segments.length - 1; i++) {
    if (!isRecord(cursor) && !Array.isArray(cursor)) return
    const next = (cursor as Record<string, unknown>)[segments[i]!]
    if (next !== undefined && !isRecord(next) && !Array.isArray(next)) return
    cursor = next ?? {}
  }
  if (!isRecord(cursor) && !Array.isArray(cursor)) return
  setByPath(target, pointer, value)
}

function isSafeItemPath(path: unknown): path is string {
  if (typeof path !== 'string') return false
  if (path === '') return true
  const trimmed = path.startsWith('/') ? path.slice(1) : path
  for (const raw of trimmed.split('/')) {
    const segment = raw.replaceAll('~1', '/').replaceAll('~0', '~')
    if (FORBIDDEN_SEGMENTS.has(segment)) return false
    if (/^\d+$/.test(segment) && Number(segment) > MAX_POINTER_INDEX) return false
  }
  return true
}

function isNonNumericItemField(path: unknown): path is string {
  if (typeof path !== 'string' || path.length === 0) return false
  const trimmed = path.startsWith('/') ? path.slice(1) : path
  if (!trimmed) return false
  for (const raw of trimmed.split('/')) {
    const segment = raw.replaceAll('~1', '/').replaceAll('~0', '~')
    if (!segment || segment === '-' || FORBIDDEN_SEGMENTS.has(segment) || /^\d+$/.test(segment)) {
      return false
    }
  }
  return true
}

function withinDepth(value: unknown, remaining: number): boolean {
  if (value === null || typeof value !== 'object') return true
  if (remaining <= 0) return false
  if (Array.isArray(value)) return value.every(item => withinDepth(item, remaining - 1))
  const proto = Object.getPrototypeOf(value)
  if (proto !== Object.prototype && proto !== null) return false
  for (const [key, entry] of Object.entries(value)) {
    if (FORBIDDEN_SEGMENTS.has(key) || !withinDepth(entry, remaining - 1)) return false
  }
  return true
}

function checkExpressions(
  value: unknown,
  inRepeat: boolean,
  allowBindState: boolean
): { valid: boolean; hasCond: boolean; usesItem: boolean } {
  if (value === null || typeof value !== 'object') return { valid: true, hasCond: false, usesItem: false }
  if (Array.isArray(value)) {
    let hasCond = false
    let usesItem = false
    for (const item of value) {
      const next = checkExpressions(item, inRepeat, allowBindState)
      if (!next.valid) return { valid: false, hasCond: false, usesItem: false }
      hasCond ||= next.hasCond
      usesItem ||= next.usesItem
    }
    return { valid: true, hasCond, usesItem }
  }
  const record = value as Record<string, unknown>
  if ('$computed' in record || '$bindItem' in record) return { valid: false, hasCond: false, usesItem: false }
  const keys = Object.keys(record)
  if ('$state' in record) {
    return { valid: keys.length === 1 && isSafePointer(record.$state), hasCond: false, usesItem: false }
  }
  if ('$bindState' in record) {
    return {
      valid: allowBindState && keys.length === 1 && isSafePointer(record.$bindState),
      hasCond: false,
      usesItem: false
    }
  }
  if ('$item' in record) {
    return { valid: inRepeat && keys.length === 1 && isSafeItemPath(record.$item), hasCond: false, usesItem: true }
  }
  if ('$index' in record) {
    return { valid: inRepeat && keys.length === 1 && record.$index === true, hasCond: false, usesItem: true }
  }
  if ('$template' in record) {
    if (keys.length !== 1 || typeof record.$template !== 'string') {
      return { valid: false, hasCond: false, usesItem: false }
    }
    let usesItem = false
    for (const match of record.$template.matchAll(/\$\{([^}]*)\}/g)) {
      const path = match[1] ?? ''
      if (!path) return { valid: false, hasCond: false, usesItem: false }
      if (path.startsWith('/')) {
        if (!isSafePointer(path)) return { valid: false, hasCond: false, usesItem: false }
      } else {
        if (!inRepeat || !isSafeItemPath(path)) return { valid: false, hasCond: false, usesItem: false }
        usesItem = true
      }
    }
    return { valid: true, hasCond: false, usesItem }
  }
  if ('$cond' in record || '$then' in record || '$else' in record) {
    if (keys.length !== 3 || !('$cond' in record) || !('$then' in record) || !('$else' in record)) {
      return { valid: false, hasCond: false, usesItem: false }
    }
    const parsedCond = VisibilityConditionStrictSchema.safeParse(record.$cond)
    if (!parsedCond.success) return { valid: false, hasCond: false, usesItem: false }
    const condUsesItem = conditionUsesItemScope(parsedCond.data)
    if (!inRepeat && condUsesItem) return { valid: false, hasCond: false, usesItem: false }
    const thenCheck = checkExpressions(record.$then, inRepeat, false)
    const elseCheck = checkExpressions(record.$else, inRepeat, false)
    return {
      valid: thenCheck.valid && elseCheck.valid,
      hasCond: true,
      usesItem: condUsesItem || thenCheck.usesItem || elseCheck.usesItem
    }
  }
  let hasCond = false
  let usesItem = false
  for (const entry of Object.values(record)) {
    const next = checkExpressions(entry, inRepeat, allowBindState)
    if (!next.valid) return { valid: false, hasCond: false, usesItem: false }
    hasCond ||= next.hasCond
    usesItem ||= next.usesItem
  }
  return { valid: true, hasCond, usesItem }
}

const isAddressActionParam = (action: string, paramKey: string): boolean =>
  action === 'setState' && paramKey === 'statePath'

function resolveBlockActionParam(
  action: string,
  paramKey: string,
  value: unknown,
  ctx: PropResolutionContext
): unknown {
  return isAddressActionParam(action, paramKey) ? resolveActionParam(value, ctx) : resolvePropValue(value, ctx)
}

/**
 * `@json-render/react` resolves every action parameter through `resolveActionParam`, which turns a bare top-level
 * `{ $item }` into a JSON Pointer address. Wrapping data-valued `{ $item }` expressions in a tautological `$cond`
 * routes click-time evaluation through `resolvePropValue` so both compile-time validation and live clicks read the
 * item's field value while `setState.params.statePath` keeps address semantics.
 */
function compileActionParams(action: string, params: Record<string, unknown>): ActionBinding['params'] {
  let rewritten: Record<string, unknown> | undefined
  for (const [paramKey, paramVal] of Object.entries(params)) {
    if (!isAddressActionParam(action, paramKey) && isRecord(paramVal) && '$item' in paramVal) {
      rewritten ??= { ...params }
      rewritten[paramKey] = {
        $cond: { $index: true, gte: 0 },
        $then: paramVal,
        $else: paramVal
      }
    }
  }
  return (rewritten ?? params) as ActionBinding['params']
}

/**
 * Validates every `$then` / `$else` branch at its own field or item position against the already-validated active
 * structure, avoiding cross-field or cross-row Cartesian explosion.
 */
function validateCondBranches(
  rawNode: unknown,
  baseVal: unknown,
  resolveLeaf: (expr: unknown) => unknown,
  checkCandidate: (candidate: unknown, rawBranch?: unknown) => boolean
): boolean {
  if (rawNode == null || typeof rawNode !== 'object') return true
  if (Array.isArray(rawNode)) {
    if (!Array.isArray(baseVal)) return false
    for (let i = 0; i < rawNode.length; i++) {
      if (
        !validateCondBranches(rawNode[i], baseVal[i], resolveLeaf, itemCandidate => {
          const next = baseVal.slice()
          next[i] = itemCandidate
          return checkCandidate(next)
        })
      ) {
        return false
      }
    }
    return true
  }
  const record = rawNode as Record<string, unknown>
  if ('$cond' in record && '$then' in record && '$else' in record) {
    for (const branch of [record.$then, record.$else]) {
      const branchVal = resolveLeaf(branch)
      if (!checkCandidate(branchVal, branch)) return false
      if (!validateCondBranches(branch, branchVal, resolveLeaf, checkCandidate)) return false
    }
    return true
  }
  if (
    '$state' in record ||
    '$bindState' in record ||
    '$item' in record ||
    '$index' in record ||
    '$template' in record
  ) {
    return true
  }
  if (!isRecord(baseVal)) return false
  for (const [key, entry] of Object.entries(record)) {
    if (
      !validateCondBranches(entry, baseVal[key], resolveLeaf, fieldCandidate =>
        checkCandidate({ ...baseVal, [key]: fieldCandidate })
      )
    ) {
      return false
    }
  }
  return true
}

/**
 * Ensures `setState.params.statePath` can never overwrite a `repeat` array pointer (or an ancestor containing one),
 * clobber structured state, or grow an array via numeric or `-` index segments.
 */
function isValidSetStateTarget(
  rawStatePath: unknown,
  resolvedPath: unknown,
  state: Record<string, unknown>,
  repeatPaths: ReadonlySet<string>,
  scope: WalkScope | undefined
): boolean {
  if (!isSafePointer(resolvedPath)) return false
  for (const repeatPath of repeatPaths) {
    if (resolvedPath === repeatPath || repeatPath.startsWith(`${resolvedPath}/`)) return false
  }
  if (isRecord(rawStatePath) && '$item' in rawStatePath) {
    if (!scope || !isNonNumericItemField(rawStatePath.$item)) return false
    if (!scope.emptyRepeat) {
      if (!isRecord(scope.repeatItem)) return false
      const existing = getByPath(state, resolvedPath)
      if (existing !== undefined && !cell.safeParse(existing).success) return false
    }
    return true
  }
  for (const repeatPath of repeatPaths) {
    if (resolvedPath.startsWith(`${repeatPath}/`)) return false
  }
  for (const raw of resolvedPath.slice(1).split('/')) {
    const segment = raw.replaceAll('~1', '/').replaceAll('~0', '~')
    if (segment === '-' || /^\d+$/.test(segment)) return false
  }
  const existing = getByPath(state, resolvedPath)
  return existing === undefined || cell.safeParse(existing).success
}

function validateActionParams(
  action: string,
  rawParams: Record<string, unknown>,
  resolved: Record<string, unknown>,
  state: Record<string, unknown>,
  repeatPaths: ReadonlySet<string>,
  scope: WalkScope | undefined
): boolean {
  const schema = ACTION_SCHEMAS[action]?.params
  if (!schema || !schema.safeParse(resolved).success) return false
  if (action === 'setState') {
    return isValidSetStateTarget(rawParams.statePath, resolved.statePath, state, repeatPaths, scope)
  }
  return true
}

/**
 * Keeps the catalog actions of an element's events, each with validated parameters only; a binding cannot open a
 * confirmation dialog or name another action.
 */
function events(
  on: unknown,
  ctx: PropResolutionContext,
  state: Record<string, unknown>,
  repeatPaths: ReadonlySet<string>,
  scope: WalkScope | undefined,
  streaming: boolean
): { status: 'ok'; value: Record<string, ActionBinding[]> | undefined } | { status: 'pending' | 'invalid' } {
  if (on == null) return { status: 'ok', value: undefined }
  if (!isRecord(on)) return { status: 'invalid' }
  const inRepeat = Boolean(scope)
  const emptyRepeat = Boolean(scope?.emptyRepeat)
  const kept: Record<string, ActionBinding[]> = {}

  for (const [event, value] of Object.entries(on)) {
    if (!event) return { status: 'invalid' }
    kept[event] = []
    for (const binding of Array.isArray(value) ? value : [value]) {
      if (!isRecord(binding) || typeof binding.action !== 'string' || !ACTIONS.has(binding.action)) {
        return { status: 'invalid' }
      }
      const action = binding.action
      if (!isRecord(binding.params)) return { status: 'invalid' }
      const rawParams = binding.params
      const schema = ACTION_SCHEMAS[action]?.params
      if (!(schema instanceof z.ZodObject)) return { status: 'invalid' }

      const expr = checkExpressions(rawParams, inRepeat, false)
      if (!expr.valid) return { status: 'invalid' }

      if (!emptyRepeat || !expr.usesItem) {
        const resolvedParams: Record<string, unknown> = {}
        for (const [paramKey, paramVal] of Object.entries(rawParams)) {
          resolvedParams[paramKey] = resolveBlockActionParam(action, paramKey, paramVal, ctx)
        }
        if (!validateActionParams(action, rawParams, resolvedParams, state, repeatPaths, scope)) {
          return { status: streaming ? 'pending' : 'invalid' }
        }
        if (!streaming && expr.hasCond) {
          for (const [paramKey, paramVal] of Object.entries(rawParams)) {
            const branchesOk = validateCondBranches(
              paramVal,
              resolvedParams[paramKey],
              branchExpr => resolvePropValue(branchExpr, ctx),
              (paramCandidate, rawBranch) =>
                validateActionParams(
                  action,
                  paramKey === 'statePath' && rawBranch !== undefined
                    ? { ...rawParams, statePath: rawBranch }
                    : rawParams,
                  { ...resolvedParams, [paramKey]: paramCandidate },
                  state,
                  repeatPaths,
                  scope
                )
            )
            if (!branchesOk) return { status: 'invalid' }
          }
        }
      } else {
        const shape = schema.shape as Record<string, z.ZodType>
        if (action === 'setState' && !Object.keys(rawParams).every(key => Object.hasOwn(shape, key))) {
          return { status: 'invalid' }
        }
        for (const [paramKey, paramSchema] of Object.entries(shape)) {
          if (!Object.hasOwn(rawParams, paramKey)) {
            if (!paramSchema.safeParse(undefined).success) return { status: 'invalid' }
            continue
          }
          const paramVal = rawParams[paramKey]
          const paramExpr = checkExpressions(paramVal, true, false)
          if (action === 'setState' && paramKey === 'statePath') {
            if (!paramExpr.usesItem || (isRecord(paramVal) && '$item' in paramVal)) {
              const resolvedPath = resolveBlockActionParam('setState', 'statePath', paramVal, ctx)
              if (!isValidSetStateTarget(paramVal, resolvedPath, state, repeatPaths, scope)) {
                return { status: streaming ? 'pending' : 'invalid' }
              }
              if (!streaming && paramExpr.hasCond) {
                const branchesOk = validateCondBranches(
                  paramVal,
                  resolvedPath,
                  branchExpr => resolvePropValue(branchExpr, ctx),
                  (candidate, rawBranch) =>
                    isValidSetStateTarget(rawBranch ?? paramVal, candidate, state, repeatPaths, scope)
                )
                if (!branchesOk) return { status: 'invalid' }
              }
            }
          } else if (!paramExpr.usesItem) {
            const resolvedVal = resolveBlockActionParam(action, paramKey, paramVal, ctx)
            if (!paramSchema.safeParse(resolvedVal).success) {
              return { status: streaming ? 'pending' : 'invalid' }
            }
            if (!streaming && paramExpr.hasCond) {
              const branchesOk = validateCondBranches(
                paramVal,
                resolvedVal,
                branchExpr => resolvePropValue(branchExpr, ctx),
                candidate => paramSchema.safeParse(candidate).success
              )
              if (!branchesOk) return { status: 'invalid' }
            }
          }
        }
      }

      kept[event].push({
        action,
        params: compileActionParams(action, rawParams)
      })
    }
  }
  return { status: 'ok', value: kept }
}

/** Seeds missing bound switcher paths with their first choice so a block never opens with every view hidden. */
function seedBoundSwitchers(sources: Record<string, unknown>, state: Record<string, unknown>) {
  for (const raw of Object.values(sources)) {
    if (!isRecord(raw) || typeof raw.type !== 'string' || !isRecord(raw.props)) continue
    const optionsProp = COMPONENTS[raw.type]?.switcherOptionsProp
    if (!optionsProp) continue
    const bound = raw.props.value
    if (!isRecord(bound) || !('$bindState' in bound) || !isSafePointer(bound.$bindState)) continue
    if (getByPath(state, bound.$bindState) !== undefined) continue
    const items = raw.props[optionsProp]
    const first = Array.isArray(items) && isRecord(items[0]) ? items[0].value : undefined
    if (typeof first === 'string') safeSetByPath(state, bound.$bindState, first)
  }
}

/** Collects every static and expanded `repeat` state pointer reachable from `rootKey`. */
function collectRepeatPaths(
  rootKey: string,
  getElement: (key: string) => unknown,
  state: Record<string, unknown>
): Set<string> {
  const paths = new Set<string>()
  const ancestors = new Set<string>()
  let remaining = ELEMENT_BUDGET

  const visit = (key: string, repeatBasePath?: string, emptyRepeat = false) => {
    if (ancestors.has(key) || --remaining < 0) return
    const raw = getElement(key)
    if (!isRecord(raw)) return
    const children = Array.isArray(raw.children)
      ? raw.children.filter((child): child is string => typeof child === 'string')
      : []

    ancestors.add(key)
    const parsedRepeat = raw.repeat !== undefined ? REPEAT_SCHEMA.safeParse(raw.repeat) : undefined
    if (parsedRepeat?.success) {
      const resolvedPath = resolveRepeatStatePath(parsedRepeat.data.statePath, repeatBasePath)
      if (resolvedPath && isSafePointer(resolvedPath)) {
        paths.add(resolvedPath)
        const items = emptyRepeat ? [] : getByPath(state, resolvedPath)
        if (Array.isArray(items) && items.length > 0) {
          for (let i = 0; i < items.length; i++) {
            const itemBase = resolveRepeatItemStatePath(resolvedPath, i)
            for (const childKey of children) visit(childKey, itemBase, false)
          }
        } else {
          const itemBase = resolveRepeatItemStatePath(resolvedPath, 0)
          for (const childKey of children) visit(childKey, itemBase, true)
        }
        ancestors.delete(key)
        return
      }
    }

    for (const childKey of children) visit(childKey, repeatBasePath, emptyRepeat)
    ancestors.delete(key)
  }

  visit(rootKey)
  return paths
}

type CheckedElement =
  | { status: 'ok'; element: UIElement; repeat?: RepeatSpec }
  | { status: 'pending' }
  | { status: 'invalid' }

/** Validates one element in its current state and repeat scope. */
function checkElement(
  key: string,
  source: unknown,
  state: Record<string, unknown>,
  repeatPaths: ReadonlySet<string>,
  scope: WalkScope | undefined,
  streaming: boolean
): CheckedElement {
  if (!isRecord(source) || typeof source.type !== 'string') {
    return { status: 'invalid' }
  }
  const component = COMPONENTS[source.type]
  if (!component) return { status: 'invalid' }
  if (source.watch != null || source.slots != null) {
    return { status: 'invalid' }
  }

  let repeat: RepeatSpec | undefined
  if (source.repeat !== undefined) {
    if (!component.slots?.length) return { status: 'invalid' }
    const parsedRepeat = REPEAT_SCHEMA.safeParse(source.repeat)
    if (!parsedRepeat.success) return { status: 'invalid' }
    const { statePath } = parsedRepeat.data
    const pathValid =
      typeof statePath === 'string' ? isSafePointer(statePath) : Boolean(scope) && isSafeItemPath(statePath.$item)
    if (!pathValid) return { status: 'invalid' }
    repeat = parsedRepeat.data
  }

  const rawProps = source.props ?? {}
  const children = source.children ?? []
  if (!isRecord(rawProps) || !Array.isArray(children) || !children.every(child => typeof child === 'string')) {
    return { status: 'invalid' }
  }

  const inRepeat = Boolean(scope)
  if (source.visible !== undefined) {
    const parsedVisible = VisibilityConditionStrictSchema.safeParse(source.visible)
    if (!parsedVisible.success || (!inRepeat && !repeat && conditionUsesItemScope(parsedVisible.data))) {
      return { status: 'invalid' }
    }
  }

  const expr = checkExpressions(rawProps, inRepeat, true)
  if (!expr.valid) return { status: 'invalid' }

  const ctx: PropResolutionContext = scope
    ? {
        stateModel: state,
        repeatItem: scope.repeatItem,
        repeatIndex: scope.repeatIndex,
        repeatBasePath: scope.repeatBasePath
      }
    : { stateModel: state }

  const checkedEvents = events(source.on, ctx, state, repeatPaths, scope, streaming)
  if (checkedEvents.status !== 'ok') {
    return checkedEvents.status === 'pending' ? { status: 'pending' } : { status: 'invalid' }
  }

  let props = rawProps
  if (!scope?.emptyRepeat || !expr.usesItem) {
    const resolved = resolveElementProps(rawProps, ctx)
    if (!component.props.safeParse(resolved).success) {
      return streaming ? { status: 'pending' } : { status: 'invalid' }
    }
    if (!streaming && expr.hasCond) {
      const branchesOk = validateCondBranches(
        rawProps,
        resolved,
        branchExpr => resolvePropValue(branchExpr, ctx),
        candidate => isRecord(candidate) && component.props.safeParse(candidate).success
      )
      if (!branchesOk) return { status: 'invalid' }
    }
    // Standalone uncontrolled switchers (Tabs) bind into the block's store so the open tab survives scrolling and room switches.
    if (component.autoBindUncontrolled && component.switcherOptionsProp && !scope && rawProps.value == null) {
      const options = resolved[component.switcherOptionsProp]
      const firstChoice =
        Array.isArray(options) && isRecord(options[0]) && typeof options[0].value === 'string'
          ? options[0].value
          : undefined
      if (firstChoice !== undefined) {
        const autoPath = `/__tabs/${escapePointerSegment(key)}`
        if (getByPath(state, autoPath) === undefined) safeSetByPath(state, autoPath, firstChoice)
        props = { ...rawProps, value: { $bindState: autoPath } }
      }
    }
  } else if (component.props instanceof z.ZodObject) {
    const shape = component.props.shape as Record<string, z.ZodType>
    for (const [propKey, propSchema] of Object.entries(shape)) {
      if (!Object.hasOwn(rawProps, propKey)) {
        if (!propSchema.safeParse(undefined).success) return { status: 'invalid' }
        continue
      }
      const propVal = rawProps[propKey]
      const propExpr = checkExpressions(propVal, true, true)
      if (!propExpr.usesItem) {
        const resolvedProp = resolveElementProps({ [propKey]: propVal }, ctx)[propKey]
        if (!propSchema.safeParse(resolvedProp).success) {
          return streaming ? { status: 'pending' } : { status: 'invalid' }
        }
        if (!streaming && propExpr.hasCond) {
          const branchesOk = validateCondBranches(
            propVal,
            resolvedProp,
            branchExpr => resolvePropValue(branchExpr, ctx),
            candidate => propSchema.safeParse(candidate).success
          )
          if (!branchesOk) return { status: 'invalid' }
        }
      }
    }
  }

  return {
    status: 'ok',
    repeat,
    element: {
      type: source.type,
      props,
      children: children as string[],
      ...(source.visible !== undefined && { visible: source.visible as UIElement['visible'] }),
      ...(checkedEvents.value && { on: checkedEvents.value }),
      ...(repeat && { repeat })
    }
  }
}

type NodeInspection =
  | {
      status: 'ok'
      children: string[]
      repeat?: RepeatSpec
      commitChildren?: (readyChildren: string[]) => void
    }
  | { status: 'pending' }
  | { status: 'invalid' }

type WalkOutcome = { status: 'ok' } | { status: 'pending' } | { status: 'invalid' }

/**
 * Single tree traversal shared by compilation and remembered-state validation so `repeat` scopes, element budgets,
 * cycle checks, and child `pending` handling follow one contract.
 */
function walkBlockTree(
  rootKey: string,
  state: Record<string, unknown>,
  streaming: boolean,
  prunePendingChildren: boolean,
  inspectNode: (key: string, scope: WalkScope | undefined) => NodeInspection
): WalkOutcome {
  const ancestors = new Set<string>()
  let budget = ELEMENT_BUDGET

  const walk = (key: string, scope?: WalkScope): WalkOutcome => {
    if (ancestors.has(key) || --budget < 0) return { status: 'invalid' }

    const inspected = inspectNode(key, scope)
    if (inspected.status === 'invalid') return inspected
    if (inspected.status === 'pending') return { status: 'pending' }

    ancestors.add(key)
    let childScopes: Array<WalkScope | undefined>

    if (inspected.repeat) {
      const resolvedPath = resolveRepeatStatePath(inspected.repeat.statePath, scope?.repeatBasePath)
      if (!resolvedPath || !isSafePointer(resolvedPath)) {
        ancestors.delete(key)
        return { status: 'invalid' }
      }
      const items = scope?.emptyRepeat ? [] : getByPath(state, resolvedPath)
      if (items === undefined) {
        ancestors.delete(key)
        return streaming ? { status: 'pending' } : { status: 'invalid' }
      }
      if (!Array.isArray(items)) {
        ancestors.delete(key)
        return { status: 'invalid' }
      }
      childScopes =
        items.length === 0
          ? [
              {
                repeatItem: undefined,
                repeatIndex: 0,
                repeatBasePath: resolveRepeatItemStatePath(resolvedPath, 0),
                emptyRepeat: true
              }
            ]
          : items.map((item, index) => ({
              repeatItem: item,
              repeatIndex: index,
              repeatBasePath: resolveRepeatItemStatePath(resolvedPath, index),
              emptyRepeat: false
            }))
    } else {
      childScopes = [scope]
    }

    const readyAcrossScopes = new Set(inspected.children)
    for (const childScope of childScopes) {
      for (const childKey of inspected.children) {
        const childResult = walk(childKey, childScope)
        if (childResult.status === 'invalid') {
          ancestors.delete(key)
          return childResult
        }
        if (childResult.status === 'pending') {
          if (!prunePendingChildren) {
            ancestors.delete(key)
            return childResult
          }
          readyAcrossScopes.delete(childKey)
        }
      }
    }

    ancestors.delete(key)
    inspected.commitChildren?.(inspected.children.filter(childKey => readyAcrossScopes.has(childKey)))
    return { status: 'ok' }
  }

  return walk(rootKey)
}

function pruneUnreachableElements(root: string, elements: Spec['elements']) {
  const reachable = new Set<string>()
  const queue = [root]
  while (queue.length > 0) {
    const key = queue.pop()!
    if (reachable.has(key)) continue
    const el = elements[key]
    if (!el) continue
    reachable.add(key)
    for (const child of el.children ?? []) queue.push(child)
  }
  for (const key of Object.keys(elements)) {
    if (!reachable.has(key)) delete elements[key]
  }
}

/**
 * Validates a compiled `ui` spec against a remembered state snapshot before restoring it, enforcing the 500-element
 * expansion budget across `repeat` arrays as well as resolved component prop and action schemas.
 */
export function validateUIBlockState(spec: Spec, state: StateModel, streaming = false): boolean {
  if (!isRecord(state) || !withinDepth(state, MAX_JSON_DEPTH)) return false

  const repeatPaths = collectRepeatPaths(spec.root, key => spec.elements[key], state)
  const rootResult = walkBlockTree(spec.root, state, streaming, false, (key, scope) => {
    const element = spec.elements[key]
    if (!element) return streaming ? { status: 'pending' } : { status: 'invalid' }
    const component = COMPONENTS[element.type]
    if (!component) return { status: 'invalid' }

    const ctx: PropResolutionContext = scope
      ? {
          stateModel: state,
          repeatItem: scope.repeatItem,
          repeatIndex: scope.repeatIndex,
          repeatBasePath: scope.repeatBasePath
        }
      : { stateModel: state }

    if (!scope?.emptyRepeat) {
      const resolved = resolveElementProps((element.props ?? {}) as Record<string, unknown>, ctx)
      if (!component.props.safeParse(resolved).success) {
        return streaming ? { status: 'pending' } : { status: 'invalid' }
      }
      if (element.on) {
        for (const value of Object.values(element.on)) {
          for (const binding of Array.isArray(value) ? value : [value]) {
            const rawParams = (binding.params ?? {}) as Record<string, unknown>
            const resolvedParams: Record<string, unknown> = {}
            for (const [paramKey, paramVal] of Object.entries(rawParams)) {
              resolvedParams[paramKey] = resolveBlockActionParam(binding.action, paramKey, paramVal, ctx)
            }
            if (
              !withinDepth(resolvedParams, MAX_JSON_DEPTH) ||
              !validateActionParams(binding.action, rawParams, resolvedParams, state, repeatPaths, scope)
            ) {
              return streaming ? { status: 'pending' } : { status: 'invalid' }
            }
          }
        }
      }
    }

    return {
      status: 'ok',
      children: element.children ?? [],
      repeat: element.repeat as RepeatSpec | undefined
    }
  })

  return rootResult.status === 'ok'
}

/**
 * Builds the spec of a `ui` block from its JSON Patch lines, or returns undefined when the block is not usable.
 * A line that is not a complete patch is left out, so a streaming block shows what has arrived.
 *
 * The spec holds only what the catalog covers: every element reachable from the root has a catalog component and
 * valid props, the tree is acyclic and within the element budget, and events bind catalog actions only.
 */
export function compileUIBlock(code: string, streaming = false): Spec | undefined {
  const source: Partial<Spec> = {}
  for (const line of code.split('\n')) {
    if (!line.trim()) continue
    const patch = parseSpecStreamLine(line)
    if (!patch) {
      if (streaming) continue
      return undefined
    }
    if (
      !isSafePointer(patch.path) ||
      (patch.from !== undefined && !isSafePointer(patch.from)) ||
      !withinDepth(patch.value, MAX_JSON_DEPTH)
    ) {
      return undefined
    }
    try {
      applySpecStreamPatch(source as Record<string, unknown>, patch)
    } catch {
      return undefined
    }
  }

  const { root } = source
  const sources: Record<string, unknown> = isRecord(source.elements) ? source.elements : {}
  if (typeof root !== 'string' || sources[root] === undefined) return undefined

  const state: Record<string, unknown> = isRecord(source.state) ? source.state : {}
  seedBoundSwitchers(sources, state)
  const repeatPaths = collectRepeatPaths(root, key => sources[key], state)

  const elements: Spec['elements'] = {}
  const rootResult = walkBlockTree(root, state, streaming, streaming, (key, scope) => {
    if (sources[key] === undefined) {
      return streaming ? { status: 'pending' } : { status: 'invalid' }
    }
    const checked = checkElement(key, sources[key], state, repeatPaths, scope, streaming)
    if (checked.status !== 'ok') return checked
    const rawChildren = checked.element.children ?? []
    return {
      status: 'ok',
      children: rawChildren,
      repeat: checked.repeat,
      commitChildren: readyChildren => {
        const existing = elements[key]
        if (!existing) {
          elements[key] =
            streaming && readyChildren.length !== rawChildren.length
              ? { ...checked.element, children: readyChildren }
              : checked.element
          return
        }
        const prevChildren = existing.children ?? []
        const readySet = new Set(readyChildren)
        const intersected = prevChildren.filter(childKey => readySet.has(childKey))
        if (intersected.length !== prevChildren.length) {
          elements[key] = { ...existing, children: intersected }
        }
      }
    }
  })

  if (rootResult.status !== 'ok') return undefined
  if (streaming) pruneUnreachableElements(root, elements)
  return { root, elements, state }
}
