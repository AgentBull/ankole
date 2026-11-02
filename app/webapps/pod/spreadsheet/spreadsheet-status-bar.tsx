import { t } from 'i18next'
import { useSignals } from '@preact/signals-react/runtime'
import { useEffect, useState } from 'react'
import { selectionRect, type SelectionStats } from '../state/spreadsheet-grid'
import type { SpreadsheetSession } from '../state/spreadsheet-collaboration'

const STATS_DELAY_MS = 120
const numberFormat = new Intl.NumberFormat(undefined, { maximumFractionDigits: 10 })

/** The sum, average, and count of a selection of several cells, as the status bar shows them. */
export function SpreadsheetStatusBar({ model }: { model: SpreadsheetSession }) {
  useSignals()
  const selection = model.selection.value
  const sheetID = model.activeSheetID.value
  const version = model.version.value
  const [stats, setStats] = useState<SelectionStats>()
  const rect = selectionRect(selection)
  const several = rect.r1 > rect.r0 || rect.c1 > rect.c0

  useEffect(() => {
    if (!several) {
      setStats(undefined)
      return
    }
    let stale = false
    // A drag selects many ranges in a row; only the one it stops on is counted.
    const timer = setTimeout(() => {
      void model
        .stats(sheetID, rect)
        .then(next => {
          if (!stale) setStats(next)
        })
        .catch(() => undefined)
    }, STATS_DELAY_MS)
    return () => {
      stale = true
      clearTimeout(timer)
    }
  }, [model, sheetID, version, several, rect.r0, rect.c0, rect.r1, rect.c1])

  if (!stats || stats.count === 0) return null
  return (
    <output
      aria-label={t('pod.spreadsheet.selection_stats')}
      className="ml-auto flex shrink-0 gap-3 px-2 text-xs text-fg-secondary">
      {stats.numbers > 0 && <span>{t('pod.spreadsheet.stats_sum', { value: numberFormat.format(stats.sum) })}</span>}
      {stats.average !== null && (
        <span>{t('pod.spreadsheet.stats_average', { value: numberFormat.format(stats.average) })}</span>
      )}
      <span>{t('pod.spreadsheet.stats_count', { value: stats.count })}</span>
    </output>
  )
}
