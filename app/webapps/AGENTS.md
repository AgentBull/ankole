# Webapps Agent Guidelines

These guidelines apply to all files under `app/webapps/` and supplement the root `AGENTS.md`. They record principles and trade-offs only. A name appears here when it is the subject of a rule and changes only by a deliberate decision, such as a package or library that a rule requires or forbids. File paths, function and hook names, commands, and examples belong in the code and the design docs, because a detail copied here goes stale without anyone noticing.

## UX

Ankole's design language balances enterprise productivity systems (Carbon, SAP Fiori, Salesforce Lightning, Palantir Blueprint) against personal-experience systems (Notion, Fluent 2, shadcn/ui, Apple Liquid Glass), leaning slightly toward the personal side. From the enterprise side, an interface keeps tolerance for error, information density, throughput, explicit state, and accessibility. From the personal side, it keeps cognitive load low, keeps chrome quiet, and lets content lead. Interaction design draws on Linear and the Pleisto q prototype: fast paths, a keyboard route for every action, and calm navigation. The Pod sidebar follows the structure of a Notion sidebar so that users can rely on a familiar model. The visual language is Ankole's own, so do not copy the signature look of another product, and do not copy any pattern that alters Ankole's product semantics.

Build every screen with `@ankole/uikit` and its tokens, and do not add packages or components from another design system. Style with Tailwind CSS first: write utility classes on the element, and add a rule to a stylesheet only when a utility cannot express it, such as markup that another library renders. A style that several components share becomes a shared utility in `@ankole/uikit`, not a class repeated in app stylesheets. Each pattern has one owner: change a control in `@ankole/uikit`, or document typography in `@ankole/block-editor`, so that every surface follows, instead of restyling it on one page.

A value that names a record from another query never shows its raw ID while that query loads. Show a skeleton in its place, and make any choice that depends on the list wait for the list instead of offering an incomplete one.

## Browser support

Webapp bundles target Chrome 132, Firefox 160, and Safari 18. Use native browser features available at that floor, and detect newer capabilities before depending on them.

## State

Each piece of client state has one owner, chosen by where the value comes from and how it changes.

**Use TanStack Query for anything the server can answer.** Records, lists, pagination, and remote snapshots live in the query cache, which already deduplicates requests, tracks freshness, and invalidates after writes. A hand-written copy has to rebuild each of those and tends to drift from the server. For that reason, never copy query data into a Signal merely to observe it. A Signal model may hold an editable local draft seeded from query data, because the draft is a fact the server does not have yet. Seed it once per source so that a background refetch never overwrites an edit in progress.

**Use Preact Signals for values that exist only in the client.** Drafts, selections, view projections, and form fields are signals, and everything derived from them is a `computed`. Fine-grained tracking re-renders a component only for the values it reads, and a derived value cannot disagree with its source. Group reusable logic for a page, editor, or form into a `createModel` model so that components share one owner instead of passing state down through props. Reserve local React state for transient UI confined to a single component, and use effects only to synchronize with an external system, always cleaning up on unmount.

**Use XState v5 for a protocol whose correctness depends on its phase.** A machine pays off when a flow needs at least two of these: timers that must cancel with the phase, in-flight async work that an event must discard or serialize, independent parallel regions, an event whose meaning depends on the phase, or retry with backoff. In that case the machine makes legal transitions explicit and cancels work automatically when a phase ends, where hand-written code spreads timer handles, abort controllers, and boolean flags across handlers that each must remember to clean up. The price is a second mental model and event-shaped code, so a single debounce timer or a one-shot request stays with Signals or Query.

The two meet in one direction. A model sends events to its actor and reads the actor's snapshot back through a signal. A value that follows the machine's phase is a `computed` over that snapshot, because mirroring the phase into a second signal from a machine action stores the same fact twice. Ordinary values stay in Signals rather than in the machine's context, and data that the machine only consults is read through callbacks, so changing that data does not produce a new snapshot. Under `babel-plugin-react-compiler` + `useSignals()`, unwrap every signal `.value` into unconditional top-level `const` bindings at the start of the component before any conditional expression (`?:`, `&&`, `??`) or JSX so compiler memoization tracks the read values instead of omitting branches or comparing stable signal references.

## Chat interactions

Pod Chat renders interactive content through json-render. The catalog that a model can write against stays minimal: add a component only when a model-written block should be able to use it, regenerate the Skill reference that teaches Agents the catalog whenever it changes, and keep forms, durable actions, and data access out of it. Ankole's own durable cards build their interaction spec from what the control plane committed and leave the answer or approval with the control plane.

## Generated clients

Generated OpenAPI specs and clients are never edited by hand. To change an API contract, update the owning declaration in the control plane and regenerate the specs and clients through the workspace scripts.

## Dynamic SaaS modules and slots

A dynamic SaaS module contributes Console and Pod slots through its module declaration, which the build discovers and merges with any explicit root slots. A Console extension page uses the same routing, tenant context, list, editor, and form primitives and `@ankole/uikit` components as a built-in Console route, so that site-scoped and tenant-scoped pages behave alike, and it declares which scope each route belongs to.

Shared declarative containers in the host expose only small, orthogonal UI blocks and typed step transitions with no domain knowledge. Keep protocol flows, external input parsing, credential redaction, and dynamic step logic in control-plane actions rather than adding feature-specific modes to the host.
