import { isRecord } from '@agentbull/active-support'
import type { FinancialChartSpec, FinancialMainPoint, FinancialVolumePoint } from '@ankole/uikit/viz/financial'
import type { AnkoleGraphCombo, AnkoleGraphEdge, AnkoleGraphNode, GraphVizSpec } from '@ankole/uikit/viz/graph'
import { validateInfographicSyntax } from '@ankole/uikit/viz/infographic'
import type { StatisticalChartSpec, StatisticalChartType } from '@ankole/uikit/viz/statistical'
import { z } from 'zod'
import { validateMermaidSyntax } from './mermaid-svg'

export const VIZ_KINDS = ['mermaid', 'infographic', 'chart', 'kline', 'graph'] as const
export type VizKind = (typeof VIZ_KINDS)[number]

export const STATISTICAL_CHART_TYPES = [
  'column',
  'bar',
  'line',
  'area',
  'combo',
  'pie',
  'donut',
  'funnel',
  'scatter',
  'histogram',
  'boxplot',
  'heatmap',
  'radar',
  'waterfall',
  'gauge',
  'treemap',
  'sunburst',
  'sankey',
  'wordcloud'
] as const satisfies readonly StatisticalChartType[]

const BUSINESS_DAY_RE = /^(\d{4})-(\d{2})-(\d{2})$/

function isValidBusinessDay(value: string): boolean {
  const match = BUSINESS_DAY_RE.exec(value.trim())
  if (!match) return false
  const year = Number(match[1])
  const month = Number(match[2])
  const day = Number(match[3])
  if (month < 1 || month > 12 || day < 1 || day > 31) return false
  const utc = new Date(Date.UTC(year, month - 1, day))
  return utc.getUTCFullYear() === year && utc.getUTCMonth() === month - 1 && utc.getUTCDate() === day
}

function formatZodIssues(error: z.ZodError): string[] {
  return error.issues.map(issue => {
    const path = issue.path.length > 0 ? `${issue.path.join('.')}: ` : ''
    return `${path}${issue.message}`
  })
}

const StatisticalSpecEnvelopeSchema = z
  .object({
    type: z.enum(STATISTICAL_CHART_TYPES),
    data: z.union([z.array(z.record(z.string(), z.unknown())).min(1), z.record(z.string(), z.unknown())]),
    xField: z.string().min(1).optional(),
    yField: z.string().min(1).optional(),
    secondaryYField: z.string().min(1).optional(),
    seriesField: z.string().min(1).optional(),
    sizeField: z.string().min(1).optional(),
    valueField: z.string().min(1).optional(),
    sourceField: z.string().min(1).optional(),
    targetField: z.string().min(1).optional(),
    stackMode: z.enum(['grouped', 'stacked', 'percent']).optional(),
    title: z.string().optional(),
    subtitle: z.string().optional(),
    showLegend: z.boolean().optional(),
    width: z.number().positive().optional(),
    height: z.number().positive().optional()
  })
  .passthrough()

export function validateAndNormalizeChartSpec(
  rawInput: unknown
): { ok: true; spec: StatisticalChartSpec } | { ok: false; errors: string[] } {
  if (!isRecord(rawInput)) {
    return { ok: false, errors: ['Chart spec must be a JSON object.'] }
  }

  const normalizedInput: Record<string, unknown> = { ...rawInput }
  if (normalizedInput.type === undefined) {
    if (typeof normalizedInput.chartType === 'string') {
      normalizedInput.type = normalizedInput.chartType
    } else if (typeof normalizedInput.chart_type === 'string') {
      normalizedInput.type = normalizedInput.chart_type
    }
  }
  if (normalizedInput.stackMode === undefined && typeof normalizedInput.stack_mode === 'string') {
    normalizedInput.stackMode = normalizedInput.stack_mode
  }

  const parsed = StatisticalSpecEnvelopeSchema.safeParse(normalizedInput)
  if (!parsed.success) {
    return { ok: false, errors: formatZodIssues(parsed.error) }
  }

  const { type, data } = parsed.data
  if (!Array.isArray(data)) {
    if (type === 'gauge') {
      const target = data.target ?? data.value
      if (typeof target !== 'number' || !Number.isFinite(target)) {
        return { ok: false, errors: ['data: gauge object data must include a finite numeric target or value.'] }
      }
    } else if (type === 'treemap' || type === 'sunburst') {
      if (!Array.isArray(data.children) || data.children.length === 0) {
        return { ok: false, errors: [`data: ${type} hierarchy object must contain a non-empty children array.`] }
      }
    } else if (type === 'sankey') {
      if (!Array.isArray(data.links) || data.links.length === 0) {
        return { ok: false, errors: ['data: sankey object data must contain a non-empty links array.'] }
      }
    } else {
      return { ok: false, errors: [`data: chart type "${type}" requires a non-empty data array.`] }
    }
  }

  return { ok: true, spec: parsed.data as unknown as StatisticalChartSpec }
}

