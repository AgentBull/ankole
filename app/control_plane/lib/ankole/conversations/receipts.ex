defmodule Ankole.Conversations.Receipts do
  @moduledoc """
  Commits a control-plane tool result with its domain write.

  The tape takes ownership of these results when it records the whole round.
  A takeover can then recover committed writes without repeating them.
  """

  require Logger

  use Ankole.Schema, tenancy: :tenant
  import Ecto.Changeset
  import Ecto.Query

  alias Ankole.Conversations.Fence
  alias Ankole.Repo

  @primary_key false
  schema "conversation_tool_receipts" do
    field :response_id, :string, primary_key: true
    field :call_id, :string, primary_key: true
    field :agent_uid, Ankole.Ecto.PrincipalKey
    field :session_id, :string
    field :result, :map
    field :inserted_at, :utc_datetime_usec
  end

  def execute(run, response_id, call_id, operation) do
    :telemetry.execute([:ankole, :conversations, :receipt, :execute], %{}, %{
      agent_uid: run.agent_uid,
      session_id: run.session_id,
      response_id: response_id,
      call_id: call_id
    })

    result =
      Repo.transact(fn repo ->
        with :ok <- Fence.check_in_tx(repo, run, :share) do
          case repo.get_by(__MODULE__, response_id: response_id, call_id: call_id) do
            %__MODULE__{} = receipt -> {:ok, {receipt, []}}
            nil -> commit_in_tx(repo, run, response_id, call_id, operation)
          end
        end
      end)

    case result do
      {:ok, {receipt, after_commit}} ->
        Enum.each(after_commit, &run_after_commit/1)
        {:ok, receipt}

      {:error, %Ecto.Changeset{} = changeset} ->
        if Keyword.has_key?(changeset.errors, :response_id) do
          fetch(response_id, call_id)
        else
          {:error, changeset}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # Notifications cannot change the result of an already committed operation.
  defp run_after_commit(action) do
    action.()
  rescue
    error -> Logger.error(Exception.format(:error, error, __STACKTRACE__))
  catch
    kind, reason -> Logger.error(Exception.format(kind, reason, __STACKTRACE__))
  end

  def fetch(response_id, call_id) do
    case Repo.get_by(__MODULE__, response_id: response_id, call_id: call_id) do
      nil -> {:error, :receipt_not_found}
      receipt -> {:ok, receipt}
    end
  end

  def delete_round_in_tx(repo, run, response_id) do
    __MODULE__
    |> where([r], r.agent_uid == ^run.agent_uid and r.session_id == ^run.session_id)
    |> where([r], r.response_id == ^response_id)
    |> repo.delete_all()
  end

  def delete_run_in_tx(repo, run) do
    __MODULE__
    |> where([r], r.agent_uid == ^run.agent_uid and r.session_id == ^run.session_id)
    |> repo.delete_all()
  end

  defp commit_in_tx(repo, run, response_id, call_id, operation) do
    with {:ok, result, after_commit} <- operation.(repo),
         {:ok, receipt} <-
           %__MODULE__{}
           |> change(%{
             response_id: response_id,
             call_id: call_id,
             agent_uid: run.agent_uid,
             session_id: run.session_id,
             result: Ankole.Conversations.ToolResult.encode(result),
             inserted_at: DateTime.utc_now(:microsecond)
           })
           |> unique_constraint(:response_id, name: :conversation_tool_receipts_pkey)
           |> check_constraint(:result, name: :conversation_tool_receipts_result_object)
           |> repo.insert() do
      {:ok, {receipt, after_commit}}
    end
  end
end
