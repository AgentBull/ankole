defmodule AnkoleWeb.ConsolePolicy do
  @moduledoc """
  Authorization boundary for console REST API actions.

  Console authorization keeps the coarse active-admin identity gate, then routes
  concrete resource/action checks through `Ankole.AuthZ`.
  """

  alias Ankole.AdminAuth
  alias Ankole.AuthZ

  @type resource :: String.t()
  @type action :: String.t()

  @doc """
  Returns `:ok` when the current console principal may perform the action.
  """
  @spec authorize(Plug.Conn.t(), resource(), action()) :: :ok | {:error, :forbidden}
  def authorize(%Plug.Conn{assigns: %{current_principal_uid: principal_uid}}, resource, action)
      when is_binary(principal_uid) do
    with true <- AdminAuth.active_human_admin?(principal_uid),
         :ok <- AuthZ.ensure_console_admin_grants(),
         :ok <-
           AuthZ.authorize(principal_uid, resource, action, %{
             "surface" => "console_rest"
           }) do
      :ok
    else
      _reason -> {:error, :forbidden}
    end
  end

  # Fail closed: without a `current_principal_uid` assign (set only by the bearer
  # plug on success) there is no authenticated principal, so deny.
  def authorize(_conn, _resource, _action), do: {:error, :forbidden}
end
