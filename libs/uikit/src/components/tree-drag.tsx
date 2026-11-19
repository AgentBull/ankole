import { autoScrollForElements } from '@atlaskit/pragmatic-drag-and-drop-auto-scroll/element'
import { attachInstruction } from '@atlaskit/pragmatic-drag-and-drop-hitbox/list-item/attach-instruction'
import { extractInstruction } from '@atlaskit/pragmatic-drag-and-drop-hitbox/list-item/extract-instruction'
import { combine } from '@atlaskit/pragmatic-drag-and-drop/combine'
import { draggable, dropTargetForElements } from '@atlaskit/pragmatic-drag-and-drop/element/adapter'
import { pointerOutsideOfPreview } from '@atlaskit/pragmatic-drag-and-drop/element/pointer-outside-of-preview'
import { setCustomNativeDragPreview } from '@atlaskit/pragmatic-drag-and-drop/element/set-custom-native-drag-preview'
import * as React from 'react'

export type TreeDropOperation = 'before' | 'after' | 'inside'
export type TreeDropAvailability = 'available' | 'blocked' | 'not-available'
export type TreeDrop = { source: string; target: string; operation: TreeDropOperation }
export type TreeDropIndication = { operation: TreeDropOperation; blocked: boolean } | null

type TreeItemDragOptions = {
  /** Items interact only inside one tree group. */
  tree: string
  id: string
  /** Text of the drag preview. */
  label?: string
  canDrag?: boolean
  availability(source: string, operation: TreeDropOperation): TreeDropAvailability
  onDrop(drop: TreeDrop): void
  /** Called once when a pointer rests on the item as an "inside" drop, for example to expand it. */
  onRestInside?(): void
}

const treeKey = 'ankole-tree'
const fromOperation = { 'reorder-before': 'before', 'reorder-after': 'after', combine: 'inside' } as const
const restDelay = 500

/**
 * Makes a tree row a drop target, and its handle a drag source when a handle is attached.
 * The row and the handle can be the same element.
 */
function useTreeItemDrag<Handle extends HTMLElement = HTMLElement, Target extends HTMLElement = HTMLElement>(
  options: TreeItemDragOptions
) {
  const [handle, setHandle] = React.useState<Handle | null>(null)
  const [target, setTarget] = React.useState<Target | null>(null)
  const [dragging, setDragging] = React.useState(false)
  const [indication, setIndication] = React.useState<TreeDropIndication>(null)
  const latest = React.useRef(options)
  React.useLayoutEffect(() => {
    latest.current = options
  })

  React.useEffect(() => {
    if (!target) return
    let rest: ReturnType<typeof setTimeout> | undefined
    const stopRest = () => {
      clearTimeout(rest)
      rest = undefined
    }
    const show = (next: TreeDropIndication) =>
      setIndication(current =>
        current?.operation === next?.operation && current?.blocked === next?.blocked ? current : next
      )
    const cleanups = [
      dropTargetForElements({
        element: target,
        canDrop: ({ source }) => source.data[treeKey] === latest.current.tree && source.data.id !== latest.current.id,
        getIsSticky: () => true,
        getData: ({ input, element, source }) => {
          const sourceID = String(source.data.id)
          return attachInstruction(
            { id: latest.current.id },
            {
              input,
              element,
              axis: 'vertical',
              operations: {
                'reorder-before': latest.current.availability(sourceID, 'before'),
                'reorder-after': latest.current.availability(sourceID, 'after'),
                combine: latest.current.availability(sourceID, 'inside')
              }
            }
          )
        },
        onDrag: ({ self }) => {
          const instruction = extractInstruction(self.data)
          const next = instruction && { operation: fromOperation[instruction.operation], blocked: instruction.blocked }
          show(next)
          if (next?.operation === 'inside' && !next.blocked) {
            rest ??= setTimeout(() => latest.current.onRestInside?.(), restDelay)
          } else stopRest()
        },
        onDragLeave: () => {
          show(null)
          stopRest()
        },
        onDrop: ({ self, source }) => {
          show(null)
          stopRest()
          const instruction = extractInstruction(self.data)
          if (instruction && !instruction.blocked) {
            latest.current.onDrop({
              source: String(source.data.id),
              target: latest.current.id,
              operation: fromOperation[instruction.operation]
            })
          }
        }
      })
    ]
    if (handle) {
      cleanups.push(
        draggable({
          element: handle,
          canDrag: () => latest.current.canDrag !== false,
          getInitialData: () => ({ [treeKey]: latest.current.tree, id: latest.current.id }),
          onGenerateDragPreview: ({ nativeSetDragImage }) => {
            const label = latest.current.label
            if (!label) return
            setCustomNativeDragPreview({
              nativeSetDragImage,
              getOffset: pointerOutsideOfPreview({ x: '12px', y: '8px' }),
              render: ({ container }) => {
                const preview = document.createElement('div')
                preview.className = 'ankole-tree-drag-preview'
                preview.textContent = label
                container.append(preview)
              }
            })
          },
          onDragStart: () => setDragging(true),
          onDrop: () => setDragging(false)
        })
      )
    }
    return () => {
      stopRest()
      combine(...cleanups)()
    }
  }, [handle, target])

  return { handleRef: setHandle, targetRef: setTarget, dragging, indication }
}

/** Scrolls a container while a tree item is dragged near its edge. */
function useTreeAutoScroll<Container extends HTMLElement>(tree: string) {
  const [element, setElement] = React.useState<Container | null>(null)
  React.useEffect(
    () =>
      element
        ? autoScrollForElements({ element, canScroll: ({ source }) => source.data[treeKey] === tree })
        : undefined,
    [element, tree]
  )
  return setElement
}

/** Marks the drop place: an ink line before or after the row, or an ink ring around it. */
function TreeDropIndicator({ indication, indent = 0 }: { indication: TreeDropIndication; indent?: number }) {
  if (!indication || indication.blocked) return null
  return (
    <span
      aria-hidden
      data-slot="tree-drop-indicator"
      data-operation={indication.operation}
      style={{ '--tree-drop-indent': `${indent}px` } as React.CSSProperties}
    />
  )
}

export { TreeDropIndicator, useTreeAutoScroll, useTreeItemDrag }
