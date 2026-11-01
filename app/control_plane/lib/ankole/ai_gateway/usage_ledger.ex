defmodule Ankole.AIGateway.UsageLedger do
  @moduledoc """
  Append-only token ledger for Agent and control-plane LLM calls.

  Explicit subject credentials determine the origin before internal caller
  labels. Only Agent and Codex rows count toward Agent token quota windows;
  Brain, Applet, OIDC Human, and automatic compaction rows remain ledger-only.
  A ledger write failure never discards an already delivered provider response.
  """

  require Ash.Query

  alias Ankole.AIGateway.ChatGPTProtocol
  alias Ankole.AIGateway.CredentialAttempts
  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.Logging

  @doc "Records one completed provider round of a classified LLM request."
  @spec record(map() | nil, String.t() | nil, map(), keyword()) :: :ok
  def record(runtime, subject_type, round, opts \\ [])

  def record(%{"capability" => "llm"} = runtime, subject_type, round, opts)
      when is_map(round) do
    with origin when not is_nil(origin) <-
           origin(runtime, subject_type, Keyword.get(opts, :caller)),
         %{} = response <- counted_round(round),
         %{} = usage <- CredentialAttempts.model_usage(response, opts) do
      insert(runtime, usage, origin)
    else
      _uncounted -> :ok
    end
  end

  def record(_runtime, _subject_type, _round, _opts), do: :ok

  @doc "Sums Agent and Codex tokens from `window_started_at` onwards."
  @spec window_tokens(String.t(), DateTime.t()) :: non_neg_integer()
  def window_tokens(subject_uid, %DateTime{} = window_started_at) when is_binary(subject_uid) do
    totals =
      UsageRecord
      |> Ash.Query.filter(
        subject_uid == ^subject_uid and inserted_at >= ^window_started_at and
          origin in [:agent, :codex]
      )
      |> Ankole.Ash.aggregate!([
        {:input, :sum, field: :input_tokens, default: 0},
        {:output, :sum, field: :output_tokens, default: 0}
      ])

    totals.input + totals.output
  end

  defp counted_round(%{"type" => type, "response" => %{} = response})
       when type in ["response.completed", "response.incomplete"],
       do: response

  defp counted_round(%{"status" => status} = response)
       when status in ["completed", "incomplete"],
       do: response

  defp counted_round(_round), do: nil

  defp insert(runtime, usage, origin) do
    request_context = Map.get(runtime, "request_context") || %{}

    attrs = %{
      subject_uid: Map.get(runtime, "subject_uid"),
      origin: origin,
      model: "#{Map.get(runtime, "provider_id")}/#{Map.get(runtime, "model")}",
      input_tokens: tokens(usage, "input_tokens"),
      output_tokens: tokens(usage, "output_tokens"),
      session_id: Ankole.Attrs.optional_text(Map.get(request_context, "session_id")),
      signal_id: uuid(Map.get(request_context, "signal_id")),
      job_id: positive_integer(Map.get(request_context, "job_id")),
      attempt: non_negative_integer(Map.get(request_context, "attempts"))
    }

    write(attrs)
  end

  # The attribution columns are optional. A malformed value must not fail the
  # quota row, so it is dropped instead of rejected.
  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp uuid(_value), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: nil

  defp write(attrs) do
    case Ankole.Ash.create(UsageRecord, :record_round, attrs) do
      {:ok, _record} -> :ok
      {:error, error} -> write_failed(attrs, Exception.message(error))
    end
  rescue
    error -> write_failed(attrs, Exception.message(error))
  end

  defp write_failed(attrs, reason) do
    Logging.warning(
      "ai_gateway.usage_ledger.write_failed",
      "LLM usage row not recorded",
      %{subject_uid: attrs.subject_uid, reason: reason}
    )

    :ok
  end

  defp origin(runtime, "agent", _caller) do
    if ChatGPTProtocol.codex_client?(Map.get(runtime, "request_context", %{})),
      do: :codex,
      else: :agent
  end

  defp origin(_runtime, "oidc_human", _caller), do: :oidc_human
  defp origin(_runtime, nil, "compaction.summary"), do: :compaction
  defp origin(_runtime, nil, "pod_applet"), do: :applet
  defp origin(_runtime, nil, "brain"), do: :brain

  defp origin(_runtime, nil, "brain." <> _stage), do: :brain
  defp origin(_runtime, _subject_type, _caller), do: nil

  defp tokens(usage, key) do
    case Map.get(usage, key) do
      value when is_integer(value) and value >= 0 -> value
      _absent -> 0
    end
  end
end
