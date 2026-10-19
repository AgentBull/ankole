import { t } from 'i18next'
import { Button } from '@ankole/uikit'
import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { getSlides, loadPresentation } from '@office-kit/pptx'
import { renderSlideToSvg } from '@office-kit/pptx-preview'
import { ContentError } from './content-primitives'

export default function PresentationPreview({ url }: { url: string }) {
  const [selected, setSelected] = useState(0)
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
  const selectedIndex = slides.data?.[selected] ? selected : 0
  const current = slides.data?.[selectedIndex]
  return (
    <div className="space-y-3">
      <ContentError error={slides.error} />
      {slides.isPending && <p role="status">{t('pod.content.reading_presentation')}</p>}
      <nav aria-label={t('pod.content.slides')} className="flex flex-wrap gap-1">
        {slides.data?.map((_slide, index) => (
          <Button
            key={index}
            size="sm"
            variant={index === selectedIndex ? 'outline' : 'ghost'}
            aria-pressed={index === selectedIndex}
            onClick={() => setSelected(index)}>
            {t('pod.content.page', { value1: index + 1 })}
          </Button>
        ))}
      </nav>
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
