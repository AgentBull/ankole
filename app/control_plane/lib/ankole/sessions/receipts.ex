defmodule Ankole.Sessions.Receipts do
  @moduledoc """
  Commits a control-plane tool result with its domain write.

  The tape takes ownership of these results when it records the whole round.
  A takeover can then recover committed writes without repeating them. A
  transaction-scoped advisory lock on the receipt identity serializes two
  executions of one call, so the second one reads the committed receipt.
  `Ankole.Sessions.Receipt` keeps the results.
  """

  require Ash.Query

  alias Ankole.Sessions.Fence
  alias Ankole.Sessions.Queue
  alias Ankole.Sessions.Receipt

  def execute(run, response_id, call_id, operation) do
    :telemetry.execute([:ankole, :sessions, :receipt, :execute], %{}, %{
      agent_uid: run.agent_uid,
      session_id: run.session_id,
      response_id: response_id,
      call_id: call_id
    })

    with {:ok, {receipt, _after_commit}} <-
           Ankole.Repo.transact_top_level(
             fn -> execute_in_tx(run, response_id, call_id, operation) end,
             after_commit: {__MODULE__, :publish_committed}
           )
           |> Ankole.Errors.reason(),
         do: {:ok, receipt}
  end

  @doc false
  def execute_in_tx(run, response_id, call_id, operation) do
    Ankole.AdvisoryLock.lock!(Ankole.Repo, "session-receipt:" <> response_id <> ":" <> call_id)

    with :ok <- Fence.current_in_tx(run) do
      case Ankole.Ash.read_one!(identity_query(response_id, call_id)) do
        %Receipt{} = receipt ->
          with :ok <- Fence.check_in_tx(run, :share),
               do: {:ok, {receipt, []}}

        nil ->
          with {:ok, sessions, commit} <- operation.(),
               :ok <- Queue.lock_sessions_in_tx(sessions),
               :ok <- Fence.check_in_tx(run, :share) do
            commit_in_tx(run, response_id, call_id, commit)
          end
      end
    end
  end

  @doc "Runs the notifications of a committed receipt."
  def publish_committed({_receipt, after_commit}),
    do: Enum.each(after_commit, &run_after_commit/1)

  # Notifications cannot change the result of an already committed operation.
  defp run_after_commit(action) do
    action.()
  rescue
    error -> log_notification_failure(:error, error, __STACKTRACE__)
  catch
    kind, reason -> log_notification_failure(kind, reason, __STACKTRACE__)
  end

  defp log_notification_failure(kind, reason, stacktrace) do
    Ankole.Logging.error(
      "sessions.receipt.notification_failed",
      "Committed receipt notification failed",
      Ankole.Logging.failure_fields(kind, reason, stacktrace)
    )
  end

  def fetch(response_id, call_id) do
    case Ankole.Ash.read_one!(identity_query(response_id, call_id)) do
      nil -> {:error, :receipt_not_found}
      receipt -> {:ok, receipt}
    end
  end

  def delete_round_in_tx(run, response_id) do
    Receipt
    |> Ash.Query.filter(agent_uid == ^run.agent_uid and session_id == ^run.session_id)
    |> Ash.Query.filter(response_id == ^response_id)
    |> discard_in_tx()
  end

  def delete_run_in_tx(run) do
    Receipt
    |> Ash.Query.filter(agent_uid == ^run.agent_uid and session_id == ^run.session_id)
    |> discard_in_tx()
  end

  defp commit_in_tx(run, response_id, call_id, operation) do
    with {:ok, result, after_commit} <- operation.(),
         {:ok, receipt} <-
           Ankole.Ash.create(Receipt, :commit_result, %{
             response_id: response_id,
             call_id: call_id,
             agent_uid: run.agent_uid,
             session_id: run.session_id,
             result: Ankole.Sessions.ToolResult.encode(result)
           }) do
      {:ok, {receipt, after_commit}}
    end
  end

  defp identity_query(response_id, call_id) do
    Receipt
    |> Ash.Query.filter(response_id == ^response_id and call_id == ^call_id)
  end

  defp discard_in_tx(query) do
    {:ok, _discarded} = Ankole.Ash.destroy_where(query, :discard)
    :ok
  end
end
