defmodule Ankole.ControlPlanePlugins.Console.Actions do
  @moduledoc false
  use Ash.Resource.Actions.Implementation

  @impl true
  def run(input, _opts, _context) do
    result =
      case input.action.name do
        :list ->
          Ankole.ControlPlanePlugins.list()

        :configure ->
          Ankole.ControlPlanePlugins.configure(input.arguments.id, input.arguments.enabled)
      end

    with {:ok, plugins} <- Ankole.Errors.wrap(result, &describe/1),
         do: {:ok, %{control_plane_plugins: plugins}}
  end

  defp describe(:control_plane_plugin_not_found),
    do: Ankole.Errors.Invalid.NotFound.exception(resource: Ankole.ControlPlanePlugins.Console)

  defp describe(reason) do
    case Ankole.AgentWorkers.Providers.Errors.describe(reason) do
      {:conflict, _message, _details} = conflict -> conflict
      _other -> {"Control Plane Plugin configuration is invalid", []}
    end
  end
end
