defmodule Ankole.ActorRuntime.Jobs.CleanupSubagentHomes do
  @moduledoc """
  Deletes durable Codex homes seven days after a delegation reaches terminal.

  User deliverables live under `user_files` and are deliberately untouched.
  The durable relative home path is recorded by the worker so this job does not
  need to reproduce worker filesystem path encoding.
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  alias Ankole.ActorRuntime.FileTransferLane
  alias Ankole.ActorRuntime.WorkerPool
  alias Ankole.SubagentDelegations

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    with {:ok, route} <- WorkerPool.file_worker_route() do
      SubagentDelegations.cleanup_candidates()
      |> Enum.reduce_while(:ok, fn delegation, :ok ->
        path = delegation.metadata["codex_home_relative_path"]

        case FileTransferLane.delete(route, "workspace_sessions", path, recursive: true) do
          {:ok, _result} ->
            case SubagentDelegations.mark_codex_home_cleaned(delegation.id) do
              {:ok, _delegation} -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end
end
