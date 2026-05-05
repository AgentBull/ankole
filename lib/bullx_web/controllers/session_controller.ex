defmodule BullXWeb.SessionController do
  use BullXWeb, :controller

  alias BullXAccounts.User

  def new(conn, _params) do
    cond do
      BullXAccounts.setup_required?() and BullXAccounts.bootstrap_activation_code_pending?() ->
        redirect(conn, to: ~p"/setup")

      match?(%User{}, conn.assigns[:current_user]) ->
        redirect(conn, to: ~p"/")

      true ->
        render_new(conn)
    end
  end

  def create(conn, params) do
    params
    |> auth_code_from_params()
    |> consume_auth_code(conn)
  end

  def delete(conn, _params) do
    conn
    |> BullXWeb.Sessions.renew_session()
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/sessions/new")
  end

  defp consume_auth_code({:ok, auth_code}, conn) do
    case BullXAccounts.consume_user_channel_auth_code(auth_code) do
      {:ok, user} -> sign_in(conn, user)
      {:error, :user_banned} -> invalid_login(conn)
      {:error, :invalid_or_expired_code} -> invalid_login(conn)
    end
  end

  defp consume_auth_code(:error, conn), do: invalid_login(conn)

  defp sign_in(conn, user) do
    conn
    |> BullXWeb.Sessions.renew_session()
    |> put_session(:user_id, user.id)
    |> put_flash(:info, "Signed in.")
    |> redirect(to: ~p"/")
  end

  defp invalid_login(conn) do
    conn
    |> put_flash(:error, "Invalid or expired authentication code.")
    |> redirect(to: ~p"/sessions/new")
  end

  defp auth_code_from_params(%{"session" => %{"auth_code" => auth_code}}),
    do: normalize_auth_code(auth_code)

  defp auth_code_from_params(%{"auth_code" => auth_code}), do: normalize_auth_code(auth_code)
  defp auth_code_from_params(_params), do: :error

  defp normalize_auth_code(auth_code) when is_binary(auth_code) do
    auth_code
    |> String.trim()
    |> String.upcase()
    |> case do
      "" -> :error
      value -> {:ok, value}
    end
  end

  defp normalize_auth_code(_auth_code), do: :error

  defp render_new(conn) do
    conn
    |> assign(:page_title, "Sign In")
    |> assign_prop(:form_action, ~p"/sessions")
    |> assign_prop(:login_providers, BullXWeb.Sessions.login_providers())
    |> render_inertia("sessions/New")
  end
end
