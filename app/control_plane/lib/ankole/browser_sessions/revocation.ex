defmodule Ankole.BrowserSessions.Revocation do
  @moduledoc """
  Browser authentication revocation, logout, and expired session cleanup.
  """
  require Ash.Query

  alias Ankole.BrowserSessions.{Authentication, Identity, OidcState, PodAccess, Session}
  alias Ankole.OIDC.AuthorizationRequests
  alias Ankole.Repo

  def revoke(browser_ref, authentication_ref) do
    Repo.transact_top_level(fn -> revoke_in_tx(browser_ref, authentication_ref) end)
  end

  @doc false
  def revoke_in_tx(browser_ref, authentication_ref) do
    Identity.in_transaction!(:revoke_in_tx)

    with {:ok, browser} <- Identity.fetch_browser(browser_ref, true),
         {:ok, authentication} <- Identity.fetch_authentication(authentication_ref),
         true <- authentication.browser_id == browser.id do
      finish_revocation(browser, authentication)
    else
      false -> {:error, :invalid_authentication}
      error -> error
    end
  end

  def revoke_pod(browser_ref, authentication_ref, tenant_id) when is_binary(tenant_id) do
    Repo.transact_top_level(fn ->
      revoke_pod_in_tx(browser_ref, authentication_ref, tenant_id)
    end)
  end

  @doc false
  def revoke_pod_in_tx(browser_ref, authentication_ref, tenant_id) when is_binary(tenant_id) do
    Identity.in_transaction!(:revoke_pod_in_tx)

    with {:ok, tenant_id} <- cast_tenant_id(tenant_id),
         {:ok, browser} <- Identity.fetch_browser(browser_ref, true),
         {:ok, authentication} <- Identity.fetch_authentication(authentication_ref),
         true <- authentication.browser_id == browser.id do
      case authentication.scope do
        :tenant ->
          if authentication.tenant_id == tenant_id do
            with {:ok, browser} <- finish_revocation(browser, authentication) do
              {:ok, %{browser: browser, authentication_revoked?: true}}
            end
          else
            {:error, :invalid_authentication}
          end

        :site ->
          revoke_site_pod(browser, authentication, tenant_id)
      end
    else
      false -> {:error, :invalid_authentication}
      error -> error
    end
  end

  defp cast_tenant_id(tenant_id) do
    case Ecto.UUID.cast(tenant_id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_authentication}
    end
  end

  defp revoke_site_pod(browser, authentication, tenant_id) do
    pod_ids = PodAccess.pod_tenant_ids(authentication.id)

    if tenant_id not in pod_ids do
      {:error, :invalid_authentication}
    else
      remaining? =
        pod_ids
        |> Enum.reject(&(&1 == tenant_id))
        |> Enum.any?(&(Identity.authentication_identity(authentication, &1) != nil))

      if remaining? do
        with :ok <-
               Ankole.OIDC.Sessions.end_authentication_in_tx(
                 authentication.id,
                 authentication.revision,
                 tenant_id: tenant_id
               ),
             :ok <- PodAccess.remove_pod_authentication_in_tx(authentication, tenant_id),
             :ok <-
               AuthorizationRequests.cancel_for_browser_in_tx(browser.id,
                 authentication_id: authentication.id,
                 tenant_id: tenant_id
               ),
             :ok <-
               OidcState
               |> Ash.Query.filter(
                 browser_id == ^browser.id and tenant_id == ^tenant_id and is_nil(consumed_at) and
                   expected_authentication_id == ^authentication.id
               )
               |> expire_oidc_states(),
             {:ok, browser} <- clear_revoked_pod_default(browser, authentication.id, tenant_id) do
          {:ok, %{browser: browser, authentication_revoked?: false}}
        end
      else
        with {:ok, browser} <- finish_revocation(browser, authentication) do
          {:ok, %{browser: browser, authentication_revoked?: true}}
        end
      end
    end
  end

  defp clear_revoked_pod_default(browser, authentication_id, tenant_id) do
    attrs = [revision: browser.revision + 1]

    attrs =
      if browser.active_authentication_id == authentication_id and
           browser.active_tenant_id == tenant_id,
         do: attrs ++ [active_authentication_id: nil, active_tenant_id: nil],
         else: attrs

    Ankole.Ash.update(browser, :revoke_in_tx, Map.new(attrs))
  end

  defp finish_revocation(browser, authentication) do
    with :ok <- revoke_records([authentication], browser.revision + 1),
         :ok <-
           AuthorizationRequests.cancel_for_browser_in_tx(browser.id,
             authentication_id: authentication.id
           ),
         :ok <-
           OidcState
           |> Ash.Query.filter(
             browser_id == ^browser.id and is_nil(consumed_at) and
               expected_authentication_id == ^authentication.id
           )
           |> expire_oidc_states() do
      attrs = [revision: browser.revision + 1]

      attrs =
        if browser.active_authentication_id == authentication.id,
          do: attrs ++ [active_authentication_id: nil, active_tenant_id: nil],
          else: attrs

      Ankole.Ash.update(browser, :revoke_in_tx, Map.new(attrs))
    end
  end

  def logout(ref, expected_revision \\ nil) do
    Repo.transact_top_level(fn -> logout_in_tx(ref, expected_revision) end)
  end

  @doc "Ends a browser and its OIDC Sessions in the caller's transaction."
  def logout_in_tx(ref, expected_revision \\ nil) do
    Identity.in_transaction!(:logout_in_tx)

    with {:ok, browser} <- Identity.fetch_browser(ref, true),
         true <- is_nil(expected_revision) or browser.revision == expected_revision,
         :ok <- revoke_records(live_authentications(browser.id), browser.revision + 1),
         :ok <- Ankole.OIDC.Sessions.end_browser_in_tx(browser.id),
         :ok <- AuthorizationRequests.cancel_for_browser_in_tx(browser.id),
         :ok <-
           OidcState
           |> Ash.Query.filter(browser_id == ^browser.id and is_nil(consumed_at))
           |> expire_oidc_states() do
      Ankole.Ash.update(browser, :logout_in_tx, %{
        revision: browser.revision + 1,
        logout_revision: browser.revision + 1
      })
    else
      false -> {:error, :logout_request_expired}
      error -> error
    end
  end

  def cleanup_expired(now) do
    oidc_states =
      OidcState
      |> Ash.Query.filter(expires_at <= ^now or not is_nil(consumed_at))
      |> expire_records()

    browsers =
      Session
      |> Ash.Query.filter(
        expires_at <= ^now and
          fragment("NOT EXISTS (SELECT 1 FROM oidc_sessions AS s WHERE s.browser_id = ?)", id)
      )
      |> expire_records()

    %{oidc_states: oidc_states, browser_sessions: browsers}
  end

  @doc false
  def live_authentications(browser_id) do
    Authentication
    |> Ash.Query.filter(browser_id == ^browser_id and is_nil(revoked_at))
    |> Ankole.Ash.read!()
  end

  @doc false
  def revoke_records(authentications, revision) do
    Enum.reduce_while(authentications, :ok, fn authentication, :ok ->
      with :ok <- end_authentication(authentication),
           {:ok, _} <-
             Ankole.Ash.update(authentication, :revoke_in_tx, %{revision: revision}) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  @doc false
  def end_authentication(nil), do: :ok

  def end_authentication(authentication),
    do:
      Ankole.OIDC.Sessions.end_authentication_in_tx(
        authentication.id,
        authentication.revision
      )

  @doc false
  def expire_oidc_states(query) do
    with {:ok, _expired} <-
           query
           |> Ash.Query.select([:id])
           |> Ankole.Ash.destroy_where(:expire_in_tx),
         do: :ok
  end

  defp expire_records(query) do
    query
    |> Ash.Query.select(Ash.Resource.Info.primary_key(query.resource))
    |> Ankole.Ash.destroy_where(:expire_in_tx)
    |> case do
      {:ok, records} -> length(records)
      {:error, error} -> raise error
    end
  end
end
