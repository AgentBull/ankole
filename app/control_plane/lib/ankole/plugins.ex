defmodule Ankole.Plugins do
  @moduledoc """
  Public facade for Ankole's first-party Elixir plugin registry.

  Ankole plugins are not a marketplace of installable extensions. They are
  first-party Elixir modules compiled into the release that contribute things
  like signal adapters, identity providers, AppConfigure keys, and supervised
  children. The lifecycle has two stages with deliberately different meanings:

    - **discovered**: every plugin module found and validated at boot. This is
      the full catalog the operator can see.
    - **active**: the discovered plugins that are *not* in the global disable
      list. Only active plugins register config and start children.

  Because plugins are installation-global and default-on, the operator opts
  plugins *out* via a single global disable list (`put_disabled_ids/1`), rather
  than opting each one in. That list is read once at registry startup, so a
  change takes effect on the next Ankole process start (see `Plugins.Config`).
  """

  alias Ankole.Plugins.Config
  alias Ankole.Plugins.Registry

  defdelegate disabled_ids_definition(), to: Config
  defdelegate disabled_ids(), to: Config
  defdelegate put_disabled_ids(disabled_ids), to: Config
  defdelegate list_discovered(), to: Registry
  defdelegate list_active(), to: Registry
  defdelegate get(id), to: Registry
  defdelegate active?(id), to: Registry
  defdelegate adapter_declarations(contract_id), to: Registry
end
