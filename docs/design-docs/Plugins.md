# Plugins

Ankole plugins are first-party trusted Elixir extension packages available at
boot. They may contribute metadata, AppConfigure declarations, setup metadata,
adapter callback modules, and supervised children.

Plugins are not a third-party isolation runtime or marketplace boundary in this
design.
The runtime does not load arbitrary plugin code from disk dynamically.

The plugin subsystem lives under `Ankole.Plugins.*`. This document defines the
shared plugin boundary; concrete subsystem extension contracts are added by
their owning subsystem documents when those contracts exist.

## Discovery And Registry

Plugin discovery is a bootstrap and local-code concern. The application must
know what plugin modules or packages are available before those plugins can
register runtime configuration, supervised children, setup metadata, or adapter
contracts.

Discovery reads local plugin roots from the repository:

- `plugins/` for normal first-party plugins;
- `internals/plugins/` for private first-party plugins when that tree exists.

`internals/plugins/` is a future optional root. A missing optional root is not a
startup error. A plugin declaration loaded from either root follows the same
contract once discovered.

Discovery must not depend on AppConfigure. AppConfigure starts after Repo and is
the runtime settings store; it is not how the process finds local plugin code.

Plugin ids must be unique across all discovery roots. A duplicate id is a
startup configuration error, not an ordering rule where one root silently wins.

The registry should store discovered specs and the active plugin set. A
normalized plugin spec includes:

- stable plugin id;
- plugin API version;
- display metadata;
- AppConfigure exact definitions;
- AppConfigure pattern definitions;
- setup metadata;
- adapter declarations, when a subsystem defines such a contract;
- supervised children, when the plugin owns Elixir runtime processes.

The registry is metadata and startup coordination. It is not a durable settings
store.

## Activation

All discovered plugins are active by default. An operator may disable plugins
through the core AppConfigure key `plugins.disabled_ids`, a plaintext global
list of plugin ids.

The disabled list is an activation policy, not a discovery source. On startup,
the plugin subsystem discovers local plugin code, reads the global disabled
list, and activates every discovered plugin whose id is not listed.

Changing `plugins.disabled_ids` while Ankole is running records the next-start
policy only. It does not hot-start or hot-stop plugin code. Setup and console
surfaces that edit the list must show that a restart is required before the
change affects active plugins.

A disabled plugin remains discoverable as local code, but its contributed
AppConfigure definitions, setup metadata, adapter declarations, and supervised
children are not active in the current process. Existing plugin-owned
AppConfigure rows may remain in PostgreSQL; disabling a plugin stops using those
rows, it does not delete them.

## Plugin Declaration

A plugin declaration should expose a stable id and API version. Optional display
name and description values may be plain strings or locale-keyed maps so setup
and console surfaces can render plugin-owned text without hard-coded host copy.

Plugin ids identify Ankole plugin packages. They are not external platform
namespaces, bot app ids, chat channel ids, provider instance ids, or agent ids.
Subsystem contracts that need those identifiers must define separate fields and
persistence rules.

Plugin declarations may contribute AppConfigure definitions and patterns. They
may also expose setup field descriptors for operator-facing forms. The form
metadata is UI description only; persistence still goes through the owning
AppConfigure key.

If a plugin contributes supervised children, the declaration must make the child
specs explicit. Supervision belongs to the host application tree, not to an
untracked plugin-side process manager.

## AppConfigure Integration

Plugin settings use the same `Ankole.AppConfigure` mechanism as core settings.
There is no plugin-specific config database, no plugin-specific secret store,
and no environment-variable fallback in AppConfigure resolution.

Plugin-owned AppConfigure values are global installation settings. Plugin
setup, credentials, provider catalogs, and adapter defaults are written in the
`global` scope and read without an agent resolution context.

Each plugin-owned AppConfigure definition declares the same contract as any
other runtime setting:

