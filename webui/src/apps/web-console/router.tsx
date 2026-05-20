import { createRootRoute, createRoute, createRouter } from "@tanstack/react-router"
import { AppShell } from "./components/app-shell"
import { ChannelCreatePage } from "./routes/channels/create"
import { ChannelEditPage } from "./routes/channels/edit"
import { ChannelsListPage } from "./routes/channels/list"
import { OverviewPage } from "./routes/overview"
import { NotFound, SectionPlaceholder } from "./routes/placeholder"

const rootRoute = createRootRoute({
  component: AppShell,
  notFoundComponent: NotFound,
})

const overviewRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/",
  component: OverviewPage,
})

const channelsRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/channels",
  component: ChannelsListPage,
})

const channelNewRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/channels/new",
  component: ChannelCreatePage,
})

const channelEditRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/channels/$adapterId/$id/edit",
  component: ChannelEditPage,
})

const sectionRoute = createRoute({
  getParentRoute: () => rootRoute,
  path: "/$section",
  component: SectionPlaceholder,
})

const routeTree = rootRoute.addChildren([overviewRoute, channelsRoute, channelNewRoute, channelEditRoute, sectionRoute])

export const router = createRouter({
  routeTree,
  basepath: "/console",
  defaultPreload: "intent",
  scrollRestoration: true,
})

declare module "@tanstack/react-router" {
  interface Register {
    router: typeof router
  }
}
