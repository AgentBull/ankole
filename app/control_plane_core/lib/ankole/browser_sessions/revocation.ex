defmodule Ankole.BrowserSessions.Revocation do
  @moduledoc """
  Browser authentication revocation, logout, and expired session cleanup.
  """
  require Ash.Query

  alias Ankole.BrowserSessions.{Authentication, Identity, LoginTransaction, Session}
  alias Ankole.Repo

  def revoke(browser_ref, authentication_ref) do
    Repo.transact_top_level(fn -> revoke_in_tx(browser_ref, authentication_ref) end)
  end

  @doc false
  def revoke_in_tx(browser_ref, authentication_ref) do
    Identity.in_transaction!(:revoke_in_tx)

    with {:ok, browser} <- Identity.fetch_browser(browser_ref, true),
         {:ok, authentication} <- Identity.fetch_authentication(authentication_ref),
         true <- authentication.browser_id == browser.id,
         :ok <- revoke_records([authentication], browser.revision + 1),
         :ok <-
           LoginTransaction
           |> Ash.Query.filter(
             browser_id == ^browser.id and status in [:pending, :authenticated] and
               (expected_authentication_id == ^authentication.id or
                  authentication_id == ^authentication.id)
           )
           |> cancel_logins() do
      attrs = [revision: browser.revision + 1]

      attrs =
        if browser.active_authentication_id == authentication.id,
          do: attrs ++ [active_authentication_id: nil, active_tenant_id: nil],
          else: attrs

      Ankole.Ash.update(browser, :revoke_in_tx, Map.new(attrs))
    else
      false -> {:error, :invalid_authentication}
      error -> error
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
         :ok <-
           LoginTransaction
           |> Ash.Query.filter(browser_id == ^browser.id and status in [:pending, :authenticated])
           |> cancel_logins() do
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
    transactions = LoginTransaction |> Ash.Query.filter(expires_at <= ^now) |> expire_records()

    browsers =
      Session
      |> Ash.Query.filter(
        expires_at <= ^now and
          fragment("NOT EXISTS (SELECT 1 FROM oidc_sessions AS s WHERE s.browser_id = ?)", id)
      )
      |> expire_records()

    %{login_transactions: transactions, browser_sessions: browsers}
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
  def cancel_logins(query) do
    with {:ok, _cancelled} <- Ankole.Ash.update_where(query, :cancel_in_tx), do: :ok
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
