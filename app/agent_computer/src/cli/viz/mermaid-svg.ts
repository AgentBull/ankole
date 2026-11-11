import {
  isPrintSafeSvg,
  materializePeleSvg,
  resolveVizTheme,
  type MarketConvention,
  type VizThemeMode
} from '@ankole/uikit/viz/theme'
import { PeleError } from 'pele/core'
import { renderAsync } from 'pele/lazy'

export interface RenderMermaidSvgOptions {
  theme?: VizThemeMode
  marketConvention?: MarketConvention
  tokenOverrides?: Partial<Record<string, string>>
  width?: number
  height?: number
}

export interface RenderedMermaidSvg {
  svg: string
  width: number
  height: number
  printSafe: boolean
}

export function formatMermaidSyntaxError(error: unknown): string {
  if (error instanceof PeleError) {
    return error.message.trim()
  }
  if (error instanceof Error && error.message.trim()) {
    return error.message.trim()
  }
  return 'Invalid Mermaid syntax.'
}

/**
 * Validates Mermaid diagram syntax directly in Bun via `pele` (`renderAsync`).
 */
export async function validateMermaidSyntax(source: string): Promise<{ ok: true } | { ok: false; errors: string[] }> {
  const trimmed = source.trim()
  if (!trimmed) {
    return { ok: false, errors: ['Mermaid diagram source is empty.'] }
  }
  try {
    await renderAsync(trimmed, { links: false, images: false, responsive: true })
    return { ok: true }
  } catch (error) {
    return { ok: false, errors: [formatMermaidSyntaxError(error)] }
  }
}

/**
 * Renders a Mermaid diagram directly in Bun via `pele` (`renderAsync`) into a Print-Safe SVG
 * without launching headless Chromium.
 */
export async function renderMermaidSvgInBun(
  source: string,
  options?: RenderMermaidSvgOptions
): Promise<RenderedMermaidSvg> {
  const trimmed = source.trim()
  if (!trimmed) {
    throw new Error('Mermaid diagram source is empty.')
  }

  const palette = resolveVizTheme(null, {
    theme: options?.theme ?? 'light',
    marketConvention: options?.marketConvention ?? 'intl',
    tokenOverrides: options?.tokenOverrides
  })

  let rendered
  try {
    rendered = await renderAsync(trimmed, {
      links: false,
      images: false,
      responsive: false,
      fontFamily: palette.fontSans,
      fontFamilyMono: palette.fontMono,
      ...(options?.width ? { maxWidth: options.width } : {})
    })
  } catch (error) {
    throw new Error(formatMermaidSyntaxError(error))
  }

  const materialized = materializePeleSvg(rendered.svg, palette, {
    width: options?.width,
    height: options?.height
  })
  const printSafe = isPrintSafeSvg(materialized.svg)
  if (!printSafe) {
    throw new Error('Rendered Mermaid SVG failed Print-Safe verification.')
  }

  return {
    svg: materialized.svg,
    width: materialized.width,
    height: materialized.height,
    printSafe
  }
}