const KlineOhlcPointSchema = z.object({
  time: z.union([z.string().min(1), z.number().finite()]),
  open: z.number().finite(),
  high: z.number().finite(),
  low: z.number().finite(),
  close: z.number().finite()
})

const KlineValuePointSchema = z.object({
  time: z.union([z.string().min(1), z.number().finite()]),
  value: z.number().finite()
})

const KlineEnvelopeSchema = z
  .object({
    mode: z.enum(['standard', 'yield_curve']).optional(),
    seriesType: z.enum(['candlestick', 'bar', 'baseline', 'line', 'area']).optional(),
    priceScaleMode: z.enum(['normal', 'logarithmic', 'percentage', 'indexedTo100']).optional(),
    basePrice: z.number().finite().optional(),
    color: z.string().min(1).optional(),
    title: z.string().optional(),
    subtitle: z.string().optional(),
    showVolume: z.boolean().optional(),
    attributionLogo: z.boolean().optional(),
    width: z.number().positive().optional(),
    height: z.number().positive().optional(),
    data: z.array(z.record(z.string(), z.unknown())).min(1)
  })
  .passthrough()

function toFiniteNum(val: unknown): number | undefined {
  if (typeof val === 'number' && Number.isFinite(val)) return val
  if (typeof val === 'string' && val.trim() !== '') {
    const n = Number(val.trim())
    if (Number.isFinite(n)) return n
  }
  return undefined
}

export interface NormalizedKlineSpec {
  spec: FinancialChartSpec
  title?: string
  subtitle?: string
}

