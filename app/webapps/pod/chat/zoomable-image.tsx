import { Button, Dialog, DialogContent, DialogTitle } from '@ankole/uikit'
import { RiZoomInLine, RiZoomOutLine } from '@remixicon/react'
import { useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'

export function ZoomableImage({ src, alt = '' }: { src: string; alt?: string }) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  const trigger = useRef<HTMLButtonElement>(null)
  return (
    <>
      <button
        type="button"
        ref={trigger}
        className="pod-chat-image-trigger"
        aria-label={t('pod.chat_timeline.enlarge_image', { name: alt })}
        onClick={event => {
          event.preventDefault()
          event.stopPropagation()
          setOpen(true)
        }}>
        <img src={src} alt={alt} loading="lazy" referrerPolicy="no-referrer" />
      </button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent className="pod-chat-lightbox" closeLabel={t('common.close')} finalFocus={trigger}>
          <DialogTitle className="sr-only">{alt || t('pod.chat_timeline.image')}</DialogTitle>
          {open && <ImageZoomView src={src} alt={alt} />}
        </DialogContent>
      </Dialog>
    </>
  )
}

export function ImageZoomView({ src, alt, onError }: { src: string; alt: string; onError?: () => void }) {
  const { t } = useTranslation()
  const [zoom, setZoom] = useState(1)
  const drag = useRef<{ x: number; y: number; left: number; top: number } | undefined>(undefined)
  return (
    <div className="pod-chat-image-view">
      <div className="pod-chat-lightbox-tools" role="toolbar" aria-label={t('pod.chat_timeline.image_zoom')}>
        <Button
          variant="ghost"
          size="icon-sm"
          disabled={zoom === 1}
          aria-label={t('pod.chat_timeline.zoom_out')}
          onClick={() => setZoom(Math.max(1, zoom - 0.5))}>
          <RiZoomOutLine aria-hidden />
        </Button>
        <span>{Math.round(zoom * 100)}%</span>
        <Button
          variant="ghost"
          size="icon-sm"
          disabled={zoom === 3}
          aria-label={t('pod.chat_timeline.zoom_in')}
          onClick={() => setZoom(Math.min(3, zoom + 0.5))}>
          <RiZoomInLine aria-hidden />
        </Button>
      </div>
      <div
        className="pod-chat-lightbox-image"
        tabIndex={0}
        role="region"
        aria-label={alt}
        style={{ cursor: zoom > 1 ? 'grab' : undefined }}
        onKeyDown={event => {
          if (event.key === '+' || event.key === '=') setZoom(value => Math.min(3, value + 0.5))
          else if (event.key === '-') setZoom(value => Math.max(1, value - 0.5))
          else if (event.key === '0') setZoom(1)
          else return
          event.preventDefault()
        }}
        onDoubleClick={() => setZoom(value => (value === 1 ? 2 : 1))}
        onPointerDown={event => {
          if (event.button !== 0 || zoom === 1) return
          drag.current = {
            x: event.clientX,
            y: event.clientY,
            left: event.currentTarget.scrollLeft,
            top: event.currentTarget.scrollTop
          }
          event.currentTarget.setPointerCapture(event.pointerId)
          event.currentTarget.focus()
        }}
        onPointerMove={event => {
          if (!drag.current) return
          event.currentTarget.scrollLeft = drag.current.left + drag.current.x - event.clientX
          event.currentTarget.scrollTop = drag.current.top + drag.current.y - event.clientY
        }}
        onPointerUp={() => {
          drag.current = undefined
        }}
        onPointerCancel={() => {
          drag.current = undefined
        }}
        onLostPointerCapture={() => {
          drag.current = undefined
        }}>
        <img
          src={src}
          alt={alt}
          draggable={false}
          onError={onError}
          referrerPolicy="no-referrer"
          style={{ width: `${zoom * 100}%`, maxWidth: 'none' }}
        />
      </div>
    </div>
  )
}
