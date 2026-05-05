import type { Meta, StoryObj } from "@storybook/react"

const PALETTES = [
  "brand",
  "gray",
  "blue",
  "cyan",
  "teal",
  "green",
  "yellow",
  "red",
  "magenta",
  "purple",
  "orange",
] as const

const SHADES = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100] as const

const SEMANTIC_TOKENS = [
  "background",
  "foreground",
  "card",
  "card-foreground",
  "popover",
  "popover-foreground",
  "primary",
  "primary-foreground",
  "secondary",
  "secondary-foreground",
  "muted",
  "muted-foreground",
  "accent",
  "accent-foreground",
  "destructive",
  "destructive-foreground",
  "border",
  "input",
  "ring",
] as const

const STATE_TOKENS = ["error", "info", "success", "warning"] as const

const CARBON_TOKENS = [
  "interactive",
  "interactive-hover",
  "interactive-active",
  "layer-01",
  "layer-02",
  "layer-03",
  "field",
  "field-border",
  "border-subtle",
  "border-strong",
  "text-primary",
  "text-secondary",
  "text-placeholder",
] as const

const FOREGROUND_TOKENS = [
  "fg-primary",
  "fg-secondary",
  "fg-tertiary",
  "fg-quaternary",
  "fg-placeholder",
  "fg-disabled",
] as const

const BACKGROUND_TOKENS = [
  "background",
  "background-secondary",
  "background-tertiary",
  "background-quaternary",
] as const

const DIVIDER_TOKENS = ["divider", "divider-secondary", "divider-tertiary", "divider-quaternary"] as const

const CHART_TOKENS = ["chart-1", "chart-2", "chart-3", "chart-4", "chart-5", "chart-up", "chart-down"] as const

function Swatch({ name, cssVar, className }: { name: string; cssVar?: string; className?: string }) {
  return (
    <div className="flex flex-col gap-1.5">
      <div
        className={className ?? "h-16 w-full ring-1 ring-foreground/10"}
        style={cssVar ? { background: `var(${cssVar})` } : undefined}
      />
      <div className="flex flex-col">
        <span className="text-xs font-semibold tracking-widest uppercase">{name}</span>
        {cssVar && <span className="text-[10px] text-muted-foreground tabular-nums">{cssVar}</span>}
      </div>
    </div>
  )
}

function PaletteRow({ palette }: { palette: string }) {
  return (
    <div className="flex flex-col gap-2">
      <h3 className="text-sm font-semibold tracking-widest uppercase">{palette}</h3>
      <div className="grid grid-cols-10 gap-2">
        {SHADES.map(shade => (
          <Swatch key={`${palette}-${shade}`} name={String(shade)} cssVar={`--color-${palette}-${shade}`} />
        ))}
      </div>
    </div>
  )
}

function TokenGrid({ tokens, prefix = "--" }: { tokens: readonly string[]; prefix?: string }) {
  return (
    <div className="grid grid-cols-2 gap-4 md:grid-cols-3 lg:grid-cols-4">
      {tokens.map(token => (
        <Swatch key={token} name={token} cssVar={`${prefix}${token}`} />
      ))}
    </div>
  )
}

const meta = {
  title: "Foundations/Colors",
  parameters: {
    layout: "fullscreen",
    docs: {
      description: {
        component:
          "Color tokens used across the UI: Carbon-style raw palettes (10–100), semantic tokens (background, primary, etc.) and chart colors. Toggle the theme decorator to inspect light vs. dark.",
      },
    },
  },
} satisfies Meta

export default meta

type Story = StoryObj<typeof meta>

export const Palettes: Story = {
  render: () => (
    <div className="flex flex-col gap-10 p-6">
      {PALETTES.map(palette => (
        <PaletteRow key={palette} palette={palette} />
      ))}
      <div className="flex flex-col gap-2">
        <h3 className="text-sm font-semibold tracking-widest uppercase">black / white</h3>
        <div className="grid grid-cols-10 gap-2">
          <Swatch name="black" cssVar="--color-black" />
          <Swatch name="white" cssVar="--color-white" />
        </div>
      </div>
    </div>
  ),
}

export const Semantic: Story = {
  render: () => (
    <div className="flex flex-col gap-8 p-6">
      <section className="flex flex-col gap-3">
        <h2 className="text-base font-semibold tracking-widest uppercase">Semantic</h2>
        <TokenGrid tokens={SEMANTIC_TOKENS} />
      </section>
      <section className="flex flex-col gap-3">
        <h2 className="text-base font-semibold tracking-widest uppercase">State</h2>
        <TokenGrid tokens={STATE_TOKENS} />
      </section>
      <section className="flex flex-col gap-3">
        <h2 className="text-base font-semibold tracking-widest uppercase">Carbon</h2>
        <TokenGrid tokens={CARBON_TOKENS} />
      </section>
      <section className="flex flex-col gap-3">
        <h2 className="text-base font-semibold tracking-widest uppercase">Foreground</h2>
        <TokenGrid tokens={FOREGROUND_TOKENS} />
      </section>
      <section className="flex flex-col gap-3">
        <h2 className="text-base font-semibold tracking-widest uppercase">Background</h2>
        <TokenGrid tokens={BACKGROUND_TOKENS} />
      </section>
      <section className="flex flex-col gap-3">
        <h2 className="text-base font-semibold tracking-widest uppercase">Divider</h2>
        <TokenGrid tokens={DIVIDER_TOKENS} />
      </section>
      <section className="flex flex-col gap-3">
        <h2 className="text-base font-semibold tracking-widest uppercase">Chart</h2>
        <TokenGrid tokens={CHART_TOKENS} />
      </section>
    </div>
  ),
}
