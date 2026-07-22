defmodule Ankole.Brain.Jobs.EnqueuePrincipalDreaming do
  @moduledoc "Enqueues one Stage B microbatch after silence or backlog makes it eligible."

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ankole.Brain.Config
  alias Ankole.Brain.Dreaming.StageB
  alias Ankole.Brain.Jobs.CuratePrincipal
  alias Ankole.Principals

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    now = parse_now(Map.get(args, "now"))

    Principals.list_active_agents()
    |> Enum.reduce_while(:ok, fn %{agent: agent}, :ok ->
      case maybe_enqueue(agent.uid, now) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_enqueue(uid, now) do
    with {:ok, %{"enabled" => true} = config} <- Config.dreaming(uid),
         true <- StageB.eligible?(uid, config, now) do
      case uid |> then(&%{"principal_uid" => &1}) |> CuratePrincipal.new() |> Oban.insert() do
        {:ok, _job} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, %{"enabled" => false}} -> :ok
      false -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_now(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _invalid -> DateTime.utc_now(:microsecond)
    end
  end

  defp parse_now(_value), do: DateTime.utc_now(:microsecond)
end
