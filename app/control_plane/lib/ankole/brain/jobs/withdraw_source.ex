defmodule Ankole.Brain.Jobs.WithdrawSource do
  @moduledoc false

  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [fields: [:args, :worker], keys: [:document_id], period: 86_400]

  alias Ankole.Brain.SourceWithdrawal

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"document_id" => document_id}}) when is_binary(document_id) do
    case SourceWithdrawal.withdraw(document_id) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_source_withdrawal_job}
end
