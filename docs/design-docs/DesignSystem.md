# Design System

`@ankole/uikit` owns every visual decision in Ankole's web surfaces: the Pod, the Console, the authentication and setup apps, the website, and the Applets that Agents build. The kit organizes those decisions into layers so that each decision lives in one place and changes for one reason. A reader who wants to know where a value belongs asks one question: when this value changes, who has to change with it?

## Layers

Each layer answers one question and may reference only the layers below it. A layer never reaches up, and a component never skips the semantic layer to read the palette.

| Layer | Answers | Owner | May reference | Lives in |
| --- | --- | --- | --- | --- |
| L0 palette | Which colours, type sizes, radii, and durations exist | Brand and design leads | literal values | `@theme static` in `libs/uikit/src/theme.css` |
| L1 semantic tokens | What role a value plays on screen: body text, hover, a field's fill, danger | The design system | L0 | `:root` in `theme.css` |
| Theme | Which L0 value each L1 role takes in light mode, dark mode, or a tenant brand | The design system | L0 | `[data-theme='dark']` in `theme.css` |
| L2 component tokens | Where one component departs from the semantic layer | The component's author | L1 (L0 only inside a theme block) | `:root` in `theme.css`, prefixed by the component |
| Base components | Behaviour from ui-sdk (`@ui-sdk/react`) plus an appearance recipe from `cva` | `@ankole/uikit` | L1, L2 | `libs/uikit/src/components` |
| Patterns | Domain-free compositions such as Field, Empty, ReferenceCard, FileCard, StatCard, DataGrid, and BoardCard | `@ankole/uikit` | base components | `libs/uikit/src/components` |
| Business components | Screens and parts that know a domain concept: Principals, Agents, approvals, jobs, quotas, Pages | The domain's app code | everything above, with layout classes only | `app/webapps/pod`, `app/webapps/console`, `app/webapps/common` |

A theme remaps L1 and L2 roles to other L0 values and never introduces a new name. Charts follow the same split: `libs/uikit/src/viz/theme.ts` reads the `chart-*` tokens and owns the categorical ramps (`OPTION_RAMP_LIGHT`, `OPTION_RAMP_LIGHT_STROKE`) that the Brain graph and Agent-built charts colour by entity type.

## Semantic names

Every role has exactly one name. Names read as role, then tier, then state, and a text colour that pairs with a fill ends in `-fg`.

| Group | Tokens | Tailwind utilities |
| --- | --- | --- |
| Text and icons | `--fg-primary`, `--fg-secondary`, `--fg-tertiary`, `--fg-quaternary`, `--fg-placeholder`, `--fg-disabled`, `--fg-on-color`, `--icon-disabled` | `text-fg-primary`, … |
| Surfaces | `--ground` (the app frame), `--page`, `--layer-01`, `--layer-02`, `--layer-03`, `--layer-card`, `--overlay`, `--overlay-secondary`, `--overlay-tertiary`, `--overlay-inverse`, `--scrim`, `--scrim-secondary` | `bg-ground`, `bg-page`, `bg-layer-01`, … |
| Interaction | `--layer-hover`, `--layer-pressed`, `--layer-drag`, `--layer-current`, `--layer-current-edge`, `--layer-tertiary-hover`, `--layer-tertiary-pressed`, `--selection`, `--ring`, `--skeleton`, `--skeleton-base` | `bg-layer-hover`, `ring-ring`, … |
| Controls | `--field`, `--field-hover`, `--field-edge`, `--field-border`, `--field-border-hover` for a slot that holds input; `--control`, `--control-hover`, `--control-edge`, `--control-base` for a raised object | `bg-field`, `border-field-border`, `bg-control`, … |
| Borders and dividers | `--border-subtle`, `--border-strong`, `--border-overlay-strong`, `--border-quaternary`, `--divider`, `--divider-strong`, `--divider-brand`, `--divider-overlay`, `--divider-overlay-brand`, `--divider-overlay-strong` | `border-border-subtle`, `divide-divider`, … |
| Actions | `--primary`, `--primary-hover`, `--primary-active`, `--primary-edge`, `--primary-fg`, `--primary-disabled`, `--primary-disabled-fg`, `--inverse`, `--destructive-solid`, `--destructive-solid-hover` | `bg-primary`, `text-primary-fg`, `bg-inverse`, … |
| Status | `--{destructive,warning,success,info}` for the mark, `-fg` for text on paper, `-subtle` for the background behind a badge or callout | `text-destructive-fg`, `bg-warning-subtle`, … |

