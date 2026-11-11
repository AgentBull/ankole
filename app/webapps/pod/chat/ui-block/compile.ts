import {
  compileSpecStream,
  resolveElementProps,
  VisibilityConditionStrictSchema,
  type ActionBinding,
  type Spec,
  type UIElement
} from '@json-render/core'
import type { z } from 'zod'
import { uiBlockCatalog } from './catalog'

/**
 * A block may expand to this many elements. A committed message renders for every reader on every visit, so a
 * larger tree, or one that contains itself, would freeze the room.
 */
const ELEMENT_BUDGET = 500
const ACTIONS = new Set(['setState', ...uiBlockCatalog.actionNames])
const COMPONENTS: Record<string, { props: z.ZodType }> = uiBlockCatalog.data.components

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value)

/**
 * Keeps the catalog actions of an element's events, each with its parameters only; a binding cannot open a
 * confirmation dialog or name another action. Returns false when a binding is not usable.
 */
function events(on: unknown): Record<string, ActionBinding[]> | undefined | false {
  if (on == null) return undefined
  if (!isRecord(on)) return false
  const kept: Record<string, ActionBinding[]> = {}
  for (const [event, value] of Object.entries(on)) {
    kept[event] = []
    for (const binding of Array.isArray(value) ? value : [value]) {
      if (!isRecord(binding) || typeof binding.action !== 'string' || !ACTIONS.has(binding.action)) return false
      kept[event].push({
        action: binding.action,
        ...(isRecord(binding.params) && { params: binding.params as ActionBinding['params'] })
      })
    }
  }
  return kept
}

/** Returns the element in the form that the renderer receives, or undefined when the catalog does not cover it. */
function element(source: unknown, state: Record<string, unknown>, streaming: boolean): UIElement | undefined {
  if (!isRecord(source) || typeof source.type !== 'string' || !Object.hasOwn(COMPONENTS, source.type)) return undefined
  // The reference teaches neither `repeat`, `watch` nor named slots, and each multiplies or hides what renders.
  if (source.repeat != null || source.watch != null || source.slots != null) return undefined
  const props = source.props ?? {}
  const children = source.children ?? []
  const on = events(source.on)
  const listed = Array.isArray(children) && children.every(child => typeof child === 'string')
  const shown = source.visible === undefined || VisibilityConditionStrictSchema.safeParse(source.visible).success
  if (!isRecord(props) || !listed || on === false || !shown) return undefined
  // While a block streams, a prop may read state that a later line adds, so the props are checked once it settles.
  const resolved = resolveElementProps(props, { stateModel: state })
  if (!streaming && !COMPONENTS[source.type]!.props.safeParse(resolved).success) return undefined
  return {
    type: source.type,
    props,
    children: children as string[],
    ...(source.visible !== undefined && { visible: source.visible as UIElement['visible'] }),
    ...(on && { on })
  }
}

/**
 * Builds the spec of a `ui` block from its JSON Patch lines, or returns undefined when the block is not usable.
 * A line that is not a complete patch is left out, so a streaming block shows what has arrived.
 *
 * The spec holds only what the catalog covers: every element reachable from the root has a catalog component and
 * valid props, the tree is acyclic and within the element budget, and events bind catalog actions only.
 */
export function compileUIBlock(code: string, streaming = false): Spec | undefined {
  let source: Partial<Spec>
  try {
    source = compileSpecStream<Partial<Spec>>(code)
  } catch {
    // A patch that cannot apply, such as a failed `test`, leaves the block without a spec.
    return undefined
  }
  const { root } = source
  const sources: Record<string, unknown> = isRecord(source.elements) ? source.elements : {}
  if (typeof root !== 'string' || sources[root] === undefined) return undefined
  const state = isRecord(source.state) ? source.state : {}
  const elements: Spec['elements'] = {}
  const ancestors = new Set<string>()
  let budget = ELEMENT_BUDGET
  const usable = (key: string): boolean => {
    // A child that has not streamed in yet renders nothing; a settled block defines every child it names.
    if (sources[key] === undefined) return streaming
    if (ancestors.has(key) || --budget < 0) return false
    const checked = elements[key] ?? element(sources[key], state, streaming)
    if (!checked) return false
    elements[key] = checked
    ancestors.add(key)
    const reachable = checked.children!.every(usable)
    ancestors.delete(key)
    return reachable
  }
  return usable(root) ? { root, elements, state } : undefined
}
