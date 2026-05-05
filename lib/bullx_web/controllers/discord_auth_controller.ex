defmodule BullXWeb.DiscordAuthController do
  use BullXWeb, :controller

  @session_key :session_controller_state
  @state_max_age_seconds 600

  def new(conn, %{"channel_id" => channel_id} = params) do
    return_to = BullXWeb.Sessions.safe_return_to(Map.get(params, "return_to"))
    state = random_state()

    with :ok <- ensure_channel_id_available(channel_id),
         redirect_uri <- BullXWeb.Sessions.callback_url("discord", channel_id),
         {:ok, url} <- BullXDiscord.SSO.authorization_url(channel_id, redirect_uri, state) do
      conn
      |> put_session(@session_key, %{
        "provider" => "discord",
        "channel_id" => channel_id,
        "return_to" => return_to,
        "nonce" => state,
        "issued_at" => System.system_time(:second)
      })
      |> redirect(external: url)
    else
      {:error, _reason} ->
        conn
        |> put_flash(:error, BullX.I18n.t("gateway.discord.auth.web_auth_failed"))
        |> redirect(to: ~p"/sessions/new")
    end
  end

  def callback(conn, %{"channel_id" => channel_id} = params) do
    with :ok <- ensure_channel_id_available(channel_id),
         {:ok, pending} <- verify_pending_state(conn, channel_id, Map.get(params, "state")),
         redirect_uri <- BullXWeb.Sessions.callback_url("discord", channel_id),
         login_params <-
           Map.merge(params, %{
             "channel_id" => channel_id,
             "redirect_uri" => redirect_uri,
             "return_to" => pending["return_to"]
           }),
         {:ok, %{user: user, return_to: return_to}} <-
           BullXDiscord.SSO.login_from_callback(login_params) do
      conn
      |> BullXWeb.Sessions.renew_session()
      |> put_session(:user_id, user.id)
      |> put_flash(:info, "Signed in.")
      |> redirect(to: return_to)
    else
      {:error, :not_bound} ->
        conn
        |> delete_session(@session_key)
        |> login_failed(BullX.I18n.t("gateway.discord.auth.login_not_bound"))

      {:error, :user_banned} ->
        conn
        |> delete_session(@session_key)
        |> login_failed(BullX.I18n.t("gateway.discord.auth.denied"))

      {:error, _reason} ->
        conn
        |> delete_session(@session_key)
        |> login_failed(BullX.I18n.t("gateway.discord.auth.web_auth_failed"))
    end
  end

  defp login_failed(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/sessions/new")
  end

  defp ensure_channel_id_available(channel_id) do
    case BullXWeb.Sessions.route_safe_channel_id?(channel_id) do
      true -> :ok
      false -> {:error, :invalid_channel_id}
    end
  end

  defp verify_pending_state(conn, channel_id, state) when is_binary(state) do
    case get_session(conn, @session_key) do
      %{
        "provider" => "discord",
        "channel_id" => ^channel_id,
        "nonce" => ^state,
        "issued_at" => issued_at
      } = pending
      when is_integer(issued_at) ->
        verify_pending_age(pending)

      _other ->
        {:error, :invalid_state}
    end
  end

  defp verify_pending_state(_conn, _channel_id, _state), do: {:error, :invalid_state}

  defp verify_pending_age(%{"issued_at" => issued_at} = pending) do
    case System.system_time(:second) - issued_at <= @state_max_age_seconds do
      true -> {:ok, pending}
      false -> {:error, :invalid_state}
    end
  end

  defp random_state do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
