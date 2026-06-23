defmodule Ankole.Plugins do
  @moduledoc """
  Public facade for Ankole's first-party Elixir plugin registry.
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
