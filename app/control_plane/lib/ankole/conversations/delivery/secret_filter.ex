defmodule Ankole.Conversations.Delivery.SecretFilter do
  @moduledoc """
  Removes installation secrets before provider-visible output leaves Conversations.Delivery.

  The filter replaces exact values of the operator-configured WorkerEnv
  secrets that the Agent's Worker can receive. It does not classify output by
  syntax. JWTs, bearer-token examples, private-key examples, and credential assignments remain unchanged
  unless their value equals one of those secrets.

  Short values and adapter-minted provider tokens stay outside the set. Reading
  a provider token here would make every reply depend on provider health, and a
  short value cannot be replaced without corrupting normal text.
  """

  alias Ankole.Conversations.Delivery.PreviewStates
  alias Ankole.Signals.Signal
  alias Ankole.AgentWorkers.WorkerEnv
  alias Ankole.Conversations.Delivery.Intent

  @redacted "[REDACTED]"

  # Exact replacement is safe only for a value long enough that it cannot appear
  # in normal prose. A shorter operator secret stays visible because replacing
  # every occurrence of a common short string would corrupt each reply.
  @minimum_secret_bytes 12

  @doc """
  Returns a copy of one intent row that is safe to give to a provider adapter.
  """
  @spec filter_intent(term()) :: {:ok, term()} | {:error, term()}
  def filter_intent(%Intent{agent_uid: agent_uid} = intent)
      when is_binary(agent_uid) and agent_uid != "" do
    with {:ok, secret_values} <- secret_values(agent_uid) do
      {:ok, redact_intent(intent, secret_values)}
    end
  end

  def filter_intent(intent), do: {:ok, intent}

  @doc """
  Returns a copy of one mutable reply request that is safe to give to a provider adapter.
  """
  @spec filter_reply_preview(term()) :: {:ok, term()} | {:error, term()}
  def filter_reply_preview(%{signal: %Signal{agent_uid: agent_uid}} = request)
      when is_binary(agent_uid) and agent_uid != "" do
    with {:ok, secret_values} <- secret_values(agent_uid) do
      preview = PreviewStates.get(request.signal)

      signal = %{
        request.signal
        | preview: %{preview | checkpoint: redact_term(preview.checkpoint, secret_values)}
      }

      {:ok,
       %{
         request
         | signal: signal,
           presentation: redact_term(request.presentation, secret_values),
           previous_presentation: redact_term(request.previous_presentation, secret_values),
           checkpoint: redact_term(request.checkpoint, secret_values),
           delivery: redact_optional_delivery(request.delivery, secret_values)
       }}
    end
  end

  def filter_reply_preview(request), do: {:ok, request}

  @doc false
  @spec redact_text(String.t(), [String.t()]) :: String.t()
  def redact_text(text, secret_values) when is_binary(text) and is_list(secret_values) do
    Enum.reduce(secret_values, text, &String.replace(&2, &1, @redacted))
  end

  defp secret_values(agent_uid) do
    case WorkerEnv.sensitive_values(agent_uid) do
      {:ok, worker_env_values} -> {:ok, normalize_secret_values(worker_env_values)}
      {:error, reason} -> {:error, {:outbound_secret_filter_unavailable, reason}}
    end
  end

  defp normalize_secret_values(values) do
    values
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= @minimum_secret_bytes))
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  defp redact_intent(%Intent{} = intent, secret_values) do
    %{
      intent
      | payload: redact_term(intent.payload, secret_values),
        fallback_visible_text: redact_term(intent.fallback_visible_text, secret_values)
    }
  end

  defp redact_optional_delivery(%Intent{} = intent, secret_values),
    do: redact_intent(intent, secret_values)

  defp redact_optional_delivery(intent, _secret_values), do: intent

  defp redact_term(value, secret_values) when is_binary(value),
    do: redact_text(value, secret_values)

  defp redact_term(value, secret_values) when is_list(value),
    do: Enum.map(value, &redact_term(&1, secret_values))

  defp redact_term(%_struct{} = value, _secret_values), do: value

  defp redact_term(value, secret_values) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, redact_term(item, secret_values)} end)
  end

  defp redact_term(value, _secret_values), do: value
end
