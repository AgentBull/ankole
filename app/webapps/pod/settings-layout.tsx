import { Card, CardContent, Tabs, TabsContent, TabsList, TabsTrigger, cn, useIsMobile } from '@ankole/uikit'
import type { ReactNode } from 'react'

type SettingsNavigationItem = {
  value: string
  label: string
  icon?: ReactNode
}

export function SettingsLayout({
  title,
  description,
  value,
  onValueChange,
  navigationLabel,
  items,
  navigationExtras,
  children
}: {
  title: string
  description: string
  value: string
  onValueChange(value: string): void
  navigationLabel: string
  items: readonly SettingsNavigationItem[]
  navigationExtras?: ReactNode
  children: ReactNode
}) {
  const isMobile = useIsMobile()
  return (
    <div className="h-full overflow-y-auto">
      <Tabs
        orientation={isMobile ? 'horizontal' : 'vertical'}
        value={value}
        onValueChange={onValueChange}
        className="mx-auto grid w-full max-w-6xl grid-cols-1 content-start gap-6 px-4 py-7 sm:px-6 md:grid-cols-[13rem_minmax(0,1fr)] md:gap-x-10 md:px-8 md:py-10 lg:gap-x-14 lg:px-10">
        <header className="grid gap-1.5 md:col-span-2">
          <h1 className="text-2xl font-semibold tracking-[-0.02em] text-foreground">{title}</h1>
          <p className="max-w-2xl text-sm leading-6 text-muted-foreground">{description}</p>
        </header>
        <TabsList
          variant="object"
          aria-label={navigationLabel}
          className="w-full min-w-0 justify-start gap-1 overflow-x-auto border-b border-border pb-3 group-data-horizontal/tabs:h-auto md:w-auto md:border-0 md:pb-0">
          {items.map(item => (
            <TabsTrigger
              key={item.value}
              value={item.value}
              className="min-h-9 shrink-0 justify-start gap-2.5 rounded-lg px-3 py-2 text-sm md:h-9 md:py-1.5">
              {item.icon}
              <span>{item.label}</span>
            </TabsTrigger>
          ))}
          {navigationExtras}
        </TabsList>
        <div className="grid min-w-0 content-start gap-6 pb-10">{children}</div>
      </Tabs>
    </div>
  )
}

export function SettingsPanel({ value, children }: { value: string; children: ReactNode }) {
  return (
    <TabsContent value={value} className="grid content-start gap-7 outline-none">
      {children}
    </TabsContent>
  )
}

function SettingsSectionHeader({
  title,
  description,
  action
}: {
  title: string
  description?: string
  action?: ReactNode
}) {
  return (
    <div className="flex flex-wrap items-end justify-between gap-x-4 gap-y-3">
      <div className="grid min-w-0 gap-1">
        <h2 className="text-base font-semibold tracking-[-0.01em] text-foreground">{title}</h2>
        {description && <p className="max-w-2xl text-sm leading-5 text-muted-foreground">{description}</p>}
      </div>
      {action}
    </div>
  )
}

export function SettingsSection({
  title,
  description,
  action,
  children,
  className
}: {
  title: string
  description?: string
  action?: ReactNode
  children: ReactNode
  className?: string
}) {
  return (
    <section className="grid content-start gap-3">
      <SettingsSectionHeader title={title} description={description} action={action} />
      <Card size="sm" className={cn('gap-0 rounded-xl bg-card py-0 shadow-none', className)}>
        <CardContent className="px-5 py-5 sm:px-6 sm:py-6">{children}</CardContent>
      </Card>
    </section>
  )
}
