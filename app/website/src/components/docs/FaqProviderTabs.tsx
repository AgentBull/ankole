import { Tabs, TabsContent, TabsList, TabsTrigger } from '@ankole/uikit/components/tabs'
import { RiArrowRightLine } from '@remixicon/react'

export interface FaqLink {
  href: string
  label: string
}

export interface FaqIssue {
  cause: string
  links?: FaqLink[]
  question: string
  resolution: string[]
  symptom: string
}

export interface FaqProviderTab {
  issues: FaqIssue[]
  label: string
  value: string
}

export interface FaqLabels {
  cause: string
  resolution: string
  symptom: string
}

interface FaqIssueListProps {
  issues: FaqIssue[]
  labels: FaqLabels
}

interface FaqProviderTabsProps {
  ariaLabel: string
  defaultValue: string
  labels: FaqLabels
  tabs: FaqProviderTab[]
}

export function FaqIssueList({ issues, labels }: FaqIssueListProps) {
  return (
    <div className="not-prose my-8 w-full min-w-0 max-w-4xl border-y border-border/80">
      <IssueList issues={issues} labels={labels} />
    </div>
  )
}

export function FaqProviderTabs({ ariaLabel, defaultValue, labels, tabs }: FaqProviderTabsProps) {
  return (
    <div className="not-prose my-8 w-full min-w-0 max-w-4xl border-y border-border/80">
      <Tabs defaultValue={defaultValue} className="w-full min-w-0 gap-0">
        <TabsList
          aria-label={ariaLabel}
          className="no-scrollbar w-full min-w-0 max-w-full justify-start gap-6 overflow-x-auto group-data-horizontal/tabs:h-auto sm:gap-8">
          {tabs.map(tab => (
            <TabsTrigger
              key={tab.value}
              value={tab.value}
              className="h-auto flex-none px-0 py-4 text-[13px] after:bg-foreground group-data-horizontal/tabs:after:h-px">
              {tab.label}
            </TabsTrigger>
          ))}
        </TabsList>

        {tabs.map(tab => (
          <TabsContent key={tab.value} value={tab.value} className="w-full min-w-0 pt-0 text-foreground">
            <IssueList issues={tab.issues} labels={labels} />
          </TabsContent>
        ))}
      </Tabs>
    </div>
  )
}

function IssueList({ issues, labels }: FaqIssueListProps) {
  return (
    <div className="divide-y divide-border/80">
      {issues.map((issue, index) => (
        <section key={issue.question} className="grid gap-4 py-7 md:grid-cols-[2.25rem_minmax(0,1fr)] md:gap-5">
          <p aria-hidden="true" className="m-0 font-mono text-[10px] leading-7 text-muted-foreground/70">
            {String(index + 1).padStart(2, '0')}
          </p>

          <div className="min-w-0">
            <h3 className="m-0 max-w-3xl text-lg leading-7 font-medium tracking-[-0.01em] text-foreground">
              {issue.question}
            </h3>

            <dl className="mt-5 grid gap-x-6 gap-y-4 sm:grid-cols-[5rem_minmax(0,1fr)]">
              <dt className="font-mono text-[10px] leading-6 tracking-[0.08em] text-muted-foreground uppercase">
                {labels.symptom}
              </dt>
              <dd className="m-0 max-w-3xl text-[14px] leading-6 text-muted-foreground">{issue.symptom}</dd>

              <dt className="font-mono text-[10px] leading-6 tracking-[0.08em] text-muted-foreground uppercase">
                {labels.cause}
              </dt>
              <dd className="m-0 max-w-3xl text-[14px] leading-6 text-muted-foreground">{issue.cause}</dd>

              <dt className="font-mono text-[10px] leading-6 tracking-[0.08em] text-muted-foreground uppercase">
                {labels.resolution}
              </dt>
              <dd className="m-0 max-w-3xl">
                <ol className="m-0 grid list-none gap-2 p-0">
                  {issue.resolution.map((step, stepIndex) => (
                    <li
                      key={step}
                      className="grid grid-cols-[1.5rem_minmax(0,1fr)] gap-2 text-[14px] leading-6 text-foreground">
                      <span aria-hidden="true" className="font-mono text-[9px] leading-6 text-muted-foreground/70">
                        {String(stepIndex + 1).padStart(2, '0')}
                      </span>
                      <span>{step}</span>
                    </li>
                  ))}
                </ol>
              </dd>
            </dl>

            {issue.links?.length ? (
              <div className="mt-5 flex flex-wrap gap-x-5 gap-y-2">
                {issue.links.map(link => (
                  <a
                    key={`${link.href}-${link.label}`}
                    href={link.href}
                    target={isExternalLink(link.href) ? '_blank' : undefined}
                    rel={isExternalLink(link.href) ? 'noopener noreferrer' : undefined}
                    className="inline-flex items-center gap-1 text-[13px] font-medium text-link underline decoration-link/35 underline-offset-4 hover:decoration-link">
                    {link.label}
                    <RiArrowRightLine aria-hidden="true" className="size-3.5" />
                  </a>
                ))}
              </div>
            ) : null}
          </div>
        </section>
      ))}
    </div>
  )
}

function isExternalLink(href: string) {
  return href.startsWith('https://') || href.startsWith('http://')
}
