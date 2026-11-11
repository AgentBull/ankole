import { lazy, Suspense, useMemo, useSyncExternalStore } from 'react'
import { cn } from '../lib/utils'
import {
  computeGraphTopology,
  projectGraphAnchors,
  resolveCanvasThemePalette,
  type AnkoleCanvasThemePalette,
  type AnkoleGraphColorRamp,
  type AnkoleGraphCombo,
  type AnkoleGraphEdge,
  type AnkoleGraphLayoutMode,
  type AnkoleGraphNode,
  type AnkoleGraphNodeShape,
  type AnkoleGraphRampColors,
  type AnkoleGraphTopology,
  type GraphViewportReader,
  type ProjectedAnchor
} from '../viz/graph-layout'
import type { AnkoleGraphHandle, AnkoleGraphProps } from './graph'

export { computeGraphTopology, projectGraphAnchors, resolveCanvasThemePalette }
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
}

function subscribeThemeSignature(onChange: () => void): () => void {
  if (typeof document === 'undefined' || typeof MutationObserver === 'undefined') return () => {}
  const observer = new MutationObserver(onChange)
  observer.observe(document.documentElement, {
    attributes: true,
    attributeFilter: ['data-theme', 'class', 'style']
  })
  return () => observer.disconnect()
}

function currentThemeSignature(): string {
  if (typeof document === 'undefined') return 'light'
  const root = document.documentElement
  return `${root.getAttribute('data-theme') ?? 'light'}:${root.className}`
}

export function useCanvasThemePalette(): AnkoleCanvasThemePalette {
  const signature = useSyncExternalStore(subscribeThemeSignature, currentThemeSignature, () => 'light')
  return useMemo(() => {
    void signature
    return resolveCanvasThemePalette()
  }, [signature])
}

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
