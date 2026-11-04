defmodule Ankole.Connectors.Jobs.CloudAccount do
  @moduledoc "Commits cloud account cleanup and reauthorization after the Pod account transaction."
  use Ankole.Job, tenancy: :tenant, queue: :default, max_attempts: 10
  alias Ankole.Connectors.{Accounts, CloudProvider, Triggers}
  alias Ankole.Repo

  @impl Ankole.Job
  def run(%Oban.Job{args: %{"operation" => operation} = args}) do
    result =
      case operation do
        "claim" -> claim(args)
        "revoke" -> CloudProvider.revoke_account(Map.delete(args, "operation"))
      end

    case result do
      {:ok, _} -> :ok
      :ok -> :ok
      error -> error
    end
  end

  defp claim(args) do
    with {:ok, account} <- Accounts.get_by_id(args["local_account_id"]) do
      case account do
        %{status: "active", upstream_connection_id: id} when is_binary(id) ->
          request =
            args
            |> Map.drop(["operation", "local_account_id"])
            |> Map.put("upstream_connection_id", id)

          with {:ok, _} <- CloudProvider.claim_account(request),
               do: resume_subscriptions(account.id, id)

        _ ->
          [args["upstream_connection_id"], args["previous_upstream_connection_id"]]
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.reduce_while({:ok, %{}}, fn id, _ ->
            case CloudProvider.revoke_account(%{"upstream_connection_id" => id}) do
              {:ok, _} -> {:cont, {:ok, %{}}}
              error -> {:halt, error}
            end
          end)
      end
    end
  end

  defp resume_subscriptions(account_id, upstream_id) do
    Repo.transact_top_level(fn ->
      case Accounts.lock(account_id) do
        %{status: "active", upstream_connection_id: ^upstream_id} ->
          {:ok, Triggers.reauthorize_account_in_tx(account_id)}

        _ ->
          {:ok, :ok}
      end
    end)
  end
end
