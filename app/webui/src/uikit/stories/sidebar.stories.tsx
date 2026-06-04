import { RiCalendarLine, RiHome2Line, RiInboxLine, RiSearchLine, RiSettings3Line } from '@remixicon/react'
import type { Meta, StoryObj } from '@storybook/react'

import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarInset,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarProvider,
  SidebarTrigger
} from '@/uikit/components/sidebar'

const ITEMS = [
  { title: 'Home', url: '#', icon: RiHome2Line },
  { title: 'Inbox', url: '#', icon: RiInboxLine },
  { title: 'Calendar', url: '#', icon: RiCalendarLine },
  { title: 'Search', url: '#', icon: RiSearchLine },
  { title: 'Settings', url: '#', icon: RiSettings3Line }
]

const meta = {
  title: 'Components/Sidebar',
  component: Sidebar,
  parameters: {
    layout: 'fullscreen'
  }
} satisfies Meta<typeof Sidebar>

export default meta

type Story = StoryObj<typeof meta>

export const Default: Story = {
  render: () => (
    <SidebarProvider>
      <Sidebar>
        <SidebarHeader>
          <div className="px-2 py-1.5 text-sm font-semibold tracking-widest uppercase">BullX</div>
        </SidebarHeader>
        <SidebarContent>
          <SidebarGroup>
            <SidebarGroupLabel>Application</SidebarGroupLabel>
            <SidebarGroupContent>
              <SidebarMenu>
                {ITEMS.map(item => (
                  <SidebarMenuItem key={item.title}>
                    <SidebarMenuButton render={<a href={item.url} />}>
                      <item.icon />
                      <span>{item.title}</span>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                ))}
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        </SidebarContent>
        <SidebarFooter>
          <div className="px-2 py-1 text-xs text-muted-foreground">v0.1.0</div>
        </SidebarFooter>
      </Sidebar>
      <SidebarInset>
        <header className="flex h-12 items-center gap-2 border-b px-4">
          <SidebarTrigger />
          <span className="text-sm font-semibold tracking-wider uppercase">Dashboard</span>
        </header>
        <main className="p-6 text-sm text-muted-foreground">Sidebar content goes here.</main>
      </SidebarInset>
    </SidebarProvider>
  )
}

export const Floating: Story = {
  render: () => (
    <SidebarProvider>
      <Sidebar variant="floating" collapsible="icon">
        <SidebarContent>
          <SidebarGroup>
            <SidebarGroupContent>
              <SidebarMenu>
                {ITEMS.map(item => (
                  <SidebarMenuItem key={item.title}>
                    <SidebarMenuButton tooltip={item.title} render={<a href={item.url} />}>
                      <item.icon />
                      <span>{item.title}</span>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                ))}
              </SidebarMenu>
            </SidebarGroupContent>
          </SidebarGroup>
        </SidebarContent>
      </Sidebar>
      <SidebarInset>
        <header className="flex h-12 items-center gap-2 border-b px-4">
          <SidebarTrigger />
        </header>
        <main className="p-6 text-sm text-muted-foreground">Floating sidebar variant.</main>
      </SidebarInset>
    </SidebarProvider>
  )
}
