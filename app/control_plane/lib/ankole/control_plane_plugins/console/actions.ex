defmodule Ankole.ControlPlanePlugins.Console.Actions do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  alias Ankole.Plugins

  @impl true
  def run(input, _opts, _context) do
    result =
      case input.action.name do
        :list ->
          list()

        :configure ->
          configure(input.arguments.id, input.arguments.enabled)
      end

    with {:ok, plugins} <- Ankole.Errors.wrap(result, &describe/1),
         do: {:ok, %{control_plane_plugins: plugins}}
  end

  @spec list() :: {:ok, [map()]} | {:error, term()}
  def list do
    with {:ok, enabled_ids} <- Plugins.enabled_ids() do
      enabled = MapSet.new(enabled_ids)

      {:ok,
       Plugins.list_discovered()
       |> Enum.map(fn plugin ->
         configured_enabled = plugin.activation == :always or MapSet.member?(enabled, plugin.id)
         active? = Plugins.active?(plugin.id)

         %{
           "id" => plugin.id,
           "activation" => Atom.to_string(plugin.activation),
           "display_name" => plugin.display_name || %{"default" => plugin.id},
           "description" => plugin.description,
           "configured_enabled" => configured_enabled,
           "active" => active?,
           "restart_required" => configured_enabled != active?
         }
       end)}
    end
  end

  defp configure(id, enabled) do
    case Enum.find(Plugins.list_discovered(), &(&1.id == id)) do
      nil ->
        {:error, :control_plane_plugin_not_found}

      %{activation: :always} when not enabled ->
        {:error, :control_plane_plugin_always_enabled}

      _plugin ->
        with {:ok, _stored} <- Plugins.put_configured_enabled(id, enabled), do: list()
    end
  end

  defp describe(:control_plane_plugin_always_enabled),
    do: {"This Plugin is included in the source build and cannot be disabled", []}

  defp describe(:control_plane_plugin_not_found),
    do: Ankole.Errors.Invalid.NotFound.exception(resource: Ankole.ControlPlanePlugins.Console)

  defp describe(reason) do
    case Ankole.AgentWorkers.Providers.Errors.describe(reason) do
      {:conflict, _message, _details} = conflict -> conflict
      _other -> {"Control Plane Plugin configuration is invalid", []}
    end
  end
end
