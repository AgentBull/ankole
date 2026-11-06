import { lazy, Suspense } from 'react'
import { cn } from '../lib/utils'
import type { AnkoleGraphHandle, AnkoleGraphProps } from './graph'

export type { AnkoleGraphHandle, AnkoleGraphProps }
export type {
  AnkoleCanvasThemePalette,
  AnkoleGraphColorRamp,
  AnkoleGraphCombo,
  AnkoleGraphEdge,
  AnkoleGraphLayoutMode,
  AnkoleGraphNode,
  AnkoleGraphNodeShape,
  AnkoleGraphRampColors,
  AnkoleGraphTopology,
  GraphViewportReader,
  ProjectedAnchor
} from '../viz/graph-layout'

const LazyGraphInner = lazy(() => import('./graph').then(module => ({ default: module.AnkoleGraph })))

export function AnkoleLazyGraph(props: AnkoleGraphProps) {
  return (
    <Suspense
      fallback={
        <div
          role="status"
          aria-label={props.ariaLabel}
          className={cn(
            'relative isolate min-h-[520px] w-full rounded-control border border-border bg-background',
            props.className
          )}
        />
      }>
      <LazyGraphInner {...props} />
    </Suspense>
  )
}

export { AnkoleLazyGraph as AnkoleGraph, AnkoleLazyGraph as Graph }