export function validateAndNormalizeKlineSpec(
  rawInput: unknown
): ({ ok: true } & NormalizedKlineSpec) | { ok: false; errors: string[] } {
  if (!isRecord(rawInput)) {
    return { ok: false, errors: ['Kline spec must be a JSON object.'] }
  }

  const envelope = KlineEnvelopeSchema.safeParse(rawInput)
  if (!envelope.success) {
    return { ok: false, errors: formatZodIssues(envelope.error) }
  }

  const errors: string[] = []
  const seriesType = envelope.data.seriesType
  const requiresOhlc = seriesType === 'candlestick' || seriesType === 'bar'
  const mainPoints: FinancialMainPoint[] = []
  const extractedVolumes: FinancialVolumePoint[] = []
  let expectedTimeKind: 'string' | 'number' | null = null

  envelope.data.data.forEach((rawRow, idx) => {
    const rawTime = rawRow.time ?? rawRow.date ?? rawRow.timestamp
    let time: string | number | undefined
    if (typeof rawTime === 'number' && Number.isFinite(rawTime)) {
      time = Math.abs(rawTime) >= 1e11 ? Math.floor(rawTime / 1000) : rawTime
    } else if (typeof rawTime === 'string') {
      const trimmed = rawTime.trim()
      if (isValidBusinessDay(trimmed)) {
        time = trimmed
      } else if (/^-?\d+(?:\.\d+)?$/.test(trimmed)) {
        const num = Number(trimmed)
        if (Number.isFinite(num)) {
          time = Math.abs(num) >= 1e11 ? Math.floor(num / 1000) : num
        }
      }
    }

    if (time === undefined) {
      errors.push(
        `data[${idx}].time: must be a valid 'YYYY-MM-DD' business day string or finite numeric timestamp/tenor.`
      )
      return
    }

    const currentKind = typeof time as 'string' | 'number'
    if (expectedTimeKind === null) {
      expectedTimeKind = currentKind
    } else if (expectedTimeKind !== currentKind) {
      errors.push(`data[${idx}].time: cannot mix business-day strings and numeric timestamps in the same series.`)
      return
    }

    const open = toFiniteNum(rawRow.open)
    const high = toFiniteNum(rawRow.high)
    const low = toFiniteNum(rawRow.low)
    const close = toFiniteNum(rawRow.close)
    const singleValue = toFiniteNum(rawRow.value)

    if (open !== undefined || high !== undefined || low !== undefined || close !== undefined || requiresOhlc) {
      const ohlcCheck = KlineOhlcPointSchema.safeParse({ time, open, high, low, close })
      if (!ohlcCheck.success) {
        errors.push(`data[${idx}]: OHLC bar requires finite open, high, low, and close numbers.`)
        return
      }
      if (ohlcCheck.data.high < ohlcCheck.data.low) {
        errors.push(`data[${idx}]: high (${ohlcCheck.data.high}) cannot be less than low (${ohlcCheck.data.low}).`)
        return
      }
      mainPoints.push(ohlcCheck.data)
    } else {
      const valCheck = KlineValuePointSchema.safeParse({ time, value: singleValue })
      if (!valCheck.success) {
        errors.push(`data[${idx}]: point requires either OHLC (open, high, low, close) or a finite numeric value.`)
        return
      }
      mainPoints.push(valCheck.data)
    }

    const vol = toFiniteNum(rawRow.volume)
    if (vol !== undefined) {
      extractedVolumes.push({
        time,
        value: vol,
        ...(typeof rawRow.volumeColor === 'string' ? { color: rawRow.volumeColor } : {})
      })
    }
  })

  if (errors.length > 0) {
    return { ok: false, errors }
  }

  const compareTime = (a: string | number, b: string | number): number => {
    if (typeof a === 'number' && typeof b === 'number') return a - b
    return String(a) < String(b) ? -1 : String(a) > String(b) ? 1 : 0
  }

  mainPoints.sort((a, b) => compareTime(a.time as string | number, b.time as string | number))
  for (let i = 1; i < mainPoints.length; i += 1) {
    if (mainPoints[i]!.time === mainPoints[i - 1]!.time) {
      return { ok: false, errors: [`data: duplicate financial timestamp "${String(mainPoints[i]!.time)}".`] }
    }
  }

  let explicitVolume: FinancialVolumePoint[] | undefined
  if (Array.isArray(rawInput.volume)) {
    explicitVolume = []
    for (let i = 0; i < rawInput.volume.length; i += 1) {
      const item = rawInput.volume[i]
      if (!isRecord(item)) {
        return { ok: false, errors: [`volume[${i}]: must be an object with time and value.`] }
      }
      const vTime = item.time
      const vVal = toFiniteNum(item.value)
      if ((typeof vTime !== 'string' && typeof vTime !== 'number') || vVal === undefined) {
        return { ok: false, errors: [`volume[${i}]: requires valid time and finite numeric value.`] }
      }
      explicitVolume.push({
        time: vTime,
        value: vVal,
        ...(typeof item.color === 'string' ? { color: item.color } : {})
      })
    }
    explicitVolume.sort((a, b) => compareTime(a.time as string | number, b.time as string | number))
  } else if (envelope.data.showVolume !== false && extractedVolumes.length > 0) {
    extractedVolumes.sort((a, b) => compareTime(a.time as string | number, b.time as string | number))
    explicitVolume = extractedVolumes
  }

  const spec: FinancialChartSpec = {
    ...(envelope.data.mode ? { mode: envelope.data.mode } : {}),
    ...(envelope.data.seriesType ? { seriesType: envelope.data.seriesType } : {}),
    ...(envelope.data.priceScaleMode ? { priceScaleMode: envelope.data.priceScaleMode } : {}),
    ...(envelope.data.basePrice !== undefined ? { basePrice: envelope.data.basePrice } : {}),
    ...(envelope.data.color ? { color: envelope.data.color } : {}),
    ...(envelope.data.attributionLogo !== undefined ? { attributionLogo: envelope.data.attributionLogo } : {}),
    ...(envelope.data.width ? { width: envelope.data.width } : {}),
    ...(envelope.data.height ? { height: envelope.data.height } : {}),
    ...(typeof rawInput.marketConvention === 'string' &&
    (rawInput.marketConvention === 'intl' || rawInput.marketConvention === 'cn')
      ? { marketConvention: rawInput.marketConvention }
      : {}),
    data: mainPoints,
    ...(explicitVolume && explicitVolume.length > 0 ? { volume: explicitVolume } : {}),
    ...(Array.isArray(rawInput.overlays) ? { overlays: rawInput.overlays as FinancialChartSpec['overlays'] } : {}),
    ...(Array.isArray(rawInput.subPanes) ? { subPanes: rawInput.subPanes as FinancialChartSpec['subPanes'] } : {}),
    ...(Array.isArray(rawInput.markers) ? { markers: rawInput.markers as FinancialChartSpec['markers'] } : {})
  }

  return {
    ok: true,
    spec,
    ...(envelope.data.title ? { title: envelope.data.title } : {}),
    ...(envelope.data.subtitle ? { subtitle: envelope.data.subtitle } : {})
  }
}

