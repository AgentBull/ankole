defmodule Ankole.OIDC.RefreshStore do
  @moduledoc false
  @behaviour Attesto.RefreshStore
  require Ash.Query
  alias Ankole.{OIDC, Repo, SecretKeyBase}
  alias Ankole.OIDC.{RefreshToken, RefreshTokenFamily, Sessions}

  @context_keys ~w(subject scope resource client_id dpop_jkt acr auth_time claims family_expires_at attestation_jkt)a

  # Attesto inserts the first token of a family when the authorization code
  # exchange finalizes the code, so this callback runs in that transaction.
  @impl true
  def insert(entry) do
    unless Repo.in_transaction?(),
      do:
        raise(Ankole.Errors.Framework.TransactionRequired,
          operation: {__MODULE__, :insert}
        )

    with :ok <-
           Sessions.lock_credential_parents_in_tx(
             entry.data.subject,
             entry.data.client_id,
             entry.data.claims["session_id"]
           ),
         {:ok, _family} <- ensure_family(entry),
         {:ok, _} <- insert_token(entry) do
      :ok
    else
      {:error, :family_revoked} = error -> error
      {:error, _} -> {:error, :conflict}
    end
  end

  @impl true
  def get(digest) do
    case RefreshToken
         |> Ash.Query.filter(digest == ^digest and exists(family, is_nil(revoked_at)))
         |> Ankole.Ash.read_one!() do
      nil -> :error
      row -> {:ok, entry(redact_successor(row, DateTime.utc_now(:microsecond)))}
    end
  end

  def redact_expired_successors(now) do
    {:ok, _rows} = Ankole.Ash.update_where(RefreshToken, :redact_successor_in_tx, %{at: now})
    :ok
  end

  defp redact_successor(%{successor_ciphertext: nil} = row, _now), do: row

  defp redact_successor(row, now) do
    if DateTime.compare(row.successor_retry_until, now) == :lt do
      %{row | successor_ciphertext: nil}
    else
      row
    end
  end

  @impl true
  def rotate(digest, child, successor, opts) do
    now = Keyword.fetch!(opts, :now)

    with {:ok, ciphertext} <-
           OIDC.seal(Ankole.JSON.encode!(successor), "refresh_successor", digest) do
      Ankole.Ash.run_action(RefreshToken, :rotate, %{
        digest: digest,
        child: child,
        successor: successor,
        ciphertext: ciphertext,
        now: now
      })
      |> result()
    else
      _ -> {:error, :retry_state_unavailable}
    end
  end

  @doc false
  def rotate_in_tx(digest, child, successor, ciphertext, now) do
    with :ok <-
           Sessions.lock_credential_parents_in_tx(
             child.data.subject,
             child.data.client_id,
             child.data.claims["session_id"]
           ) do
      rotate_locked(digest, child, successor, ciphertext, now)
    else
      {:error, :context_unavailable} -> {:ok, :error}
    end
  end

  defp rotate_locked(digest, child, successor, ciphertext, now) do
    family =
      RefreshTokenFamily
      |> Ash.Query.filter(
        id == ^child.family_id and session_id == ^child.data.claims["session_id"]
      )
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read_one!()

    parent =
      RefreshToken
      |> Ash.Query.filter(digest == ^digest)
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read_one!()

    cond do
      is_nil(family) or is_nil(parent) ->
        {:ok, :error}

      not is_nil(family.revoked_at) ->
        {:ok, {:error, :family_revoked}}

      parent.family_id != child.family_id ->
        {:ok, {:error, :invalid_rotation}}

      not is_nil(parent.consumed_at) ->
        {:ok, {:reuse, entry(parent)}}

      DateTime.to_unix(family.family_expires_at) <= now or
          DateTime.to_unix(parent.expires_at) <= now ->
        {:ok, {:error, :expired}}

      true ->
        commit_rotation(parent, child, successor, ciphertext, now)
    end
  end

  defp commit_rotation(parent, child, successor, ciphertext, now) do
    case RefreshToken
         |> Ash.Query.filter(family_id == ^child.family_id and generation == ^child.generation)
         |> Ankole.Ash.read_one!() do
      nil ->
        with {:ok, _} <- insert_token(child),
             {:ok, updated} <-
               Ankole.Ash.update(parent, :consume_in_tx, %{
                 at: timestamp(now),
                 successor_ciphertext: ciphertext,
                 successor_retry_until: timestamp(successor.retry_until)
               }) do
          {:ok, {:ok, entry(updated), child}}
        else
          {:error, _} -> {:error, :token_conflict}
        end

      _ ->
        :ok = revoke_family_in_tx(child.family_id)
        {:ok, {:error, :family_integrity_error}}
    end
  end

  @impl true
  def revoke_family(nil), do: :ok

  def revoke_family(id) do
    {:ok, :ok} = Ankole.Ash.run_action(RefreshTokenFamily, :revoke_family, %{id: id})
    :ok
  end

  @doc false
  def revoke_family_in_tx(id) do
    with {subject, client_id, session_id} <- family_context(id),
         :ok <- Sessions.lock_credential_parents_in_tx(subject, client_id, session_id),
         %RefreshTokenFamily{} = family <-
           RefreshTokenFamily
           |> Ash.Query.filter(id == ^id)
           |> Ash.Query.lock(:for_update)
           |> Ankole.Ash.read_one!() do
      {:ok, _} = Ankole.Ash.update(family, :revoke_in_tx, %{})

      {:ok, _} =
        RefreshToken
        |> Ash.Query.filter(family_id == ^id)
        |> Ankole.Ash.destroy_where(:remove_in_tx)

      {:ok, _} = Sessions.revoke(family.session_id)
    end

    :ok
  end

  defp family_context(id) do
    case RefreshTokenFamily
         |> Ash.Query.filter(id == ^id)
         |> Ash.Query.load(:session)
         |> Ankole.Ash.read_one!() do
      %{session: %{} = session} -> {session.principal_uid, session.client_id, session.id}
      _ -> nil
    end
  end

  defp ensure_family(entry) do
    case RefreshTokenFamily
         |> Ash.Query.filter(id == ^entry.family_id)
         |> Ash.Query.lock(:for_update)
         |> Ankole.Ash.read_one!() do
      %{revoked_at: revoked} when not is_nil(revoked) ->
        {:error, :family_revoked}

      %RefreshTokenFamily{} = family ->
        {:ok, family}

      nil ->
        Ankole.Ash.create(RefreshTokenFamily, :issue_in_tx, %{
          id: entry.family_id,
          session_id: entry.data.claims["session_id"],
          family_expires_at: timestamp(entry.data.family_expires_at)
        })
    end
  end

  defp insert_token(entry) do
    Ankole.Ash.create(RefreshToken, :issue_in_tx, %{
      digest: entry.token_hash,
      family_id: entry.family_id,
      generation: entry.generation,
      client_id: entry.data.client_id,
      principal_uid: entry.data.subject,
      session_id: entry.data.claims["session_id"],
      scope: Enum.join(entry.data.scope, " "),
      context: entry.data,
      expires_at: timestamp(entry.expires_at)
    })
  end

  defp entry(row) do
    %{
      token_hash: row.digest,
      family_id: row.family_id,
      generation: row.generation,
      data: context(row.context),
      expires_at: DateTime.to_unix(row.expires_at),
      consumed: not is_nil(row.consumed_at),
      consumed_at: unix(row.consumed_at),
      successor: successor(row)
    }
  end

  defp successor(%{consumed_at: nil}), do: nil

  defp successor(%{successor_ciphertext: nil, successor_retry_until: deadline}),
    do: %{retry_until: DateTime.to_unix(deadline), recoverable: false}

  defp successor(row) do
    {:ok, json} =
      SecretKeyBase.unseal(row.successor_ciphertext, "oidc", ["refresh_successor", row.digest])

    decoded = Ankole.JSON.decode!(json)

    if decoded["recoverable"] == false do
      %{retry_until: decoded["retry_until"], recoverable: false}
    else
      %{
        token: decoded["token"],
        generation: decoded["generation"],
        retry_until: decoded["retry_until"],
        context: context(decoded["context"])
      }
    end
  end

  defp context(map),
    do:
      Map.new(@context_keys, fn key -> {key, Map.get(map, Atom.to_string(key))} end)
      |> Map.reject(fn {key, value} ->
        key in [:family_expires_at, :attestation_jkt] and is_nil(value)
      end)

  defp unix(nil), do: nil
  defp unix(time), do: DateTime.to_unix(time)

  defp timestamp(seconds),
    do: DateTime.from_unix!(seconds * 1_000_000, :microsecond)

  defp result({:ok, value}), do: value
  defp result({:error, reason}), do: {:error, reason}
end
