import { buildPelePaletteCssVars, MERMAID_PALETTES, type MermaidThemeMode } from './mermaid-renderer'

export const MERMAID_FRAME_CSP = "default-src 'none'; style-src 'unsafe-inline'; img-src data:;"

/**
 * Builds an isolated HTML document for `<iframe sandbox="" referrerPolicy="no-referrer" srcDoc>`.
 * Scripts, network requests, forms, and navigation are blocked by both `sandbox=""` and CSP.
 */
export function buildMermaidSrcDoc(options: {
  svg: string
  theme: MermaidThemeMode
  width: number
  height: number
  scale?: number
  fitContainer?: boolean
}): string {
  const { svg, theme, width, height, scale = 1, fitContainer = true } = options
  const paletteVars = buildPelePaletteCssVars(theme)
  const bg = MERMAID_PALETTES[theme].bg
  const scaledWidth = Math.max(1, Math.round(width * scale))
  const scaledHeight = Math.max(1, Math.round(height * scale))
  const svgSizing = fitContainer
    ? `max-width:100%;height:auto;width:${scaledWidth}px;`
    : `width:${scaledWidth}px;height:${scaledHeight}px;max-width:none;`

  return [
    '<!DOCTYPE html>',
    `<html lang="en" translate="no" class="notranslate">`,
    '<head>',
    '<meta charset="utf-8">',
    `<meta http-equiv="Content-Security-Policy" content="${MERMAID_FRAME_CSP}">`,
    '<style>',
    `:root{${paletteVars};color-scheme:${theme};}`,
    `html,body{margin:0;padding:0;background:${bg};color:var(--pele-fg);font-family:var(--pele-font);overflow:${fitContainer ? 'auto' : 'hidden'};}`,
    `.stage{display:flex;align-items:center;justify-content:center;min-width:100%;min-height:100%;box-sizing:border-box;padding:${fitContainer ? '16px' : '0'};}`,
    `.stage svg{display:block;${svgSizing}}`,
    '</style>',
    '</head>',
    `<body><div class="stage">${svg}</div></body>`,
    '</html>'
  ].join('')
}
