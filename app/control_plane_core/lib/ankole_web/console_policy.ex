defmodule AnkoleWeb.ConsolePolicy do
  @moduledoc """
  Authorization boundary for console REST API actions.

  The console API pipeline verifies the browser session and re-checks that the
  subject is still an active Human administrator. This module keeps the explicit
  AuthZ decision path alive for resource/action checks without doing per-request
  grant repair.
  """

  alias Ankole.AuthZ

  @type resource :: String.t()
  @type action :: String.t()

  @doc """
  Returns `:ok` when the current console principal may perform the action.
  """
  @spec authorize(Plug.Conn.t(), resource(), action()) :: :ok | {:error, :forbidden}
  def authorize(%Plug.Conn{assigns: %{current_principal_uid: principal_uid}}, resource, action)
      when is_binary(principal_uid) do
    with :ok <-
           AuthZ.authorize(principal_uid, resource, action, %{
             "surface" => "console_rest"
           }) do
      :ok
    else
      _reason -> {:error, :forbidden}
    end
  end

  # Fail closed: without a `current_principal_uid` assign from the authenticated
  # session boundary there is no authenticated Principal, so deny.
  def authorize(_conn, _resource, _action), do: {:error, :forbidden}
end
