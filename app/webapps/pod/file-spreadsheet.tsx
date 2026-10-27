import { t } from 'i18next'
import { Button } from '@ankole/uikit'
import { useQuery } from '@tanstack/react-query'
import { useMemo, useState } from 'react'
import { read, utils } from 'xlsx'
import { ContentError } from './content-primitives'

export default function SpreadsheetPreview({ url }: { url: string }) {
  const [sheet, setSheet] = useState('')
  const workbook = useQuery({
    queryKey: ['file-spreadsheet', url],
    queryFn: async ({ signal }) => {
      const response = await fetch(url, { signal })
      if (!response.ok) throw new Error(t('pod.content.could_not_read_the_spreadsheet_file'))
      return read(await response.arrayBuffer())
    },
    retry: false
  })
  const selected = workbook.data?.SheetNames.includes(sheet) ? sheet : workbook.data?.SheetNames[0]
  const html = useMemo(
    () =>
      selected && workbook.data?.Sheets[selected]
        ? utils.sheet_to_html(workbook.data.Sheets[selected], { editable: false })
        : '',
    [workbook.data, selected]
  )
  return (
    <div className="space-y-3">
      <ContentError error={workbook.error} />
      {workbook.isPending && <p role="status">{t('pod.content.reading_spreadsheet')}</p>}
      <nav
        aria-label={t('pod.content.worksheet')}
        className="flex flex-nowrap items-center gap-1 overflow-x-auto py-0.5">
        {workbook.data?.SheetNames.map(name => (
          <Button
            key={name}
            size="sm"
            className="shrink-0"
            variant={name === selected ? 'outline' : 'ghost'}
            aria-pressed={name === selected}
            onClick={() => setSheet(name)}>
            {name}
          </Button>
        ))}
      </nav>
      {selected && (
        <iframe
          title={t('pod.content.worksheet_2', { value1: selected })}
          sandbox=""
          className="h-[65vh] w-full rounded border border-border bg-white"
          srcDoc={`<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:"><style>body{margin:12px;font:14px sans-serif;color:#161616}table{border-collapse:collapse}td,th{border:1px solid #ddd;padding:6px 10px;min-width:60px;white-space:pre-wrap}a{color:inherit}</style>${html}`}
        />
      )}
      <p className="text-xs text-fg-tertiary">
        {t('pod.content.the_preview_shows_cell_contents_number_formats_and_merged_cells')}
      </p>
    </div>
  )
}
