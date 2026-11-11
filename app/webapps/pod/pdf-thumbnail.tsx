import { useQuery } from '@tanstack/react-query'
import { useEffect, useRef, useState, type ReactNode } from 'react'

/** A thumbnail is drawn this wide, which covers a Grid card on a high-density screen. */
const THUMBNAIL_WIDTH = 640

/** Draws the first page of a PDF into an image. pdf.js loads on the first call. */
async function renderPdfThumbnail(url: string, signal: AbortSignal): Promise<Blob> {
  if (signal.aborted) throw signal.reason ?? new DOMException('Aborted', 'AbortError')
  const { openPdf } = await import('./pdfjs')
  if (signal.aborted) throw signal.reason ?? new DOMException('Aborted', 'AbortError')
  // A thumbnail needs only the first page, so pdf.js reads the byte ranges that page uses instead of the whole file.
  const task = openPdf({ url, disableAutoFetch: true, disableStream: true })
  const abort = () => void task.destroy()
  signal.addEventListener('abort', abort, { once: true })
  try {
    const page = await (await task.promise).getPage(1)
    const viewport = page.getViewport({ scale: THUMBNAIL_WIDTH / page.getViewport({ scale: 1 }).width })
    const canvas = document.createElement('canvas')
    canvas.width = Math.ceil(viewport.width)
    canvas.height = Math.ceil(viewport.height)
    await page.render({ canvas, viewport }).promise
    return await new Promise<Blob>((resolve, reject) =>
      canvas.toBlob(
        blob => (blob ? resolve(blob) : reject(new Error('The PDF page could not be encoded'))),
        'image/webp',
        0.8
      )
    )
  } finally {
    signal.removeEventListener('abort', abort)
    await task.destroy()
  }
}

/**
 * Shows the first page of a PDF in place of `fallback`, which stays while the page renders and when it cannot.
 * Rendering waits until the thumbnail scrolls near the viewport, so a long list reads only the files it shows.
 */
export function PdfThumbnail({ url, className, fallback }: { url: string; className?: string; fallback: ReactNode }) {
  const holder = useRef<HTMLSpanElement>(null)
  const [near, setNear] = useState(false)
  useEffect(() => {
    const observer = new IntersectionObserver(
      entries => {
        if (entries.some(entry => entry.isIntersecting)) setNear(true)
      },
      { rootMargin: '200px' }
    )
    observer.observe(holder.current!)
    return () => observer.disconnect()
  }, [])
  return (
    <span ref={holder} className={className}>
      {near ? <PdfFirstPage url={url} fallback={fallback} /> : fallback}
    </span>
  )
}

function PdfFirstPage({ url, fallback }: { url: string; fallback: ReactNode }) {
  const page = useQuery({
    queryKey: ['pdf-thumbnail', url],
    queryFn: ({ signal }) => renderPdfThumbnail(url, signal),
    retry: false,
    staleTime: Infinity,
    refetchOnWindowFocus: false,
    refetchOnReconnect: false
  })
  const [source, setSource] = useState<string>()
  useEffect(() => {
    if (!page.data) return
    const objectURL = URL.createObjectURL(page.data)
    setSource(objectURL)
    return () => {
      URL.revokeObjectURL(objectURL)
      setSource(undefined)
    }
  }, [page.data])
  return source ? <img src={source} alt="" className="size-full object-cover object-top" /> : fallback
}