const GraphColorRampSchema = z.enum([
  'blue',
  'teal',
  'purple',
  'brand',
  'green',
  'orange',
  'cyan',
  'magenta',
  'yellow',
  'gray'
])

const GraphNodeInputSchema = z
  .object({
    id: z.string().min(1),
    label: z.string().min(1).optional(),
    subtitle: z.string().optional(),
    ramp: GraphColorRampSchema.optional(),
    shape: z.enum(['circle', 'diamond', 'hexagon', 'rect']).optional(),
    comboId: z.string().min(1).optional(),
    parentId: z.string().min(1).nullable().optional(),
    tier: z.enum(['hub', 'object']).optional(),
    href: z.string().optional(),
    weight: z.number().finite().optional()
  })
  .passthrough()

const GraphEdgeInputSchema = z
  .object({
    id: z.string().min(1).optional(),
    source: z.string().min(1),
    target: z.string().min(1),
    label: z.string().optional(),
    ramp: GraphColorRampSchema.optional(),
    dashed: z.boolean().optional(),
    kind: z.enum(['hierarchy', 'relation']).optional()
  })
  .passthrough()

const GraphComboInputSchema = z
  .object({
    id: z.string().min(1),
    label: z.string().min(1).optional(),
    ramp: GraphColorRampSchema.optional(),
    parentId: z.string().min(1).optional()
  })
  .passthrough()

const GraphEnvelopeSchema = z
  .object({
    nodes: z.array(GraphNodeInputSchema).min(1),
    edges: z.array(GraphEdgeInputSchema).optional(),
    combos: z.array(GraphComboInputSchema).optional(),
    layout: z.enum(['force', 'hierarchy', 'combo', 'radial']).optional(),
    showEdgeLabels: z.boolean().optional(),
    selectedNodeId: z.string().nullable().optional(),
    highlightedNodeId: z.string().nullable().optional(),
    focusCenterNodeId: z.string().nullable().optional(),
    width: z.number().positive().optional(),
    height: z.number().positive().optional(),
    title: z.string().optional(),
    subtitle: z.string().optional()
  })
  .passthrough()

export interface NormalizedGraphSpec {
  spec: GraphVizSpec
  title?: string
  subtitle?: string
}

