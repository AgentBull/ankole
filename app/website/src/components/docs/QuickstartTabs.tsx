import { Alert, AlertDescription, AlertTitle } from '@ankole/uikit/components/alert'
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from '@ankole/uikit/components/collapsible'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@ankole/uikit/components/tabs'
import { RiArrowDownSLine, RiArrowRightLine, RiCheckLine, RiErrorWarningLine, RiFileCopyLine } from '@remixicon/react'
import { useEffect, useState } from 'react'

export interface QuickstartCode {
  code: string
  language?: string
}

export interface QuickstartBatchImport {
  content: string
  label: string
}

export interface QuickstartCopyItem {
  description?: string
  value: string
}

export interface QuickstartField {
  description: string
  name: string
  value?: string
}

export interface QuickstartLink {
  href: string
  label: string
}

export interface QuickstartStep {
  batchImport?: QuickstartBatchImport
  body?: string[]
  bullets?: string[]
  caution?: string
  code?: QuickstartCode[]
  copyItems?: QuickstartCopyItem[]
  fields?: QuickstartField[]
  links?: QuickstartLink[]
  title: string
}

export interface QuickstartSection {
  intro?: string
  steps: QuickstartStep[]
  summary?: string
  title: string
}

export interface QuickstartAlert {
  body: string[]
  title: string
}

export interface QuickstartTab {
  advanced?: QuickstartSection
  alert?: QuickstartAlert
  badge?: string
  basic: QuickstartSection
  label: string
  prerequisites?: string[]
  summary: string
  value: string
}

export interface QuickstartLabels {
  advancedSettings: string
  basicSettings: string
  copied: string
  copy: string
  hideAdvanced: string
  prerequisites: string
  showAdvanced: string
}

interface QuickstartTabsProps {
  ariaLabel: string
  defaultValue: string
  labels: QuickstartLabels
  queryParam?: string
  tabs: QuickstartTab[]
}

interface QuickstartDisclosureProps {
  labels: QuickstartLabels
  section: QuickstartSection
}

interface QuickstartAgentPromptProps {
  labels: QuickstartLabels
  prompt: string
}

export function QuickstartAgentPrompt({ labels, prompt }: QuickstartAgentPromptProps) {
  return (
    <div className="not-prose my-6 w-full min-w-0 max-w-4xl border-y border-border/80">
      <div className="grid gap-4 py-5 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-start">
        <blockquote className="m-0 border-0 p-0">
          <p className="m-0 max-w-3xl text-sm leading-6 text-foreground">{prompt}</p>
        </blockquote>
        <CopyButton labels={labels} value={prompt} />
      </div>
    </div>
  )
}

