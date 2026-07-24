import { Tabs, TabsContent, TabsList, TabsTrigger } from '@ankole/uikit/components/tabs'
import { RiArrowRightLine, RiCheckLine, RiFileCopyLine } from '@remixicon/react'
import { motion, useReducedMotion } from 'motion/react'
import { useState } from 'react'

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
  const [copied, setCopied] = useState(false)

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(text)
    } catch {
      // Clipboard API can be unavailable on non-secure origins; fall back to a hidden textarea.
      const textarea = document.createElement('textarea')
      textarea.value = text
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
      aria-label={label}
      className="inline-flex h-7 cursor-pointer items-center gap-1.5 border border-gray-70 px-2 font-mono text-xs text-gray-30 transition-colors duration-150 ease-[var(--ease-productive)] hover:bg-gray-80 hover:text-white">
      {copied ? <RiCheckLine className="size-3.5" /> : <RiFileCopyLine className="size-3.5" />}
      {copied ? copiedLabel : label}
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
    <div className="border border-gray-90 bg-gray-100 dark:border-gray-80">
      <div className="flex items-center justify-between border-b border-gray-90 px-3 py-2 dark:border-gray-80">
        <span className="font-mono text-[11px] tracking-[0.14em] text-gray-50 uppercase">bash</span>
        <CopyButton text={code} label={copyLabel} copiedLabel={copiedLabel} />
      </div>
      <pre className="overflow-x-auto p-4 font-mono text-sm leading-6 text-gray-20">
        <code>
          {lines.map((line, index) => {
            const comment = line.startsWith('#')
            return (
              <span key={`${index}-${line}`} className="grid grid-cols-[1.25rem_1fr]">
                <span aria-hidden="true" className={comment ? 'text-gray-60' : 'text-brand-40'}>
                  {comment ? '#' : '$'}
                </span>
                <span className={comment ? 'text-gray-50' : undefined}>
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
  installHref: string
}

export default function QuickStartTabs({ labels, installHref }: QuickStartTabsProps) {
  const reduced = useReducedMotion()

  return (
    <motion.div
      data-reveal
      initial={reduced ? false : { opacity: 0, y: 16 }}
      whileInView={{ opacity: 1, y: 0 }}
      viewport={{ once: true, amount: 0.2 }}
      transition={{ duration: 0.5, ease: [0, 0, 0.3, 1], delay: 0.1 }}>
      <Tabs defaultValue="source">
        {/* The three labels exceed a phone width, so let the list scroll instead of the page. */}
        <TabsList className="max-w-full overflow-x-auto">
          <TabsTrigger value="source">{labels.source}</TabsTrigger>
          <TabsTrigger value="docker">{labels.docker}</TabsTrigger>
          <TabsTrigger value="kubernetes">{labels.kubernetes}</TabsTrigger>
        </TabsList>
        <TabsContent value="source" className="pt-4">
          <p className="mb-4 text-sm text-muted-foreground">{labels.sourceNote}</p>
          <CodeBlock code={SOURCE_COMMANDS} copyLabel={labels.copy} copiedLabel={labels.copied} />
        </TabsContent>
        <TabsContent value="docker" className="pt-4">
          <p className="mb-4 text-sm text-muted-foreground">{labels.dockerNote}</p>
          <CodeBlock code={DOCKER_COMMANDS} copyLabel={labels.copy} copiedLabel={labels.copied} />
        </TabsContent>
        <TabsContent value="kubernetes" className="pt-4">
          <p className="text-sm text-muted-foreground">{labels.k8sBody}</p>
          <a
            href={installHref}
            className="mt-4 inline-flex items-center gap-1.5 text-sm font-medium text-primary no-underline hover:underline dark:text-brand-40">
            {labels.k8sLink}
            <RiArrowRightLine className="size-4" />
          </a>
        </TabsContent>
      </Tabs>
    </motion.div>
  )
}