export function validateAndNormalizeGraphSpec(
  rawInput: unknown
): ({ ok: true } & NormalizedGraphSpec) | { ok: false; errors: string[] } {
  if (!isRecord(rawInput)) {
    return { ok: false, errors: ['Graph spec must be a JSON object.'] }
  }

  const parsed = GraphEnvelopeSchema.safeParse(rawInput)
  if (!parsed.success) {
    return { ok: false, errors: formatZodIssues(parsed.error) }
  }

  const nodeIds = new Set<string>()
  const errors: string[] = []
  const nodes: AnkoleGraphNode[] = []

  for (let i = 0; i < parsed.data.nodes.length; i += 1) {
    const rawNode = parsed.data.nodes[i]!
    if (nodeIds.has(rawNode.id)) {
      errors.push(`nodes[${i}].id: duplicate node id "${rawNode.id}".`)
      continue
    }
    nodeIds.add(rawNode.id)
    nodes.push({
      id: rawNode.id,
      label: rawNode.label ?? rawNode.id,
      ...(rawNode.subtitle ? { subtitle: rawNode.subtitle } : {}),
      ...(rawNode.ramp ? { ramp: rawNode.ramp } : {}),
      ...(rawNode.shape ? { shape: rawNode.shape } : {}),
      ...(rawNode.comboId ? { comboId: rawNode.comboId } : {}),
      ...(rawNode.parentId !== undefined ? { parentId: rawNode.parentId } : {}),
      ...(rawNode.tier ? { tier: rawNode.tier } : {}),
      ...(rawNode.href ? { href: rawNode.href } : {}),
      ...(rawNode.weight !== undefined ? { weight: rawNode.weight } : {})
    })
  }

  const edges: AnkoleGraphEdge[] = []
  const rawEdges = parsed.data.edges ?? []
  for (let i = 0; i < rawEdges.length; i += 1) {
    const rawEdge = rawEdges[i]!
    if (!nodeIds.has(rawEdge.source)) {
      errors.push(`edges[${i}].source: references unknown node "${rawEdge.source}".`)
    }
    if (!nodeIds.has(rawEdge.target)) {
      errors.push(`edges[${i}].target: references unknown node "${rawEdge.target}".`)
    }
    edges.push({
      id: rawEdge.id ?? `edge-${i + 1}`,
      source: rawEdge.source,
      target: rawEdge.target,
      ...(rawEdge.label ? { label: rawEdge.label } : {}),
      ...(rawEdge.ramp ? { ramp: rawEdge.ramp } : {}),
      ...(rawEdge.dashed !== undefined ? { dashed: rawEdge.dashed } : {}),
      ...(rawEdge.kind ? { kind: rawEdge.kind } : {})
    })
  }

  const combos: AnkoleGraphCombo[] | undefined = parsed.data.combos?.map(c => ({
    id: c.id,
    label: c.label ?? c.id,
    ...(c.ramp ? { ramp: c.ramp } : {}),
    ...(c.parentId ? { parentId: c.parentId } : {})
  }))

  if (errors.length > 0) {
    return { ok: false, errors }
  }

  const spec: GraphVizSpec = {
    nodes,
    edges,
    ...(combos && combos.length > 0 ? { combos } : {}),
    ...(parsed.data.layout ? { layout: parsed.data.layout } : {}),
    ...(parsed.data.showEdgeLabels !== undefined ? { showEdgeLabels: parsed.data.showEdgeLabels } : {}),
    ...(parsed.data.selectedNodeId !== undefined ? { selectedNodeId: parsed.data.selectedNodeId } : {}),
    ...(parsed.data.highlightedNodeId !== undefined ? { highlightedNodeId: parsed.data.highlightedNodeId } : {}),
    ...(parsed.data.focusCenterNodeId !== undefined ? { focusCenterNodeId: parsed.data.focusCenterNodeId } : {}),
    ...(parsed.data.width ? { width: parsed.data.width } : {}),
    ...(parsed.data.height ? { height: parsed.data.height } : {})
  }

  return {
    ok: true,
    spec,
    ...(parsed.data.title ? { title: parsed.data.title } : {}),
    ...(parsed.data.subtitle ? { subtitle: parsed.data.subtitle } : {})
  }
}

export async function validateByKind(
  kind: VizKind,
  rawTextOrSpec: string | unknown
): Promise<{ ok: true; valid: true; kind: VizKind } | { ok: false; valid: false; kind: VizKind; errors: string[] }> {
  if (kind === 'mermaid') {
    const text = typeof rawTextOrSpec === 'string' ? rawTextOrSpec : String(rawTextOrSpec ?? '')
    const res = await validateMermaidSyntax(text)
    return res.ok ? { ok: true, valid: true, kind } : { ok: false, valid: false, kind, errors: res.errors }
  }

  if (kind === 'infographic') {
    const text = typeof rawTextOrSpec === 'string' ? rawTextOrSpec : String(rawTextOrSpec ?? '')
    const res = validateInfographicSyntax(text)
    return res.ok ? { ok: true, valid: true, kind } : { ok: false, valid: false, kind, errors: res.errors }
  }

  let parsedObj: unknown = rawTextOrSpec
  if (typeof rawTextOrSpec === 'string') {
    try {
      parsedObj = JSON.parse(rawTextOrSpec)
    } catch (error) {
      return {
        ok: false,
        valid: false,
        kind,
        errors: [`Invalid JSON spec: ${error instanceof Error ? error.message : String(error)}`]
      }
    }
  }

  if (kind === 'chart') {
    const res = validateAndNormalizeChartSpec(parsedObj)
    return res.ok ? { ok: true, valid: true, kind } : { ok: false, valid: false, kind, errors: res.errors }
  }

  if (kind === 'kline') {
    const res = validateAndNormalizeKlineSpec(parsedObj)
    return res.ok ? { ok: true, valid: true, kind } : { ok: false, valid: false, kind, errors: res.errors }
  }

  const res = validateAndNormalizeGraphSpec(parsedObj)
  return res.ok ? { ok: true, valid: true, kind } : { ok: false, valid: false, kind, errors: res.errors }
}