export function QuickstartTabs({ ariaLabel, defaultValue, labels, queryParam, tabs }: QuickstartTabsProps) {
  const [value, setValue] = useState(defaultValue)

  useEffect(() => {
    if (!queryParam) return

    const requestedValue = new URLSearchParams(window.location.search).get(queryParam)
    if (requestedValue && tabs.some(tab => tab.value === requestedValue)) setValue(requestedValue)
  }, [queryParam, tabs])

  function changeTab(nextValue: string) {
    setValue(nextValue)
    if (!queryParam) return

    const url = new URL(window.location.href)
    url.searchParams.set(queryParam, nextValue)
    window.history.replaceState(window.history.state, '', `${url.pathname}${url.search}${url.hash}`)
  }

  return (
    <div className="not-prose my-10 w-full min-w-0 max-w-4xl border-y border-border/80">
      <Tabs value={value} onValueChange={changeTab} className="w-full min-w-0 gap-0">
        <TabsList
          aria-label={ariaLabel}
          className="no-scrollbar w-full min-w-0 max-w-full justify-start gap-6 overflow-x-auto group-data-horizontal/tabs:h-auto sm:gap-8">
          {tabs.map(tab => (
            <TabsTrigger
              key={tab.value}
              value={tab.value}
              className="h-auto flex-none gap-1.5 px-0 py-4 text-[13px] after:bg-foreground group-data-horizontal/tabs:after:h-px">
              <span>{tab.label}</span>
              {tab.badge ? (
                <span className="font-mono text-[9px] tracking-[0.06em] text-muted-foreground">· {tab.badge}</span>
              ) : null}
            </TabsTrigger>
          ))}
        </TabsList>

        {tabs.map(tab => (
          <TabsContent key={tab.value} value={tab.value} className="w-full min-w-0 pt-0 text-foreground">
            <div className="py-7">
              <p className="m-0 max-w-3xl text-[15px] leading-7 text-foreground">{tab.summary}</p>
              {tab.alert ? (
                <Alert variant="warning" className="mt-6 max-w-3xl">
                  <RiErrorWarningLine aria-hidden="true" />
                  <AlertTitle>{tab.alert.title}</AlertTitle>
                  <AlertDescription>
                    {tab.alert.body.map(paragraph => (
                      <p key={paragraph}>{paragraph}</p>
                    ))}
                  </AlertDescription>
                </Alert>
              ) : null}
              {tab.prerequisites?.length ? (
                <div className="mt-6 grid gap-3 border-t border-border/70 pt-4 sm:grid-cols-[6rem_minmax(0,1fr)] sm:gap-5">
                  <p className="m-0 font-mono text-[10px] tracking-[0.08em] text-muted-foreground uppercase">
                    {labels.prerequisites}
                  </p>
                  <ul className="m-0 grid list-none gap-x-6 gap-y-2 p-0 md:grid-cols-[repeat(auto-fit,minmax(9rem,1fr))]">
                    {tab.prerequisites.map((item, index) => (
                      <li
                        key={item}
                        className="grid grid-cols-[1.5rem_minmax(0,1fr)] gap-1 text-[13px] leading-5 text-muted-foreground">
                        <span aria-hidden="true" className="font-mono text-[9px] leading-5 text-muted-foreground/70">
                          {String(index + 1).padStart(2, '0')}
                        </span>
                        <span>{item}</span>
                      </li>
                    ))}
                  </ul>
                </div>
              ) : null}
            </div>

            <div className="border-t border-border/80 py-7">
              <p className="m-0 font-mono text-[10px] tracking-[0.08em] text-muted-foreground uppercase">
                {labels.basicSettings}
              </p>
              <SectionContent section={tab.basic} labels={labels} showHeading />
            </div>

            {tab.advanced ? <AdvancedSection section={tab.advanced} labels={labels} /> : null}
          </TabsContent>
        ))}
      </Tabs>
    </div>
  )
}

export function QuickstartDisclosure({ labels, section }: QuickstartDisclosureProps) {
  return (
    <div className="not-prose my-8 max-w-4xl">
      <AdvancedSection section={section} labels={labels} standalone />
    </div>
  )
}

function AdvancedSection({
  labels,
  section,
  standalone = false
}: {
  labels: QuickstartLabels
  section: QuickstartSection
  standalone?: boolean
}) {
  const [open, setOpen] = useState(false)

  return (
    <Collapsible
      open={open}
      onOpenChange={nextOpen => setOpen(nextOpen)}
      className={standalone ? 'border-y border-border/80' : 'mt-2 border-t border-border/80'}>
      <CollapsibleTrigger className="group flex w-full cursor-pointer items-start justify-between gap-5 py-4 text-left outline-none focus-visible:ring-2 focus-visible:ring-ring/50 focus-visible:ring-offset-2 focus-visible:ring-offset-background">
        <span className="min-w-0 flex-1 sm:grid sm:grid-cols-[6rem_minmax(0,1fr)] sm:gap-5">
          <span className="block font-mono text-[10px] tracking-[0.08em] text-muted-foreground uppercase">
            {labels.advancedSettings}
          </span>
          <span className="mt-1 block sm:mt-0">
            <span className="block text-sm leading-5 font-medium text-foreground">{section.title}</span>
            {section.summary ? (
              <span className="mt-1 block max-w-2xl text-[13px] leading-5 font-normal text-muted-foreground">
                {section.summary}
              </span>
            ) : null}
          </span>
        </span>
        <span className="mt-0.5 inline-flex shrink-0 items-center gap-1.5 font-mono text-[10px] font-normal text-muted-foreground">
          {open ? labels.hideAdvanced : labels.showAdvanced}
          <RiArrowDownSLine
            aria-hidden="true"
            className={`size-4 transition-transform motion-reduce:transition-none ${open ? 'rotate-180' : ''}`}
          />
        </span>
      </CollapsibleTrigger>
      <CollapsibleContent className="border-t border-border/70 pb-2">
        <SectionContent section={section} labels={labels} />
      </CollapsibleContent>
    </Collapsible>
  )
}

