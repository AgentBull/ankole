defmodule Ankole.Sessions.Receipts do
  @moduledoc """
  Commits a control-plane tool result with its domain write.

  The tape takes ownership of these results when it records the whole round.
  A takeover can then recover committed writes without repeating them.
  """

  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Sessions.Domain
  require Ash.Query

  alias Ankole.Sessions.Fence
  alias Ankole.Sessions.Queue
  alias Ankole.Repo

  @identity_constraint "session_tool_receipts_pkey"

  postgres do
    table("session_tool_receipts")
    repo(Ankole.Repo)
    migrate?(false)
    unique_index_names([{[:response_id, :call_id], @identity_constraint}])
    foreign_key_names([{:agent_uid, "session_tool_receipts_agent_uid_fkey"}])

    check_constraints do
      check_constraint(:result, "session_tool_receipts_result_object")
    end
  end

  attributes do
    attribute(:response_id, :string,
      primary_key?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:call_id, :string,
      primary_key?: true,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:agent_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
    attribute(:session_id, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:result, Ankole.Ash.Types.JSONMap, allow_nil?: false)
    create_timestamp(:inserted_at, type: :utc_datetime_usec)
  end

  actions do
    defaults([:read])

    create :commit_result do
      primary?(true)
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)
      accept([:response_id, :call_id, :agent_uid, :session_id, :result])
    end

    destroy :discard do
      transaction?(false)
      require_atomic?(true)
      change(Ankole.Ash.RequireTransaction.Atomic)
    end
  end

  def execute(run, response_id, call_id, operation) do
    Repo.assert_outside_transaction!()

    :telemetry.execute([:ankole, :sessions, :receipt, :execute], %{}, %{
      agent_uid: run.agent_uid,
      session_id: run.session_id,
      response_id: response_id,
      call_id: call_id
    })

    result =
      Repo.transact(fn repo ->
        with :ok <- Fence.current_in_tx(repo, run) do
          case Ankole.Ash.read_one!(identity_query(response_id, call_id)) do
            %__MODULE__{} = receipt ->
              with :ok <- Fence.check_in_tx(repo, run, :share),
                   do: {:ok, {receipt, []}}

            nil ->
              with {:ok, sessions, commit} <- operation.(repo),
                   :ok <-
                     Queue.lock_sessions_in_tx(repo, sessions),
                   :ok <- Fence.check_in_tx(repo, run, :share) do
                commit_in_tx(repo, run, response_id, call_id, commit)
              end
          end
        end
      end)

    case result do
      {:ok, {receipt, after_commit}} ->
        Enum.each(after_commit, &run_after_commit/1)
        {:ok, receipt}

      {:error, %Ash.Error.Invalid{errors: errors} = error} ->
        if receipt_conflict?(errors) do
          fetch(response_id, call_id)
        else
          {:error, error}
        end

      {:error, _reason} = error ->
        error
    end
  end

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

  def delete_round_in_tx(_repo, run, response_id) do
    __MODULE__
    |> Ash.Query.filter(agent_uid == ^run.agent_uid and session_id == ^run.session_id)
    |> Ash.Query.filter(response_id == ^response_id)
    |> discard_in_tx()
  end

  def delete_run_in_tx(_repo, run) do
    __MODULE__
    |> Ash.Query.filter(agent_uid == ^run.agent_uid and session_id == ^run.session_id)
    |> discard_in_tx()
  end

  defp commit_in_tx(_repo, run, response_id, call_id, operation) do
    with {:ok, result, after_commit} <- operation.(),
         {:ok, receipt} <-
           Ankole.Ash.create(__MODULE__, :commit_result, %{
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
    __MODULE__
    |> Ash.Query.filter(response_id == ^response_id and call_id == ^call_id)
  end

  defp receipt_conflict?(errors) do
    Enum.any?(errors, fn
      %Ash.Error.Changes.InvalidAttribute{private_vars: vars} ->
        vars[:constraint_type] == :unique and vars[:constraint] == @identity_constraint

      _error ->
        false
    end)
  end

  defp discard_in_tx(query) do
    case Ankole.Ash.bulk_destroy(query, :discard, %{}, strategy: [:atomic], return_errors?: true) do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> raise Ash.Error.to_error_class(errors)
    end
  end
end
