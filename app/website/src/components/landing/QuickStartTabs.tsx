import { useCopyFeedback } from '@ankole/uikit/hooks/use-copy-feedback'
import { copyText } from '../../lib/copy-text'
import { Tabs, TabsContent, TabsList, TabsTrigger } from '@ankole/uikit/components/tabs'
import { ArrowRightRegular, CheckmarkRegular, CopyRegular } from '@ankole/uikit/icons'

const SOURCE_COMMANDS = `git clone https://github.com/AgentBull/ankole.git
cd ankole
bash tools/devkit/scripts/env-setup.sh
# Open a new terminal, then return to the repository root.
bun install
bun run services:start
bun run services:status
bun run control-plane:setup
bun dev`

const DOCKER_COMMANDS = `git clone https://github.com/AgentBull/ankole.git
cd ankole/tools/deploy/docker-compose
cp .env.example .env
chmod 600 .env
# Fill the required values in .env, then:
docker compose pull
docker compose up -d`

interface CopyButtonProps {
  text: string
  label: string
  copiedLabel: string
}

function CopyButton({ text, label, copiedLabel }: CopyButtonProps) {
  const [copied, markCopied] = useCopyFeedback(false, 2000)
  const copy = async () => {
    await copyText(text)
    markCopied(true)
  }

  const currentLabel = copied ? copiedLabel : label

  return (
    <button
      type="button"
      onClick={copy}
      aria-label={currentLabel}
      className="inline-flex h-7 cursor-pointer items-center gap-1.5 border border-gray-90 px-2 font-mono text-xs text-gray-50 transition-colors duration-150 ease-[var(--ease-productive)] hover:bg-gray-90 hover:text-white">
      {copied ? (
        <CheckmarkRegular aria-hidden="true" className="size-3.5" />
      ) : (
        <CopyRegular aria-hidden="true" className="size-3.5" />
      )}
      <span aria-live="polite">{currentLabel}</span>
    </button>
  )
}

interface CodeBlockProps {
  code: string
  copyLabel: string
  copiedLabel: string
}

/** A shell line renders with a `$` gutter; a comment line renders muted with `#`. */
function CodeBlock({ code, copyLabel, copiedLabel }: CodeBlockProps) {
  const lines = code.split('\n')

  return (
    <div className="border border-gray-100 bg-gray-100 dark:border-gray-90">
      <div className="flex items-center justify-between border-b border-gray-100 px-3 py-2 dark:border-gray-90">
        <span className="font-mono text-[11px] tracking-[0.14em] text-gray-70 uppercase">bash</span>
        <CopyButton text={code} label={copyLabel} copiedLabel={copiedLabel} />
      </div>
      <pre className="overflow-x-auto p-4 font-mono text-sm leading-6 text-gray-40">
        <code>
          {lines.map((line, index) => {
            const comment = line.startsWith('#')
            return (
              <span key={`${index}-${line}`} className="grid grid-cols-[1.25rem_1fr]">
                <span aria-hidden="true" className={comment ? 'text-gray-80' : 'text-brand-40'}>
                  {comment ? '#' : '$'}
                </span>
                <span className={comment ? 'text-gray-70' : undefined}>
                  {comment ? line.replace(/^#\s?/, '') : line}
                </span>
              </span>
            )
          })}
        </code>
      </pre>
    </div>
  )
}

interface QuickStartTabsProps {
  ariaLabel?: string
  labels: {
    source: string
    docker: string
    kubernetes: string
    copy: string
    copied: string
    sourceNote: string
    dockerNote: string
    k8sBody: string
    k8sLink: string
  }
  deploymentHref: string
}

export default function QuickStartTabs({ ariaLabel = 'Quick start', labels, deploymentHref }: QuickStartTabsProps) {
  return (
    <div data-reveal="rise">
      <Tabs defaultValue="docker">
        {/*
         * The three labels exceed a phone width, so the list scrolls instead of the page.
         * It must also start rather than centre: a flex container that centres content
         * wider than itself spills past both edges, and the part that overflows to the
         * left cannot be scrolled back to — on a phone that clipped the first character
         * of the first tab for good.
         */}
        <TabsList aria-label={ariaLabel} className="max-w-full justify-start overflow-x-auto">
          <TabsTrigger value="docker">{labels.docker}</TabsTrigger>
          <TabsTrigger value="kubernetes">{labels.kubernetes}</TabsTrigger>
          <TabsTrigger value="source">{labels.source}</TabsTrigger>
        </TabsList>
        <TabsContent value="docker" className="pt-4">
          <p className="mb-4 text-sm text-muted-foreground">{labels.dockerNote}</p>
          <CodeBlock code={DOCKER_COMMANDS} copyLabel={labels.copy} copiedLabel={labels.copied} />
        </TabsContent>
        <TabsContent value="kubernetes" className="pt-4">
          <p className="text-sm text-muted-foreground">{labels.k8sBody}</p>
          <a
            href={deploymentHref}
            className="mt-4 inline-flex items-center gap-1.5 text-sm font-medium text-brand-60 no-underline hover:underline dark:text-brand-40">
            {labels.k8sLink}
            <ArrowRightRegular className="size-4" />
          </a>
        </TabsContent>
        <TabsContent value="source" className="pt-4">
          <p className="mb-4 text-sm text-muted-foreground">{labels.sourceNote}</p>
          <CodeBlock code={SOURCE_COMMANDS} copyLabel={labels.copy} copiedLabel={labels.copied} />
        </TabsContent>
      </Tabs>
    </div>
  )
}
