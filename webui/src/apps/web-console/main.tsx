import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { RouterProvider } from "@tanstack/react-router"
import { createRoot } from "react-dom/client"
import { BullXI18nextProvider } from "@/i18n/provider"
import "./api/config"
import { router } from "./router"

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      retry: 1,
      refetchOnWindowFocus: false,
      staleTime: 30_000,
    },
  },
})

const container = document.getElementById("root")

if (container) {
  createRoot(container).render(
    <BullXI18nextProvider>
      <QueryClientProvider client={queryClient}>
        <RouterProvider router={router} />
      </QueryClientProvider>
    </BullXI18nextProvider>,
  )
}