L2 tokens carry the prefix of the component that owns them: `sidebar-*`, `badge-*`, `ceramic-*`, `menu-*`, `slash-icon-*`, `composer-*`, `chart-*`, `fog-*`, `switch-*`, `table-*`, `board-*`, `search-mark-*`, `doc-*` (the caret and selection of the Word, spreadsheet, and presentation editors), and `syntax-*` (JSON and code tokens). The sidebar keeps `--sidebar` and `--sidebar-border` because the Pod desktop shell turns the sidebar fill transparent without touching the page. A component token exists only where the component departs from the semantic layer or needs its own dark value; a component that matches the semantic layer reads the L1 role directly.

## Rules

- **Components never name a palette step.** A palette step in a recipe cannot follow the dark theme or a tenant brand. When no L1 role fits, add the role to `theme.css` (as `destructive-solid` replaces `bg-red-80` in the destructive Button).
- **Sizes come from the ladders.** Type uses `text-25` through `text-800` (10, 12, 13, 14, 15, 16, 18, 20, 24, 30, 36, 48, 64 px) and figures use `text-num-*`; corners use `rounded-micro`, `rounded-mini`, `rounded-control`, `rounded-surface`, `rounded-panel`, and `rounded-full`; controls take the 24, 28, 32, and 36 px heights of the Button sizes. Layout dimensions of a business component, such as a panel width, stay with that component, and so do the initials and emoji that scale with the box holding them; a stylesheet marks such a size with a `/* glyph */` note.
- **One look, one owner.** When a business component repeats a look that another surface also needs, the look becomes a uikit variant or pattern rather than a second copy.
- **Business components style layout only.** They compose uikit and set flex, grid, gap, and size classes; colour, type, and radius come from the components and tokens they use.
- **Icons are Fluent System Icons.** Every icon comes from `@ankole/uikit/icons`, which re-exports `@fluentui/react-icons`; product code draws no icon of its own.

`libs/uikit/test/design-layers.test.ts` enforces the palette, legacy-name, colour-literal, and arbitrary-size rules across `libs/uikit/src/components` and `app/webapps`, and checks that the dark theme overrides only names that the light theme declares.

## Applet CSS contract

Applets are built by Agents without Tailwind and style their own layout through CSS variables, as the Pod CLI help instructs (`app/agent_computer/src/cli/pod/pod-cli-help.ts`). Saved Applets already read the names that predate the semantic layer (`--background`, `--foreground`, `--border`, `--muted-foreground`, `--card`, and others), so `theme.css` keeps those names, in both the plain and the `--color-*` spelling, as `var()` aliases of the canonical roles in a dedicated block. The aliases follow both themes automatically. Saved Applets also use the colour utilities that the kit offered under those names, such as `text-muted-foreground` and `bg-card`, and Tailwind emits a utility only when a scanned source uses it, so the same block bridges the legacy names and keeps their background, text, and border utilities, plain and on hover, through `@source inline()`. Product code and the kit never read the legacy names, which the guard test enforces. Agent-authored chart specifications read the same names through the lookup tables in `libs/uikit/src/viz/theme.ts`, which keep them for the same reason.

`ApprovalCard` and `PrincipalBadge` belong to the Applet component surface listed in the same help text, so they live in uikit rather than in Pod.

## Design sources

The palette, type ladder, and light and dark values mirror the Ankole-Base Styles library; each step in `theme.css` carries the library's name. The team's Paper file "Ankole Design System" draws the layers, the base components and patterns, the Pod and Console business components, and the SaaS, Pod, and Console screens with the same token names, so a designer and an engineer read one vocabulary.
