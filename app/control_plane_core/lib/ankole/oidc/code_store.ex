defmodule Ankole.OIDC.CodeStore do
  @moduledoc false
  @behaviour Attesto.CodeStore
  require Ash.Query
  alias Ankole.OIDC.AuthorizationCode
  alias Ankole.Repo

  @impl true
  def put(%{code_hash: digest, data: data, expires_at: expiry}) do
    case Repo.transact(fn ->
           Ankole.Ash.create(AuthorizationCode, :issue_in_tx, %{
             digest: digest,
             client_id: data.client_id,
             principal_uid: data.subject,
             redirect_uri: data.redirect_uri,
             scope: Enum.join(data.scope, " "),
             code_challenge: data.code_challenge,
             nonce: data.claims["nonce"],
             session_id: data.claims["session_id"],
             expires_at: timestamp(expiry)
           })
         end) do
      {:ok, _} -> :ok
      {:error, error} -> raise Ash.Error.to_error_class(error)
    end
  end

  @impl true
  def take(digest) do
    {:ok, result} =
      Repo.transact(fn ->
        query = AuthorizationCode |> Ash.Query.filter(digest == ^digest)

        case Ankole.Ash.bulk_update(query, :consume_in_tx, %{at: DateTime.utc_now()},
               strategy: [:atomic],
               return_records?: true,
               return_errors?: true
             ) do
          %Ash.BulkResult{status: :success, records: [row]} ->
            {:ok, {:ok, entry(row)}}

          %Ash.BulkResult{status: :success, records: []} ->
            {:ok, consumed(Ankole.Ash.read_one!(query))}

          %Ash.BulkResult{errors: errors} ->
            {:error, Ash.Error.to_error_class(errors)}
        end
      end)

    result
  end

  @impl true
  def mark_consumed(digest, meta) do
    deadline = meta[:replay_retain_until] || System.system_time(:second) + 1800

    {:ok, :ok} =
      Repo.transact(fn ->
        query = AuthorizationCode |> Ash.Query.filter(digest == ^digest)

        case Ankole.Ash.bulk_update(
               query,
               :finalize_in_tx,
               %{
                 family_id: meta[:family_id],
                 replay_retain_until: timestamp(deadline)
               },
               strategy: [:atomic],
               return_records?: true,
               return_errors?: true
             ) do
          %Ash.BulkResult{status: :success, records: [_row]} -> {:ok, :ok}
          %Ash.BulkResult{status: :success, records: []} -> {:error, :code_not_consumed}
          %Ash.BulkResult{errors: errors} -> {:error, Ash.Error.to_error_class(errors)}
        end
      end)

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
        claims: %{"session_id" => row.session_id, "nonce" => row.nonce}
      }
    }
  end

  defp timestamp(seconds),
    do: DateTime.from_unix!(seconds * 1_000_000, :microsecond)
end
