defmodule Ankole.OIDC.RefreshStore do
  @moduledoc false
  @behaviour Attesto.RefreshStore
  import Ecto.Query
  require Ash.Query
  alias Ankole.{OIDC, Repo, SecretKeyBase}
  alias Ankole.OIDC.{RefreshToken, RefreshTokenFamily, Session, Sessions}

  @context_keys ~w(subject scope resource client_id dpop_jkt acr auth_time claims family_expires_at attestation_jkt)a

  @impl true
  def insert(entry) do
    Repo.transact(fn ->
      with :ok <-
             Sessions.lock_credential_parents_in_tx(
               entry.data.subject,
               entry.data.client_id,
               entry.data.claims["session_id"]
             ),
           {:ok, _family} <- ensure_family(entry),
           {:ok, _} <- insert_token(entry) do
        {:ok, :ok}
      else
        {:error, :family_revoked} = error -> error
        {:error, _} -> {:error, :conflict}
      end
    end)
    |> result()
  end

  @impl true
  def get(digest) do
    case Repo.one(
           from(t in RefreshToken,
             join: f in RefreshTokenFamily,
             on: f.id == t.family_id,
             where: t.digest == ^digest and is_nil(f.revoked_at),
             select: t
           )
         ) do
      nil -> :error
      row -> {:ok, entry(redact_successor(row, DateTime.utc_now(:microsecond)))}
    end
  end

  def redact_expired_successors(now) do
    redact_successors(RefreshToken, now)
  end

  defp redact_successor(%{successor_ciphertext: nil} = row, _now), do: row

  defp redact_successor(row, now) do
    if DateTime.compare(row.successor_retry_until, now) == :lt do
      %{row | successor_ciphertext: nil}
    else
      row
    end
  end

  defp redact_successors(query, now) do
    {:ok, :ok} =
      Repo.transact(fn ->
        case Ankole.Ash.bulk_update(query, :redact_successor_in_tx, %{at: now},
               strategy: [:atomic],
               return_errors?: true
             ) do
          %Ash.BulkResult{status: :success} -> {:ok, :ok}
          %Ash.BulkResult{errors: errors} -> {:error, Ash.Error.to_error_class(errors)}
        end
      end)

    :ok
  end

  @impl true
  def rotate(digest, child, successor, opts) do
    now = Keyword.fetch!(opts, :now)

    with {:ok, ciphertext} <-
           OIDC.seal(Ankole.JSON.encode!(successor), "refresh_successor", digest) do
      Repo.transact(fn -> rotate_in_tx(digest, child, successor, ciphertext, now) end)
      |> result()
    else
      _ -> {:error, :retry_state_unavailable}
    end
  end

  defp rotate_in_tx(digest, child, successor, ciphertext, now) do
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
      Repo.one(
        from(f in RefreshTokenFamily,
          where: f.id == ^child.family_id and f.session_id == ^child.data.claims["session_id"],
          lock: "FOR UPDATE"
        )
      )

    parent = Repo.one(from(t in RefreshToken, where: t.digest == ^digest, lock: "FOR UPDATE"))

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
    case Repo.get_by(RefreshToken, family_id: child.family_id, generation: child.generation) do
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
        :ok = revoke_family(child.family_id)
        {:ok, {:error, :family_integrity_error}}
    end
  end

  @impl true
  def revoke_family(nil), do: :ok

  def revoke_family(id) do
    {:ok, :ok} =
      Repo.transact(fn ->
        with {subject, client_id, session_id} <- family_context(id),
             :ok <- Sessions.lock_credential_parents_in_tx(subject, client_id, session_id),
             %RefreshTokenFamily{} = family <-
               Repo.one(from(f in RefreshTokenFamily, where: f.id == ^id, lock: "FOR UPDATE")) do
          {:ok, _} = Ankole.Ash.update(family, :revoke_in_tx, %{})

          case RefreshToken
               |> Ash.Query.filter(family_id == ^id)
               |> Ankole.Ash.bulk_destroy(:remove_in_tx, %{},
                 strategy: [:atomic],
                 return_errors?: true
               ) do
            %Ash.BulkResult{status: :success} -> :ok
            %Ash.BulkResult{errors: errors} -> Repo.rollback(Ash.Error.to_error_class(errors))
          end

          {:ok, _} = Sessions.revoke(family.session_id)
        end

        {:ok, :ok}
      end)

    :ok
  end

  defp family_context(id) do
    Repo.one(
      from(f in RefreshTokenFamily,
        join: s in Session,
        on: s.id == f.session_id,
        where: f.id == ^id,
        select: {s.principal_uid, s.client_id, s.id}
      )
    )
  end

  defp ensure_family(entry) do
    case Repo.one(
           from(f in RefreshTokenFamily, where: f.id == ^entry.family_id, lock: "FOR UPDATE")
         ) do
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
