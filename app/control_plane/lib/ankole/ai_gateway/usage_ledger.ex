defmodule Ankole.AIGateway.UsageLedger do
  @moduledoc """
  Append-only Agent token ledger behind the Agent token quota.

  One row records the provider usage of one counted round. A request counts when
  it carries an Agent token, so its `subject_type` is `agent`, and it uses the
  `llm` capability. In-process callers such as Brain and compaction pass no
  `subject_type` and never reach the ledger.

  A ledger write failure logs a warning and returns `:ok`. The provider round
  already happened, so failing the response would destroy a delivered answer to
  protect a soft limit.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIGateway.ChatGPTProtocol
  alias Ankole.AIGateway.CredentialAttempts
  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.Logging
  alias Ankole.Repo

  @doc """
  Records one provider round of an Agent request.

  `round` is the streaming terminal event or the non-streaming response body.
  `aggregate_includes_tool_usage?` names a hosted composite round, whose image
  generation tokens do not count. Any other round, capability, or subject type
  is not counted.
  """
  @spec record(map() | nil, String.t() | nil, map(), keyword()) :: :ok
  def record(runtime, subject_type, round, opts \\ [])

  def record(%{"capability" => "llm"} = runtime, "agent", round, opts) when is_map(round) do
    with %{} = response <- counted_round(round),
         %{} = usage <- CredentialAttempts.model_usage(response, opts) do
      insert(runtime, usage)
    else
      _uncounted -> :ok
    end
  end

  def record(_runtime, _subject_type, _round, _opts), do: :ok

  @doc """
  Sums the tokens of one Agent from `window_started_at` onwards.
  """
  @spec window_tokens(String.t(), DateTime.t()) :: non_neg_integer()
  def window_tokens(subject_uid, %DateTime{} = window_started_at) when is_binary(subject_uid) do
    UsageRecord
    |> where([record], record.subject_uid == ^subject_uid)
    |> where([record], record.inserted_at >= ^window_started_at)
    |> select([record], sum(record.input_tokens + record.output_tokens))
    |> Repo.one()
    |> total_tokens()
  end

  defp counted_round(%{"type" => type, "response" => %{} = response})
       when type in ["response.completed", "response.incomplete"],
       do: response

  defp counted_round(%{"status" => status} = response)
       when status in ["completed", "incomplete"],
       do: response

  defp counted_round(_round), do: nil

  defp insert(runtime, usage) do
    attrs = %{
      subject_uid: Map.get(runtime, "subject_uid"),
      origin: origin(runtime),
      model: "#{Map.get(runtime, "provider_id")}/#{Map.get(runtime, "model")}",
      input_tokens: tokens(usage, "input_tokens"),
      output_tokens: tokens(usage, "output_tokens")
    }

    write(attrs)
  end

  defp write(attrs) do
    case %UsageRecord{} |> UsageRecord.changeset(attrs) |> Repo.insert() do
      {:ok, _record} -> :ok
      {:error, changeset} -> write_failed(attrs, inspect(changeset.errors))
    end
  rescue
    error -> write_failed(attrs, Exception.message(error))
  end

  defp write_failed(attrs, reason) do
    Logging.warning(
      "ai_gateway.usage_ledger.write_failed",
      "agent token usage row not recorded",
      %{subject_uid: attrs.subject_uid, reason: reason}
    )

    :ok
  end

  # A Background Agent Job reaches AIGateway through the Codex client, which
  # declares its own client identity headers. A Worker turn declares none.
  defp origin(runtime) do
    if ChatGPTProtocol.codex_client?(Map.get(runtime, "request_context", %{})),
      do: "codex",
      else: "agent"
  end

  defp tokens(usage, key) do
    case Map.get(usage, key) do
      value when is_integer(value) and value >= 0 -> value
      _absent -> 0
    end
  end

  defp total_tokens(nil), do: 0
  defp total_tokens(%Decimal{} = total), do: Decimal.to_integer(total)
  defp total_tokens(total) when is_integer(total), do: total
end
