/// <reference types="vite/types/importMeta.d.ts" />
import { getDocument, GlobalWorkerOptions, PDFWorker } from 'pdfjs-dist/legacy/build/pdf.mjs'
// eslint-disable-next-line import/default -- `?url` makes Vite export the asset URL, which the module itself does not
import workerURL from 'pdfjs-dist/legacy/build/pdf.worker.min.mjs?url'

GlobalWorkerOptions.workerSrc = workerURL

// pdf.js names the predefined CMap, symbol font, or image decoder a document needs; Vite emits each as its own asset.
// The other standard fonts come from the system, so pdf.js asks only for Symbol and ZapfDingbats.
const binaryURLs = new Map(
  Object.entries(
    import.meta.glob<string>(
      [
        '/node_modules/pdfjs-dist/cmaps/*.bcmap',
        '/node_modules/pdfjs-dist/standard_fonts/Foxit{Symbol,Dingbats}.pfb',
        '/node_modules/pdfjs-dist/wasm/{jbig2,openjpeg}.wasm'
      ],
      { query: '?url&no-inline', import: 'default', eager: true }
    )
  ).map(([path, url]) => [path.slice(path.lastIndexOf('/') + 1), url])
)

class BundledBinaryData {
  async fetch({ filename }: { filename: string }) {
    const url = binaryURLs.get(filename)
    if (!url) throw new Error(`pdf.js asked for a file that Ankole does not bundle: ${filename}`)
    const response = await fetch(url)
    if (!response.ok) throw new Error(`Could not load ${filename}`)
    return new Uint8Array(await response.arrayBuffer())
  }
}

let sharedWorker: PDFWorker | undefined

/** Opens a PDF with pdf.js. Thumbnails and the viewer share one worker. */
export function openPdf(source: { url: string; disableAutoFetch?: boolean; disableStream?: boolean }) {
  sharedWorker ??= new PDFWorker()
  return getDocument({ ...source, worker: sharedWorker, BinaryDataFactory: BundledBinaryData })
}
