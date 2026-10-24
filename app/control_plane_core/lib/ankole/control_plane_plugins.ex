defmodule Ankole.ControlPlanePlugins do
  @moduledoc """
  Operator-facing projection of compiled Elixir/OTP Control Plane Plugins.

  Configuration is durable but activation is boot-time. Writes only change the
  next-start selection; the active registry remains the truth for this process.
  """

  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  json_api do
    authorize?(true)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      base_route "/control-plane-plugins", Ankole.ControlPlanePlugins.Console do
        route(:get, "/", :list, name: "list_control_plane_plugins", wrap_in_result?: false)

        route(:put, "/", :configure,
          name: "configure_control_plane_plugin",
          wrap_in_result?: false
        )
      end
    end
  end

  resources do
    resource(Ankole.ControlPlanePlugins.Console)
  end

  alias Ankole.Plugins

  @spec list() :: {:ok, [map()]} | {:error, term()}
  def list do
    with {:ok, enabled_ids} <- Plugins.enabled_ids() do
      enabled = MapSet.new(enabled_ids)
      active = Plugins.list_active() |> MapSet.new(& &1.id)

      {:ok,
       Plugins.list_discovered()
       |> Enum.map(fn plugin ->
         configured_enabled = MapSet.member?(enabled, plugin.id)
         active? = MapSet.member?(active, plugin.id)

         %{
           "id" => plugin.id,
           "display_name" => plugin.display_name || %{"default" => plugin.id},
           "description" => plugin.description,
           "configured_enabled" => configured_enabled,
           "active" => active?,
           "restart_required" => configured_enabled != active?
         }
       end)
       |> Enum.sort_by(& &1["id"])}
    end
  end

  @spec configure(String.t(), boolean()) :: {:ok, [map()]} | {:error, term()}
  def configure(id, enabled) when is_binary(id) and is_boolean(enabled) do
    discovered_ids = Plugins.list_discovered() |> MapSet.new(& &1.id)

    if MapSet.member?(discovered_ids, id) do
      with {:ok, _stored} <- Plugins.put_configured_enabled(id, enabled) do
        list()
      end
    else
      {:error, :control_plane_plugin_not_found}
    end
  end

  def configure(_id, _enabled), do: {:error, :invalid_control_plane_plugin_configuration}
end
