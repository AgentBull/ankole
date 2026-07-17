defmodule Ankole.ControlPlanePlugins do
  @moduledoc """
  Operator-facing projection of compiled Elixir/OTP Control Plane Plugins.

  Configuration is durable but activation is boot-time. Writes only change the
  next-start selection; the active registry remains the truth for this process.
  """

  alias Ankole.Plugins

  @spec list() :: {:ok, [map()]} | {:error, term()}
  def list do
    with {:ok, disabled_ids} <- Plugins.disabled_ids() do
      disabled = MapSet.new(disabled_ids)
      active = Plugins.list_active() |> MapSet.new(& &1.id)

      {:ok,
       Plugins.list_discovered()
       |> Enum.map(fn plugin ->
         configured_enabled = not MapSet.member?(disabled, plugin.id)
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
      with {:ok, disabled_ids} <- Plugins.disabled_ids(),
           {:ok, _stored} <-
             Plugins.put_disabled_ids(update_disabled_ids(disabled_ids, id, enabled)) do
        list()
      end
    else
      {:error, :control_plane_plugin_not_found}
    end
  end

  def configure(_id, _enabled), do: {:error, :invalid_control_plane_plugin_configuration}

  defp update_disabled_ids(disabled_ids, id, true), do: Enum.reject(disabled_ids, &(&1 == id))

  defp update_disabled_ids(disabled_ids, id, false) do
    [id | disabled_ids]
    |> Enum.uniq()
    |> Enum.sort()
  end
end
