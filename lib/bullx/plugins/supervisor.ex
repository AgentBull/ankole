defmodule BullX.Plugins.Supervisor do
  @moduledoc """
  Supervises the plugin registry and enabled plugin supervision trees.

  This supervisor starts only compiled, validated plugins. Enabling a plugin
  selects which declared children and extensions participate in runtime; it does
  not load new BEAM code from disk.
  """

  use Supervisor

  alias BullX.Plugins.{Discovery, PluginSupervisor, Registry}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    start_link_with_name(name, opts)
  end

  defp start_link_with_name(nil, opts), do: Supervisor.start_link(__MODULE__, opts)
  defp start_link_with_name(name, opts), do: Supervisor.start_link(__MODULE__, opts, name: name)

  @impl true
  def init(opts) do
    with {:ok, plugins} <- discover_plugins(opts),
         enabled_plugins <- enabled_plugins(opts),
         {:ok, registry_state} <- Registry.build(plugins, enabled_plugins) do
      children =
        [
          {Registry,
           plugins: plugins,
           enabled_plugins: enabled_plugins,
           name: Keyword.get(opts, :registry_name, Registry)}
          | plugin_supervisors(registry_state)
        ]

      Supervisor.init(children, strategy: :one_for_one)
    else
      {:error, reason} ->
        raise ArgumentError, "invalid BullX plugin configuration: #{inspect(reason)}"
    end
  end

  defp discover_plugins(opts) do
    case Keyword.fetch(opts, :plugins) do
      {:ok, plugins} -> {:ok, plugins}
      :error -> Discovery.discover()
    end
  end

  defp enabled_plugins(opts) do
    Keyword.get_lazy(opts, :enabled_plugins, &BullX.Config.Plugins.enabled_plugins!/0)
  end

  defp plugin_supervisors(%Registry{} = registry_state) do
    registry_state.plugins
    |> Enum.filter(&MapSet.member?(registry_state.enabled_ids, &1.id))
    |> Enum.map(&plugin_supervisor_child(&1, registry_state.enabled_ids))
  end

  defp plugin_supervisor_child(plugin, enabled_ids) do
    context = %{plugin: plugin, enabled_plugins: MapSet.to_list(enabled_ids)}

    Supervisor.child_spec(
      {PluginSupervisor, {plugin, context}},
      id: {:bullx_plugin, plugin.id}
    )
  end
end
