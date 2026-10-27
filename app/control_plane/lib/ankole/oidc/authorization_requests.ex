defmodule Ankole.OIDC.AuthorizationRequests do
  @moduledoc false
  require Ash.Query
  alias Ankole.{BrowserSessions, Principals, Repo}
  alias Ankole.OIDC.{AuthorizationRequest, LoginPolicy}

  @request_ttl 10 * 60

  def begin(browser_ref, client_id, request, opts \\ []) when is_map(request) do
    Repo.transact_top_level(fn -> begin_in_tx(browser_ref, client_id, request, opts) end)
  end

  def begin_in_tx(browser_ref, client_id, request, opts \\ []) when is_map(request) do
    :ok = Repo.require_transaction()

    with {:ok, browser} <- BrowserSessions.lock_browser_in_tx(browser_ref) do
      Ankole.Ash.create(AuthorizationRequest, :begin_in_tx, %{
        browser_id: browser.id,
        client_id: client_id,
        started_revision: browser.revision,
        request: request,
        expected_authentication_id: Keyword.get(opts, :expected_authentication_id),
        expires_at: DateTime.add(DateTime.utc_now(), @request_ttl)
      })
    end
  end

  def get(browser_ref, id) do
    with {:ok, browser} <- BrowserSessions.get(browser_ref),
         {:ok, id} <- Ecto.UUID.cast(id),
         %AuthorizationRequest{} = request <- find_request(id),
         true <- live_for_browser?(request, browser) do
      {:ok, request}
    else
      _ -> {:error, :login_expired}
    end
  end

  def authenticate_in_tx(browser_ref, id, authentication) do
    :ok = Repo.require_transaction()

    with {:ok, browser} <- BrowserSessions.lock_browser_in_tx(browser_ref),
         {:ok, %AuthorizationRequest{status: :pending} = request} <- get(browser_ref, id),
         true <- request.tenant_id == Repo.tenant_id!(),
         :ok <- expected_authentication(request, authentication) do
      Ankole.Ash.update(request, :authenticate_in_tx, %{
        authentication_id: authentication.id,
        authentication_revision: authentication.revision,
        request: request.request,
        started_revision: max(request.started_revision, browser.revision)
      })
    else
      false -> {:error, :invalid_authentication}
      {:ok, %AuthorizationRequest{}} -> {:error, :login_expired}
      error -> error
    end
  end

  def select_identity(browser_ref, id, authentication_ref) do
    with {:ok, request} <- get(browser_ref, id) do
      Repo.with_tenant(request.tenant_id, fn ->
        Repo.transact_top_level(fn ->
          select_identity_in_tx(browser_ref, id, authentication_ref)
        end)
      end)
    end
  end

  def select_identity_in_tx(browser_ref, id, authentication_ref) do
    :ok = Repo.require_transaction()

    with {:ok, _browser} <- BrowserSessions.lock_browser_in_tx(browser_ref),
         {:ok, request} <- get(browser_ref, id),
         true <- request.tenant_id == Repo.tenant_id!(),
         {:ok, authentication} <- BrowserSessions.get_authentication(authentication_ref),
         true <- authentication.browser_id == request.browser_id,
         %{} = auth <- BrowserSessions.identity(authentication_ref, request.tenant_id),
         {:ok, selected_request, action} <- LoginPolicy.select_authentication(request, auth),
         {:ok, updated_browser} <-
           BrowserSessions.activate_in_tx(browser_ref, authentication_ref, request.tenant_id) do
      if action == :reuse do
        Ankole.Ash.update(request, :authenticate_in_tx, %{
          authentication_id: authentication.id,
          authentication_revision: authentication.revision,
          request: selected_request,
          started_revision: updated_browser.revision
        })
      else
        Ankole.Ash.update(request, :reauthenticate_in_tx, %{
          expected_authentication_id: authentication.id,
          request: selected_request,
          started_revision: updated_browser.revision
        })
      end
    else
      false -> {:error, :invalid_authentication}
      nil -> {:error, :invalid_authentication}
      error -> error
    end
  end

  def consume(browser_ref, id, authentication_ref, issue) when is_function(issue, 2) do
    with {:ok, request} <- get(browser_ref, id) do
      Repo.with_tenant(request.tenant_id, fn ->
        Repo.transact_top_level(fn ->
          consume_in_tx(browser_ref, id, authentication_ref, issue)
        end)
      end)
    end
  end

  def consume_in_tx(browser_ref, id, authentication_ref, issue) when is_function(issue, 2) do
    :ok = Repo.require_transaction()

    with {:ok, _browser} <- BrowserSessions.lock_browser_in_tx(browser_ref),
         {:ok, request} <- get(browser_ref, id),
         true <- request.tenant_id == Repo.tenant_id!(),
         true <- LoginPolicy.authorization_ready?(request),
         true <-
           authentication_ref == %{
             "id" => request.authentication_id,
             "revision" => request.authentication_revision
           },
         %{} = auth <- BrowserSessions.identity(authentication_ref, request.tenant_id),
         {:ok, _principal} <- lock_active_human(auth),
         {:ok, _} <- Ankole.Ash.update(request, :consume_in_tx, %{}) do
      issue.(request.request, auth)
    else
      nil -> {:error, :login_expired}
      false -> {:error, :login_expired}
      error -> error
    end
  end

  def cancel_for_browser_in_tx(browser_id, opts \\ []) do
    :ok = Repo.require_transaction()
    except_id = Keyword.get(opts, :except_id)
    authentication_id = Keyword.get(opts, :authentication_id)

    query =
      AuthorizationRequest
      |> Ash.Query.for_read(:lookup_across_tenants)
      |> Ash.Query.filter(browser_id == ^browser_id and status in [:pending, :authenticated])

    query =
      if except_id,
        do: Ash.Query.filter(query, id != ^except_id),
        else: query

    query =
      if authentication_id do
        Ash.Query.filter(
          query,
          expected_authentication_id == ^authentication_id or
            authentication_id == ^authentication_id
        )
      else
        query
      end

    query
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_across_tenants!()
    |> Enum.reduce_while(:ok, fn request, :ok ->
      Repo.with_tenant(request.tenant_id, fn ->
        case Ankole.Ash.update(request, :cancel_in_tx, %{}) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end)
  end

  defp expected_authentication(%{expected_authentication_id: nil}, _authentication), do: :ok

  defp expected_authentication(%{expected_authentication_id: expected_id}, authentication) do
    if authentication.id == expected_id,
      do: :ok,
      else: {:error, :login_subject_mismatch}
  end

  defp lock_active_human(%{"principal_uid" => uid, "access_version" => version}) do
    with {:ok, %{type: :human, status: :active} = principal} <-
           Principals.lock_principal_in_tx(uid, :share),
         :ok <- Principals.HumanAccess.check(principal.uid, version) do
      {:ok, principal}
    else
      {:ok, _} -> {:error, :human_access_revoked}
      {:error, :not_found} -> {:error, :human_access_revoked}
      error -> error
    end
  end

  defp live_for_browser?(request, browser) do
    request.browser_id == browser.id and
      request.started_revision >= browser.logout_revision and
      request.status in [:pending, :authenticated] and
      DateTime.compare(request.expires_at, DateTime.utc_now()) == :gt
  end

  defp find_request(id) do
    Repo.across_tenants(fn ->
      AuthorizationRequest
      |> Ash.Query.for_read(:lookup_across_tenants)
      |> Ash.Query.filter(id == ^id)
      |> Ankole.Ash.read_one!()
    end)
  end
end