function SectionContent({
  labels,
  section,
  showHeading = false
}: {
  labels: QuickstartLabels
  section: QuickstartSection
  showHeading?: boolean
}) {
  return (
    <>
      {showHeading ? (
        <div className="mt-2 max-w-3xl">
          <h3 className="m-0 text-base leading-6 font-medium text-foreground">{section.title}</h3>
          {section.intro ? (
            <p className="mt-2 mb-0 text-[13px] leading-5 text-muted-foreground">{section.intro}</p>
          ) : null}
        </div>
      ) : section.intro ? (
        <p className="mt-4 mb-0 max-w-3xl text-sm leading-6 text-muted-foreground">{section.intro}</p>
      ) : null}
      <ol className="m-0 mt-3 max-w-3xl list-none p-0">
        {section.steps.map((step, index) => (
          <li
            key={`${index}-${step.title}`}
            className="grid grid-cols-[1.75rem_minmax(0,1fr)] gap-3 border-b border-border/70 py-5 last:border-b-0 sm:grid-cols-[2rem_minmax(0,1fr)] sm:gap-4">
            <span className="pt-0.5 font-mono text-[10px] text-muted-foreground/70">
              {String(index + 1).padStart(2, '0')}
            </span>
            <div className="min-w-0">
              <h4 className="m-0 text-sm leading-6 font-medium text-foreground">{step.title}</h4>

              {step.body?.map(paragraph => (
                <p key={paragraph} className="mt-2 mb-0 max-w-3xl text-sm leading-6 text-muted-foreground">
                  {paragraph}
                </p>
              ))}

              {step.bullets?.length ? (
                <ul className="mt-3 list-none space-y-2 p-0">
                  {step.bullets.map(item => (
                    <li key={item} className="flex gap-3 text-sm leading-6 text-muted-foreground">
                      <span aria-hidden="true" className="mt-[0.7em] size-1 shrink-0 bg-muted-foreground/60" />
                      <span>{item}</span>
                    </li>
                  ))}
                </ul>
              ) : null}

              {step.batchImport ? <BatchImport block={step.batchImport} labels={labels} /> : null}

              {step.copyItems?.length ? <CopyItemList items={step.copyItems} labels={labels} /> : null}

              {step.fields?.length ? <FieldList fields={step.fields} /> : null}

              {step.code?.map(block => (
                <CodeBlock key={`${block.language ?? 'text'}-${block.code}`} block={block} labels={labels} />
              ))}

              {step.caution ? (
                <p className="mt-4 mb-0 border-l-2 border-amber-500/70 pl-4 text-sm leading-6 text-foreground">
                  {step.caution}
                </p>
              ) : null}

              {step.links?.length ? (
                <div className="mt-4 flex flex-wrap gap-x-5 gap-y-2">
                  {step.links.map(link => (
                    <a
                      key={link.href}
                      href={link.href}
                      target={isExternalLink(link.href) ? '_blank' : undefined}
                      rel={isExternalLink(link.href) ? 'noopener noreferrer' : undefined}
                      className="inline-flex items-center gap-1.5 text-sm font-medium text-primary underline-offset-4 hover:underline dark:text-brand-40">
                      {link.label}
                      <RiArrowRightLine aria-hidden="true" className="size-4" />
                    </a>
                  ))}
                </div>
              ) : null}
            </div>
          </li>
        ))}
      </ol>
    </>
  )
}

function BatchImport({ block, labels }: { block: QuickstartBatchImport; labels: QuickstartLabels }) {
  return (
    <div className="mt-4 border-y border-border/80">
      <div className="flex items-center justify-between gap-4 py-2.5">
        <span className="font-mono text-[10px] tracking-[0.08em] text-muted-foreground uppercase">{block.label}</span>
        <CopyButton itemLabel={block.label} labels={labels} value={block.content} />
      </div>
      <pre className="m-0 overflow-x-auto border-0 border-t border-border/70 bg-muted/20 px-4 py-3 text-xs leading-6 text-foreground">
        <code>{block.content}</code>
      </pre>
    </div>
  )
}