- stable key or registered key pattern;
- JSON-compatible schema;
- encryption policy;
- optional code default;
- optional generated value behavior;
- optional description for setup and console surfaces.

Exact definitions are used for known keys. Pattern definitions are used for
runtime-computed keys such as provider or channel instances. Exact definitions
take precedence over patterns, and ambiguous pattern matches must be rejected so
validation and encryption policy never depend on load order.

Plugin declarations must not create agent-scoped plugin settings. If a consuming
subsystem needs per-agent behavior that references a plugin capability, such as
an agent channel binding or model preference, that setting belongs to the
subsystem's own AppConfigure key or durable row. It may use AppConfigure agent
scope only when the subsystem's design allows it, but it is not plugin
enablement or plugin-owned setup.

Secret values are declared as encrypted AppConfigure values. Plugins must not
implement their own at-rest encryption for AppConfigure rows. Key derivation,
sealing, and opening go through the kernel boundary used by AppConfigure.

Generated secrets or generated defaults are not silently persisted by reads.
The owning setup or write path must explicitly accept and store the generated
value.

## Setup Metadata

Setup and console surfaces may render plugin-owned fields from plugin metadata.
Field paths are persistence contracts inside the plugin-owned config object, not
temporary form names. Renaming a field path changes existing stored config
unless the plugin keeps a compatibility reader for the old shape.

Fields that contain secrets must be marked as secrets. Host surfaces show secret
presence or redacted values, not plaintext. Empty secret submissions mean "keep
the existing value"; deleting the owning AppConfigure row is the explicit erase
operation.

Interactive setup flows may run server-side through trusted plugin callbacks,
for example to produce an OAuth link or provider QR code. Returning intermediate
values from such a flow does not persist anything by itself. The operator-facing
write path still validates and stores the final value through AppConfigure.

## Elixir Runtime Boundary

Plugins are Elixir-side extension modules or OTP applications. A plugin adapter
implements behaviours or callback modules defined by the subsystem that consumes
that adapter mode.

The host subsystem owns durable state, AppConfigure registration, setup and
console writes, supervision placement, authorization, and database-backed runtime
projections. Plugin callbacks receive only the context and host APIs that the
subsystem contract exposes.

Plugin code must not read bootstrap environment variables to simulate
AppConfigure resolution. Host-owned operations go through the owning subsystem's
Elixir API instead of becoming ad hoc plugin-side database writes.

## Adding Subsystem Contracts

Concrete adapter contracts belong to the subsystem that consumes them. When a
subsystem adds an adapter contract, that contract should define:

- the stable contract id or callback module;
- the plugin declaration shape;
- the Elixir behaviour, callback module, or host API exposed to plugin code;
- what durable rows, events, or outbox records the host owns;
- which global AppConfigure definitions or patterns the plugin may register;
- how setup and console surfaces write those settings;
- whether any per-agent setting may reference the plugin, and which subsystem
  owns that setting;
- how runtime projections reload after AppConfigure writes;
- what behavior is intentionally not guaranteed.

This document does not list current concrete adapter contracts. They should be
added only when the owning subsystem has an implementation or a settled design.

## Invariants

- Plugin code is trusted and available as local code at boot.
- Plugin code discovery is bootstrap/local-code state, not AppConfigure state.
- Plugin discovery reads `plugins/` and optional `internals/plugins/`.
- Plugin ids are unique across all discovery roots.
- All discovered plugins are active unless listed in global
  `plugins.disabled_ids`.
- Plugin activation changes require process restart.
- Plugin settings use global `Ankole.AppConfigure` rows.
- AppConfigure keys must be declared or accepted by one registered pattern
  before persistence.
- Plugin-owned secrets use AppConfigure encryption and kernel crypto.
- Plugins do not own agent-scoped settings. Per-agent behavior that references a
  plugin belongs to the consuming subsystem.
- Host-owned operations go through the owning subsystem's Elixir API.
- Concrete adapter contracts are not documented as current until their owning
  subsystem defines them.
