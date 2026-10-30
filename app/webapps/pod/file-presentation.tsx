import { useTranslation } from 'react-i18next'
import { Button } from '@ankole/uikit'
import { RiArrowLeftSLine, RiArrowRightSLine } from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import { useEffect, useRef, useState } from 'react'
import { getSlides, loadPresentation } from '@office-kit/pptx'
import { renderSlideToSvg } from '@office-kit/pptx-preview'
import { ContentError } from './content-primitives'

export default function PresentationPreview({ url }: { url: string }) {
  const { t } = useTranslation()
  const [selected, setSelected] = useState(0)
  const navRef = useRef<HTMLElement>(null)
  const slides = useQuery({
    queryKey: ['file-presentation', url],
    queryFn: async ({ signal }) => {
      const response = await fetch(url, { signal })
      if (!response.ok) throw new Error(t('pod.content.could_not_read_the_presentation'))
      const presentation = await loadPresentation(await response.arrayBuffer())
      return getSlides(presentation).map(slide => renderSlideToSvg(presentation, slide))
    },
    retry: false
  })
  const total = slides.data?.length ?? 0
  const selectedIndex = slides.data?.[selected] ? selected : 0
  const current = slides.data?.[selectedIndex]
  useEffect(() => {
    navRef.current
      ?.querySelector<HTMLElement>('[aria-pressed="true"]')
      ?.scrollIntoView({ block: 'nearest', inline: 'nearest' })
  }, [selectedIndex, total])
  return (
    <div className="space-y-3">
      <ContentError error={slides.error} />
      {slides.isPending && <p role="status">{t('pod.content.reading_presentation')}</p>}
      <div className="flex items-center gap-1.5">
        {total > 1 && (
          <Button
            type="button"
            size="icon-sm"
            variant="ghost"
            className="shrink-0"
            aria-label={t('pod.content.previous_page')}
            title={t('pod.content.previous_page')}
            disabled={selectedIndex <= 0}
            onClick={() => setSelected(Math.max(0, selectedIndex - 1))}>
            <RiArrowLeftSLine aria-hidden className="size-4" />
          </Button>
        )}
        <nav
          ref={navRef}
          aria-label={t('pod.content.slides')}
          className="flex min-w-0 flex-1 flex-nowrap items-center gap-1 overflow-x-auto py-0.5">
          {slides.data?.map((_slide, index) => (
            <Button
              key={index}
              size="sm"
              className="shrink-0"
              variant={index === selectedIndex ? 'outline' : 'ghost'}
              aria-pressed={index === selectedIndex}
              onClick={() => setSelected(index)}>
              {t('pod.content.page', { value1: index + 1 })}
            </Button>
          ))}
        </nav>
        {total > 1 && (
          <>
            <Button
              type="button"
              size="icon-sm"
              variant="ghost"
              className="shrink-0"
              aria-label={t('pod.content.next_page')}
              title={t('pod.content.next_page')}
              disabled={selectedIndex >= total - 1}
              onClick={() => setSelected(Math.min(total - 1, selectedIndex + 1))}>
              <RiArrowRightSLine aria-hidden className="size-4" />
            </Button>
            <span className="shrink-0 text-xs tabular-nums text-fg-tertiary">
              {selectedIndex + 1} / {total}
            </span>
          </>
        )}
      </div>
      {current && (
        <iframe
          title={t('pod.content.slide', { value1: selectedIndex + 1 })}
          sandbox=""
          className="aspect-video w-full rounded border border-border bg-white"
          srcDoc={`<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data: blob:"><style>html,body{margin:0;width:100%;height:100%;overflow:hidden}svg{width:100%;height:100%}</style>${current}`}
        />
      )}
      <p className="text-xs text-fg-tertiary">
        {t('pod.content.fonts_and_complex_graphics_may_differ_from_the_original_download')}
      </p>
    </div>
  )
}
