defmodule BullX.Setup.Plugins do
  @moduledoc """
  Setup-step API for choosing enabled compile-time plugins.

  Enabling a plugin is persisted in BullX config, but the running registry only
  changes after restart. This module reports that difference explicitly so the
  setup UI can distinguish saved intent from currently active runtime plugins.
  """

  alias BullX.Config
  alias BullX.Config.Plugins, as: PluginsConfig
  alias BullX.Plugins
  alias BullX.Setup.ChannelSources

  @enabled_plugins_key "bullx.enabled_plugins"

  @spec status() :: map()
  def status do
    discovered = discovered_plugins()
    persisted_ids = persisted_enabled_ids()
    runtime_enabled_ids = runtime_enabled_ids()
    setup_extensions = ChannelSources.setup_extensions()

    %{
      complete?:
        Enum.sort(persisted_ids) == Enum.sort(runtime_enabled_ids) and setup_extensions != [],
      discovered: discovered,
      persisted_enabled_ids: persisted_ids,
      runtime_enabled_ids: runtime_enabled_ids,
      setup_capable_adapter_ids: Enum.map(setup_extensions, & &1.id),
      pending_restart?: Enum.sort(persisted_ids) != Enum.sort(runtime_enabled_ids),
      diff: %{
        persisted_only: Enum.sort(persisted_ids -- runtime_enabled_ids),
        runtime_only: Enum.sort(runtime_enabled_ids -- persisted_ids)
      }
    }
  end

  @spec save_enabled([String.t()]) :: :ok | {:error, map()}
  def save_enabled(ids) when is_list(ids) do
    ids =
      ids
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    known_ids = Enum.map(discovered_plugins(), & &1.id)
    unknown = Enum.sort(ids -- known_ids)

    case unknown do
      [] -> Config.put(@enabled_plugins_key, Jason.encode!(ids))
      [_ | _] -> {:error, %{field: "plugins", message: "unknown plugin ids", details: unknown}}
    end
  end

  def save_enabled(_ids), do: {:error, %{field: "plugins", message: "must be a list"}}

  defp discovered_plugins do
    Plugins.plugins()
    |> Enum.map(fn plugin ->
      %{
        id: plugin.id,
        app: Atom.to_string(plugin.app),
        module: inspect(plugin.module),
        enabled?: plugin.id in runtime_enabled_ids(),
        metadata: plugin.metadata
      }
    end)
  end

  defp persisted_enabled_ids do
    PluginsConfig.enabled_plugins!()
  rescue
    _error -> []
  end

  defp runtime_enabled_ids do
    Plugins.enabled_plugins()
    |> Enum.map(& &1.id)
  rescue
    _error -> []
  end
end
