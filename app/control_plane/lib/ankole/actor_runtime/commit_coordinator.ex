defmodule Ankole.ActorRuntime.CommitCoordinator do
  @moduledoc """
  Final proposal commit boundary.
  """

  alias Ankole.AIAgent
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.ActorRuntime.CommitCoordinator.ConversationSummary
  alias Ankole.ActorRuntime.CommitCoordinator.FinalProposal
  alias Ankole.ActorRuntime.CommitCoordinator.Payload
  alias Ankole.ActorRuntime.CommitCoordinator.TurnError
  alias Ankole.ActorRuntime.OutboxDispatcher
  alias Ankole.Repo

  @doc """
  Handles a final proposal envelope or body and commits it durably.

  The worker proposes the assistant output, but the control plane is the owner
  of durable truth. Commit writes the transcript, turn result, actor input
  consumption, and provider outbox in one database transaction.
  """
  @spec commit_final_proposal(map()) :: {:ok, map()} | {:error, term()}
  def commit_final_proposal(proposal) when is_map(proposal) do
    proposal = Payload.unwrap_body(proposal, "turn_final_proposal")
    turn_ref = Payload.fetch_map!(proposal, "turn")
    now = DateTime.utc_now(:microsecond)

    Repo.transact(fn repo ->
      with %LlmTurn{} = llm_turn <- AIAgent.lock_turn(repo, Payload.fetch_turn_id(turn_ref)),
           {:ok, result} <- FinalProposal.commit_in_tx(repo, llm_turn, turn_ref, proposal, now) do
        {:ok, result}
      else
        nil -> {:error, :llm_turn_not_found}
        {:error, _reason} = error -> error
      end
    end)
    |> wake_outbox_after_commit()
  end

  @doc """
  Commits a worker-produced conversation summary.

  The worker decides the summary text and the covered message ids. This function
  only validates that the ids belong to the active conversation for the echoed
  turn fence, then writes the summary row and completes the turn transactionally.
  """
  @spec commit_conversation_summary(map()) :: {:ok, map()} | {:error, term()}
  def commit_conversation_summary(request) when is_map(request) do
    turn_ref = Payload.fetch_map!(request, "turn")
    now = DateTime.utc_now(:microsecond)

    Repo.transact(fn repo ->
      with %LlmTurn{} = llm_turn <- AIAgent.lock_turn(repo, Payload.fetch_turn_id(turn_ref)),
           {:ok, result} <-
             ConversationSummary.commit_in_tx(repo, llm_turn, turn_ref, request, now) do
        {:ok, result}
      else
        nil -> {:error, :llm_turn_not_found}
        {:error, _reason} = error -> error
      end
    end)
    |> wake_outbox_after_commit()
  end

  @doc """
  Handles a worker turn.error envelope and releases the actor input for retry.

  A worker error fails the current AI-agent turn and supersedes runtime
  deliveries, but it does not consume the actor input. The next scheduling pass
  can therefore retry the same user-visible work.
  """
  @spec handle_turn_error(map()) :: {:ok, map()} | {:error, term()}
  def handle_turn_error(envelope) when is_map(envelope) do
    payload = Payload.unwrap_body(envelope, "turn_error")
    turn_ref = Payload.fetch_map!(payload, "turn")
    now = DateTime.utc_now(:microsecond)

    Repo.transact(fn repo ->
      with %LlmTurn{} = llm_turn <- AIAgent.lock_turn(repo, Payload.fetch_turn_id(turn_ref)),
           {:ok, result} <- TurnError.handle_in_tx(repo, llm_turn, turn_ref, payload, now) do
        {:ok, result}
      else
        nil -> {:error, :llm_turn_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp wake_outbox_after_commit(result) do
    tap(result, fn
      {:ok, %{status: :committed}} -> OutboxDispatcher.wake()
      _result -> :ok
    end)
  end
end
