import { useQuery } from '@tanstack/react-query'
import { api, unwrap } from '@/lib/api'
import type { AiAgentModelProfileConfig } from '@/ai-agent/config'

export const TRANSPORT_OPTIONS = [
  'auto',
  'sse',
  'websocket',
  'websocket-cached'
] as const satisfies readonly NonNullable<AiAgentModelProfileConfig['transport']>[]

export function useAgentsQuery() {
  return useQuery({
    queryKey: ['console-agents'],
    queryFn: () => unwrap(api.console.agents.get())
  })
}

export function useAdaptersQuery() {
  return useQuery({
    queryKey: ['console-external-gateway-adapters'],
    queryFn: () => unwrap(api.console['external-gateway-adapters'].get())
  })
}

export function formatDate(value: Date | string | null | undefined): string {
  if (!value) return '-'
  const date = value instanceof Date ? value : new Date(value)
  if (Number.isNaN(date.getTime())) return '-'
  return date.toLocaleString()
}

export function optionalFiniteNumber(value: string, label: string): number | undefined {
  const trimmed = value.trim()
  if (!trimmed) return undefined

  const parsed = Number(trimmed)
  if (!Number.isFinite(parsed)) throw new Error(`${label} must be a finite number`)
  return parsed
}

export function optionalPositiveInteger(value: string, label: string): number | undefined {
  const trimmed = value.trim()
  if (!trimmed) return undefined

  const parsed = Number(trimmed)
  if (!Number.isInteger(parsed) || parsed <= 0) throw new Error(`${label} must be a positive integer`)
  return parsed
}

export function numberInputValue(value: number | undefined): string {
  return typeof value === 'number' && Number.isFinite(value) ? String(value) : ''
}
