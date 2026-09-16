defmodule Ankole.OIDC.RPLogout do
  @moduledoc false
  alias Ankole.{BrowserSessions, OIDC, Repo}
  alias Ankole.OIDC.{LogoutRequest, Sessions}
  alias Ankole.OIDC.Boruta.IdTokens

  def prepare(ref, params) do
    with {:ok, browser} <- BrowserSessions.get(ref),
         {:ok, client} <- request_client(params),
         :ok <- validate_hint(params["id_token_hint"], client),
         :ok <- validate_redirect(params["post_logout_redirect_uri"], client),
         true <- is_nil(params["state"]) or is_binary(params["state"]) do
      %LogoutRequest{}
      |> Ecto.Changeset.change(
        browser_id: browser.id,
        browser_generation: browser.generation,
        client_id: if(client, do: client.id),
        redirect_uri: params["post_logout_redirect_uri"],
        state: params["state"],
        expires_at: DateTime.add(DateTime.utc_now(), 10 * 60)
      )
      |> Repo.insert()
    else
      false -> {:error, :invalid_logout_request}
      error -> error
    end
  end

  def confirmation(ref, id) do
    with {:ok, browser} <- BrowserSessions.get(ref),
         {:ok, id} <- Ecto.UUID.cast(id),
         %LogoutRequest{} = request <- Repo.get(LogoutRequest, id),
         true <-
           request.browser_id == browser.id and request.browser_generation == browser.generation and
             is_nil(request.confirmed_at) and
             DateTime.compare(request.expires_at, DateTime.utc_now()) == :gt do
      {:ok, request}
    else
      _ -> {:error, :logout_request_expired}
    end
  end

  def confirm(ref, id) do
    Repo.transact(fn repo ->
      with {:ok, request} <- confirmation(ref, id),
           {:ok, client} <- current_client(request.client_id),
           :ok <- validate_redirect(request.redirect_uri, client),
           {:ok, browser} <- BrowserSessions.logout(ref),
           {:ok, request} <-
             request |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now()) |> repo.update() do
        {:ok, %{request: request, browser: browser}}
      end
    end)
  end

  def cancel(ref, id) do
    with {:ok, request} <- confirmation(ref, id),
         do: Repo.delete(request)
  end

  def redirect_uri(%LogoutRequest{redirect_uri: nil}), do: nil
  def redirect_uri(%LogoutRequest{redirect_uri: uri, state: nil}), do: uri

  def redirect_uri(%LogoutRequest{redirect_uri: uri, state: state}) do
    parsed = URI.parse(uri)
    query = URI.encode_query(%{"state" => state})
    query = if parsed.query in [nil, ""], do: query, else: parsed.query <> "&" <> query
    URI.to_string(%{parsed | query: query})
  end

  defp request_client(params) do
    with {:ok, hint_id} <- hint_client(params["id_token_hint"]),
         id <- params["client_id"] || hint_id,
         true <- is_nil(hint_id) or is_nil(params["client_id"]) or params["client_id"] == hint_id do
      if is_nil(id), do: {:ok, nil}, else: OIDC.get_active_client(id)
    else
      _ -> {:error, :invalid_logout_client}
    end
  end

  defp current_client(nil), do: {:ok, nil}
  defp current_client(id), do: OIDC.get_active_client(id)

  defp hint_client(nil), do: {:ok, nil}
  defp hint_client(token), do: IdTokens.client_id(token)

  defp validate_hint(nil, _client), do: :ok

  defp validate_hint(token, %{id: client_id}) do
    with {:ok, claims} <- IdTokens.verify_hint(token, client_id),
         {:ok, session} <- Sessions.get(claims["sid"]),
         true <-
           session.client_id == client_id and session.principal_uid == claims["sub"],
         true <- recent?(session) do
      :ok
    else
      _ -> {:error, :invalid_id_token_hint}
    end
  end

  defp validate_hint(_token, _client), do: {:error, :invalid_id_token_hint}

  defp recent?(%{ended_at: nil, expires_at: expiry}),
    do: DateTime.compare(expiry, DateTime.utc_now()) == :gt

  defp recent?(%{ended_at: ended}), do: DateTime.diff(DateTime.utc_now(), ended) <= 24 * 60 * 60

  defp validate_redirect(nil, _client), do: :ok

  defp validate_redirect(uri, %{post_logout_redirect_uris: uris}) when is_binary(uri) do
    if uri in uris, do: :ok, else: {:error, :unregistered_logout_redirect}
  end

  defp validate_redirect(_uri, _client), do: {:error, :unregistered_logout_redirect}
end
