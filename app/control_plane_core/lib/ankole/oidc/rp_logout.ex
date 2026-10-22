defmodule Ankole.OIDC.RPLogout do
  @moduledoc false
  require Ash.Query
  alias Ankole.{BrowserSessions, OIDC, Repo}
  alias Ankole.OIDC.LogoutRequest
  alias Ankole.OIDC.Sessions

  def prepare(ref, params) do
    with {:ok, browser} <- BrowserSessions.get(ref),
         {:ok, request} <- Attesto.EndSession.parse(OIDC.attesto_config(), params),
         {:ok, client} <- Repo.across_tenants(fn -> current_client(request.client_id) end),
         {:ok, tenant_id} <- request_tenant(client, browser) do
      Repo.with_tenant(tenant_id, fn -> prepare_request(browser, client, request) end)
    end
  end

  defp prepare_request(browser, client, request) do
    with :ok <- validate_hint(request, client),
         {:ok, _} <- confirm_redirect(request, client),
         true <- is_nil(request.state) or is_binary(request.state) do
      Repo.transact(fn _repo ->
        Ankole.Ash.create(LogoutRequest, :prepare_in_tx, %{
          browser_id: browser.id,
          browser_revision: browser.revision,
          client_id: if(client, do: client.id),
          redirect_uri: request.post_logout_redirect_uri,
          state: request.state,
          expires_at: DateTime.add(DateTime.utc_now(), 10 * 60)
        })
      end)
    else
      false -> {:error, :invalid_logout_request}
      error -> error
    end
  end

  defp request_tenant(%{tenant_id: id}, _browser), do: {:ok, id}

  defp request_tenant(nil, browser) do
    case browser.active_tenant_id do
      id when is_binary(id) -> {:ok, id}
      nil -> with {:ok, tenant} <- Ankole.Tenants.privileged(), do: {:ok, tenant.id}
    end
  end

  def confirmation(ref, id) do
    with {:ok, browser} <- BrowserSessions.get(ref),
         {:ok, id} <- Ecto.UUID.cast(id),
         %LogoutRequest{} = request <- find_request(id),
         true <-
           request.browser_id == browser.id and request.browser_revision == browser.revision and
             is_nil(request.confirmed_at) and
             DateTime.compare(request.expires_at, DateTime.utc_now()) == :gt do
      {:ok, request}
    else
      _ -> {:error, :logout_request_expired}
    end
  end

  def confirm(ref, id) do
    with {:ok, request} <- confirmation(ref, id) do
      Repo.with_tenant(request.tenant_id, fn ->
        Repo.transact(fn _repo ->
          with {:ok, request} <- confirmation(ref, id),
               {:ok, client} <- current_client(request.client_id),
               {:ok, redirect_uri} <-
                 confirm_redirect(
                   %Attesto.EndSession{
                     client_id: request.client_id,
                     post_logout_redirect_uri: request.redirect_uri,
                     state: request.state
                   },
                   client
                 ),
               {:ok, browser} <- BrowserSessions.logout(ref, request.browser_revision),
               {:ok, request} <- Ankole.Ash.update(request, :confirm_in_tx, %{}) do
            {:ok, %{request: request, browser: browser, redirect_uri: redirect_uri}}
          end
        end)
      end)
    end
  end

  def cancel(ref, id) do
    with {:ok, request} <- confirmation(ref, id) do
      Repo.with_tenant(request.tenant_id, fn ->
        Repo.transact(fn _repo -> Ankole.Ash.destroy(request, :cancel_in_tx) end)
      end)
    end
  end

  defp find_request(id) do
    Repo.across_tenants(fn ->
      LogoutRequest
      |> Ash.Query.for_read(:lookup_across_tenants, %{}, authorize?: false)
      |> Ash.Query.filter(id == ^id)
      |> Ash.read_one!(authorize?: false)
    end)
  end

  defp current_client(nil), do: {:ok, nil}
  defp current_client(id), do: OIDC.get_active_client(id)

  defp validate_hint(%Attesto.EndSession{sid: nil, subject: nil}, _client), do: :ok

  defp validate_hint(%Attesto.EndSession{sid: sid, subject: subject}, %{id: client_id}) do
    with {:ok, session} <- Sessions.get(sid),
         true <- session.client_id == client_id and session.principal_uid == subject,
         true <- recent?(session),
         do: :ok,
         else: (_ -> {:error, :invalid_id_token_hint})
  end

  defp validate_hint(_, _), do: {:error, :invalid_id_token_hint}

  defp recent?(%{ended_at: nil, expires_at: expiry}),
    do: DateTime.compare(expiry, DateTime.utc_now()) == :gt

  defp recent?(%{ended_at: ended}), do: DateTime.diff(DateTime.utc_now(), ended) <= 24 * 60 * 60

  defp confirm_redirect(%Attesto.EndSession{} = request, client) do
    uris = if(client, do: client.post_logout_redirect_uris, else: [])

    case Attesto.EndSession.confirm_redirect(request, uris) do
      {:ok, :no_redirect} -> {:ok, nil}
      {:ok, uri} -> {:ok, uri}
      error -> error
    end
  end
end
