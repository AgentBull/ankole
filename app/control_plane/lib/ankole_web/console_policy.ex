defmodule AnkoleWeb.ConsolePolicy do
  @moduledoc """
  Authorization boundary for console REST API actions.

  The first implementation is a coarse active-admin gate. Controllers still call
  this module with resource/action pairs so future AuthZ integration can replace
  the internals without changing the HTTP surface.
  """

  alias Ankole.AdminAuth

  @type resource :: String.t()
  @type action :: String.t()

  @doc """
  Returns `:ok` when the current console principal may perform the action.
  """
  @spec authorize(Plug.Conn.t(), resource(), action()) :: :ok | {:error, :forbidden}
  def authorize(%Plug.Conn{assigns: %{current_principal_uid: principal_uid}}, _resource, _action)
      when is_binary(principal_uid) do
    case AdminAuth.active_human_admin?(principal_uid) do
      true -> :ok
      false -> {:error, :forbidden}
    end
  end

  def authorize(_conn, _resource, _action), do: {:error, :forbidden}
end
