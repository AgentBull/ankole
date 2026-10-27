defmodule Ankole.OIDC.CodeStore do
  @moduledoc false
  @behaviour Attesto.CodeStore
  require Ash.Query
  alias Ankole.OIDC.AuthorizationCode

  # Each callback is one statement, or a read after a refused write, so it
  # runs in the transaction of its caller or alone.

  @impl true
  def put(%{code_hash: digest, data: data, expires_at: expiry}) do
    case Ankole.Ash.create(AuthorizationCode, :issue_in_tx, %{
           digest: digest,
           client_id: data.client_id,
           principal_uid: data.subject,
           redirect_uri: data.redirect_uri,
           scope: Enum.join(data.scope, " "),
           code_challenge: data.code_challenge,
           nonce: data.claims["nonce"],
           auth_time: data.claims["auth_time"],
           session_id: data.claims["session_id"],
           expires_at: timestamp(expiry)
         }) do
      {:ok, _} -> :ok
      {:error, error} -> raise error
    end
  end

  @impl true
  def take(digest) do
    query = AuthorizationCode |> Ash.Query.filter(digest == ^digest)

    case Ankole.Ash.update_atomic(query, :consume_in_tx, %{at: DateTime.utc_now()}) do
      {:ok, row} ->
        {:ok, entry(row)}

      {:error, error} = result ->
        case Ankole.Errors.reason(result) do
          {:error, :stale} -> consumed(Ankole.Ash.read_one!(query))
          _ -> raise error
        end
    end
  end

  @impl true
  def mark_consumed(digest, meta) do
    deadline = meta[:replay_retain_until] || System.system_time(:second) + 1800

    {:ok, _row} =
      AuthorizationCode
      |> Ash.Query.filter(digest == ^digest)
      |> Ankole.Ash.update_atomic(:finalize_in_tx, %{
        family_id: meta[:family_id],
        replay_retain_until: timestamp(deadline)
      })

    :ok
  end

  defp consumed(%{finalized: true} = row) do
    {:error, :consumed,
     %{
       family_id: row.family_id,
       subject: row.principal_uid,
       session_id: row.session_id,
       replay_retain_until: DateTime.to_unix(row.replay_retain_until)
     }}
  end

  defp consumed(_), do: :error

  defp entry(row) do
    %{
      code_hash: row.digest,
      expires_at: DateTime.to_unix(row.expires_at),
      data: %{
        client_id: row.client_id,
        redirect_uri: row.redirect_uri,
        subject: row.principal_uid,
        code_challenge: row.code_challenge,
        scope: String.split(row.scope, " ", trim: true),
        resource: [],
        dpop_jkt: nil,
        family_id: nil,
        claims: %{
          "session_id" => row.session_id,
          "nonce" => row.nonce,
          "auth_time" => row.auth_time
        }
      }
    }
  end

  defp timestamp(seconds),
    do: DateTime.from_unix!(seconds * 1_000_000, :microsecond)
end
