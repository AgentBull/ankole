import { createInertiaApp, type ResolvedComponent } from "@inertiajs/react"
import { createRoot } from "react-dom/client"
import { BullXI18nextProvider } from "./i18n/provider"

type WebpackContext = {
  (path: string): Promise<ResolvedComponent>
  keys(): string[]
}

type WebpackContextOptions = {
  recursive: boolean
  regExp: RegExp
  mode: "lazy" | "sync" | "eager" | "weak" | "lazy-once"
}

const inertiaElement = document.getElementById("app")
const inertiaPage = initialInertiaPage(inertiaElement)
const pages = (
  import.meta as unknown as {
    webpackContext: (request: string, options: WebpackContextOptions) => WebpackContext
  }
).webpackContext("./apps", {
  recursive: true,
  regExp: /\.tsx$/,
  mode: "lazy",
})

if (inertiaPage) {
  createInertiaApp({
    page: inertiaPage,
    http: { xsrfHeaderName: "x-csrf-token" },
    title: title => (title ? `${title} · BullX` : "BullX"),
    resolve: async name => {
      const path = `./${name}.tsx`

      if (!pages.keys().includes(path)) {
        throw new Error(`Unknown Inertia page: ${name}`)
      }

      return await pages(path)
    },
    setup({ App, el, props }) {
      createRoot(el).render(
        <BullXI18nextProvider>
          <App {...props} />
        </BullXI18nextProvider>,
      )
    },
  })
}

function initialInertiaPage(element: HTMLElement | null) {
  const json =
    document.querySelector<HTMLScriptElement>('script[data-page="app"][type="application/json"]')?.textContent ||
    element?.dataset.page

  return json ? JSON.parse(json) : null
}
