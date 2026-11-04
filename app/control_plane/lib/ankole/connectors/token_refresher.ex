defmodule Ankole.Connectors.TokenRefresher do
  @moduledoc "Refreshes rotating OAuth credentials under a short database lease and version fence."
  require Ash.Query
  alias Ankole.Connectors.{Accounts, ConnectedAccount, Credentials, Store}
  alias Ankole.Principals.{HumanAccess, WorkAccess}
  alias Ankole.Repo

  def access_token(config, account, adapter) do
    with true <- Accounts.valid?(account),
         {:ok, tokens} <- Credentials.account_credentials(account) do
      if fresh?(account.expires_at),
        do: {:ok, tokens["access_token"]},
        else: refresh(config, account, adapter)
    else
      false -> {:error, :oauth_reauthorization_required}
      error -> error
    end
  end

  def refresh(config, account, adapter) do
    refresh(config, account, adapter, System.monotonic_time(:millisecond) + 30_000)
  end

  defp refresh(config, account, adapter, deadline) do
    case claim(config.id, account.id, account.credentials_version) do
      {:ok, {:fresh, row}} ->
        with {:ok, credentials} <- Credentials.account_credentials(row),
             do: {:ok, credentials["access_token"]}

      {:ok, {:refresh_failed, reason}} ->
        {:error, reason}

      {:ok, {config, row}} ->
        result =
          with {:ok, secret} <- Credentials.secret(config),
               {:ok, credentials} <- Credentials.account_credentials(row),
               do: refresh_token(adapter, config, secret, credentials)

        case finish(config, row, result) do
          {:ok, {:refresh_failed, reason}} -> {:error, reason}
          other -> other
        end

      {:error, :oauth_refresh_in_progress} = error ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          refresh(config, account, adapter, deadline)
        else
          error
        end

      error ->
        error
    end
  end

  defp refresh_token(adapter, config, secret, %{"refresh_token" => token} = credentials)
       when is_binary(token) and token != "",
       do: adapter.refresh_token(config, secret, credentials)

  defp refresh_token(_adapter, _config, _secret, _credentials),
    do: {:error, :oauth_reauthorization_required}

  def invalidate(config, account, token) do
    Repo.transact_top_level(fn ->
      with %{status: "active", secret_version: version} <- Store.lock(config.id),
           true <- version == config.secret_version,
           %{status: "active"} = row <- Accounts.lock(account.id),
           {:ok, %{"access_token" => ^token}} <- Credentials.account_credentials(row),
           {:ok, _} <-
             Ankole.Ash.update(row, :update, %{
               expires_at: DateTime.utc_now(),
               last_refresh_failure_at: nil,
               first_refresh_failure_at: nil
             }) do
        {:ok, :ok}
      else
        {:error, _} = error -> error
        _ -> {:ok, :ok}
      end
    end)
  end

  defp claim(config_id, account_id, observed_version) do
    account = ConnectedAccount |> Ash.Query.filter(id == ^account_id) |> Ankole.Ash.read_one!()

    Repo.transact_top_level(fn ->
      with :ok <- check_authority(account),
           %{status: "active"} = config <- Store.lock(config_id),
           %{status: "active"} = row <- Accounts.lock(account_id) do
        now = DateTime.utc_now()

        cond do
          not Accounts.valid?(row) ->
            {:error, :oauth_reauthorization_required}

          expired?(row.refresh_expires_at, now) ->
            expire(row)

          fresh?(row.expires_at) and
              (row.credentials_version != observed_version or
                 not proactive?(row.refresh_expires_at, now)) ->
            {:ok, {:fresh, row}}

          future?(row.refreshing_until, now) ->
            if expired?(row.expires_at, now),
              do: {:error, :oauth_refresh_in_progress},
              else: {:ok, {:fresh, row}}

          row.last_refresh_failure_at && DateTime.diff(now, row.last_refresh_failure_at) < 30 ->
            {:error, :oauth_refresh_cooling_down}

          true ->
            with {:ok, leased} <-
                   Ankole.Ash.update(row, :update, %{
                     refresh_lease_id: Ankole.Authn.SecretDigest.token(),
                     refreshing_until: DateTime.add(now, 30)
                   }),
                 do: {:ok, {config, leased}}
        end
      else
        {:error, _} = error -> error
        _ -> {:error, :oauth_reauthorization_required}
      end
    end)
  end

  defp finish(config, leased, result) do
    Repo.transact_top_level(fn ->
      with %{status: "active", secret_version: version} <- Store.lock(config.id),
           true <- version == config.secret_version,
           %{
             credentials_version: credentials_version,
             refresh_lease_id: lease_id
           } = row <- Accounts.lock(leased.id),
           :ok <- check_refresh_owner(row),
           true <-
             row.status == "active" and credentials_version == leased.credentials_version and
               lease_id == leased.refresh_lease_id do
        finish_result(row, result)
      else
        {:error, _} = error -> error
        _ -> {:error, :oauth_refresh_superseded}
      end
    end)
  end

  defp finish_result(row, {:ok, tokens}) do
    with {:ok, previous} <- Credentials.account_credentials(row),
         tokens = Map.merge(previous, tokens),
         {:ok, sealed} <- Credentials.seal(tokens, "connector_connected_account", row.id),
         {:ok, _} <-
           Ankole.Ash.update(row, :update, %{
             sealed_credentials: sealed,
             credentials_version: row.credentials_version + 1,
             expires_at: Accounts.expiry(tokens, "expires_at", "expires_in"),
             refresh_expires_at:
               Accounts.expiry(tokens, "refresh_expires_at", "refresh_expires_in") ||
                 row.refresh_expires_at,
             refresh_lease_id: nil,
             refreshing_until: nil,
             last_refreshed_at: DateTime.utc_now(),
             last_refresh_failure_at: nil,
             first_refresh_failure_at: nil,
             last_error: nil
           }),
         do: {:ok, tokens["access_token"]}
  end

  defp finish_result(row, {:error, reason}) do
    now = DateTime.utc_now()

    permanent =
      reason in [:invalid_grant, :oauth_reauthorization_required] or
        (row.first_refresh_failure_at &&
           DateTime.diff(now, row.first_refresh_failure_at) > 4 * 86_400)

    with {:ok, _} <-
           Ankole.Ash.update(row, :update, %{
             status: if(permanent, do: "expired", else: "active"),
             refresh_lease_id: nil,
             refreshing_until: nil,
             first_refresh_failure_at: row.first_refresh_failure_at || now,
             last_refresh_failure_at: now,
             last_error: %{
               "code" =>
                 if(permanent, do: "oauth_reauthorization_required", else: "oauth_refresh_failed")
             }
           }) do
      # Commit the failure cooldown even though the external request failed.
      {:ok,
       {:refresh_failed,
        if(permanent, do: :oauth_reauthorization_required, else: :oauth_refresh_failed)}}
    end
  end

  defp expire(row) do
    with {:ok, _} <-
           Ankole.Ash.update(row, :update, %{
             status: "expired",
             refresh_lease_id: nil,
             refreshing_until: nil
           }),
         do: {:ok, {:refresh_failed, :oauth_reauthorization_required}}
  end

  defp check_authority(%{subject_kind: "human"} = row),
    do:
      WorkAccess.check_in_tx(%{
        authorization_kind: "human",
        human_uid: row.owner_principal_uid,
        human_access_version: row.owner_access_version
      })

  defp check_authority(_), do: :ok

  # Renames and offboarding update this locked account in their Principal
  # transaction. Read its current owner without taking a later Principal lock.
  defp check_refresh_owner(%{subject_kind: "human"} = row),
    do: HumanAccess.check(row.owner_principal_uid, row.owner_access_version)

  defp check_refresh_owner(_), do: :ok

  defp fresh?(nil), do: true
  defp fresh?(time), do: DateTime.diff(time, DateTime.utc_now()) > 60
  defp future?(nil, _), do: false
  defp future?(time, now), do: DateTime.compare(time, now) == :gt
  defp expired?(nil, _), do: false
  defp expired?(time, now), do: DateTime.compare(time, now) != :gt
  defp proactive?(nil, _), do: false
  defp proactive?(time, now), do: DateTime.diff(time, now) < 7 * 86_400
end