function CopyItemList({ items, labels }: { items: QuickstartCopyItem[]; labels: QuickstartLabels }) {
  return (
    <ul className="mt-4 list-none border-y border-border/80 p-0">
      {items.map(item => (
        <li
          key={item.value}
          className="grid grid-cols-[minmax(0,1fr)_auto] items-start gap-4 border-b border-border/70 py-3 last:border-b-0">
          <div className="min-w-0">
            <code className="break-all font-mono text-xs leading-5 text-foreground">{item.value}</code>
            {item.description ? (
              <p className="mt-1 mb-0 text-xs leading-5 text-muted-foreground">{item.description}</p>
            ) : null}
          </div>
          <CopyButton labels={labels} value={item.value} />
        </li>
      ))}
    </ul>
  )
}

function FieldList({ fields }: { fields: QuickstartField[] }) {
  return (
    <dl className="mt-4 grid gap-x-6 border-t border-border sm:grid-cols-2">
      {fields.map(field => (
        <div key={field.name} className="border-b border-border py-3">
          <dt className="font-mono text-xs text-foreground">{field.name}</dt>
          {field.value ? (
            <dd className="mt-1 font-mono text-xs text-primary dark:text-brand-40">{field.value}</dd>
          ) : null}
          <dd className="mt-1 text-sm leading-6 text-muted-foreground">{field.description}</dd>
        </div>
      ))}
    </dl>
  )
}

function CodeBlock({ block, labels }: { block: QuickstartCode; labels: QuickstartLabels }) {
  return (
    <div className="mt-4 border border-border bg-gray-100 dark:bg-gray-90">
      <div className="flex items-center justify-between border-b border-gray-80 px-3 py-2 dark:border-gray-80">
        <span className="font-mono text-[11px] tracking-[0.14em] text-gray-50 uppercase">
          {block.language ?? 'text'}
        </span>
        <CopyButton inverted itemLabel={block.language ?? 'text'} labels={labels} value={block.code} />
      </div>
      <pre className="m-0 overflow-x-auto border-0 bg-transparent p-4 text-sm leading-6 text-gray-20">
        <code>{block.code}</code>
      </pre>
    </div>
  )
}

function CopyButton({
  inverted = false,
  itemLabel,
  labels,
  value
}: {
  inverted?: boolean
  itemLabel?: string
  labels: QuickstartLabels
  value: string
}) {
  const [copied, setCopied] = useState(false)

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(value)
    } catch {
      const textarea = document.createElement('textarea')
      textarea.value = value
      textarea.style.position = 'fixed'
      textarea.style.opacity = '0'
      document.body.appendChild(textarea)
      textarea.select()
      document.execCommand('copy')
      document.body.removeChild(textarea)
    }
    setCopied(true)
    window.setTimeout(() => setCopied(false), 2000)
  }

  return (
    <button
      type="button"
      onClick={copy}
      aria-label={`${copied ? labels.copied : labels.copy}: ${itemLabel ?? value}`}
      className={`inline-flex h-7 w-fit shrink-0 cursor-pointer items-center gap-1.5 border px-2 font-mono text-[10px] transition-colors focus-visible:ring-2 focus-visible:outline-none ${
        inverted
          ? 'border-gray-70 text-gray-30 hover:bg-gray-80 hover:text-white focus-visible:ring-brand-40'
          : 'border-border text-muted-foreground hover:border-foreground/40 hover:text-foreground focus-visible:ring-ring/50'
      }`}>
      {copied ? (
        <RiCheckLine aria-hidden="true" className="size-3.5" />
      ) : (
        <RiFileCopyLine aria-hidden="true" className="size-3.5" />
      )}
      {copied ? labels.copied : labels.copy}
    </button>
  )
}

function isExternalLink(href: string) {
  return href.startsWith('https://') || href.startsWith('http://')
}
