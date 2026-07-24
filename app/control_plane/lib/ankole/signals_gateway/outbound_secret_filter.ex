defmodule Ankole.SignalsGateway.OutboundSecretFilter do
  @moduledoc """
  Removes installation secrets before provider-visible output leaves SignalsGateway.

  The filter replaces exact values of the RuntimeFabric worker authentication
  key and the operator-configured WorkerEnv secrets that the current Agent
  Computer can receive. It does not classify output by syntax. JWTs,
  bearer-token examples, private-key examples, and credential assignments remain
  unchanged unless their value equals one of those secrets.

  Short values and adapter-minted provider tokens stay outside the set. Reading
  a provider token here would make every reply depend on provider health, and a
  short value cannot be replaced without corrupting normal text.
  """

  alias Ankole.AppConfigure
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.WorkerAuthKey
  alias Ankole.SignalsGateway.ActorRuntime.WorkerEnv
  alias Ankole.SignalsGateway.OutboxEntry

  @redacted "[REDACTED]"

  # Exact replacement is safe only for a value long enough that it cannot appear
  # in normal prose. A shorter operator secret stays visible because replacing
  # every occurrence of a common short string would corrupt each reply.
  @minimum_secret_bytes 12

  @doc """
  Returns a copy of one outbox row that is safe to give to a provider adapter.
  """
  @spec filter_outbox(term()) :: {:ok, term()} | {:error, term()}
  def filter_outbox(%OutboxEntry{agent_uid: agent_uid} = outbox)
      when is_binary(agent_uid) and agent_uid != "" do
    with {:ok, secret_values} <- secret_values(agent_uid) do
      {:ok, redact_outbox(outbox, secret_values)}
    end
  end

  def filter_outbox(outbox), do: {:ok, outbox}

  @doc """
  Returns a copy of one mutable reply request that is safe to give to a provider adapter.
  """
  @spec filter_reply_preview(term()) :: {:ok, term()} | {:error, term()}
  def filter_reply_preview(%{actor_event: %ActorEvent{agent_uid: agent_uid}} = request)
      when is_binary(agent_uid) and agent_uid != "" do
    with {:ok, secret_values} <- secret_values(agent_uid) do
      actor_event =
        Map.update!(
          request.actor_event,
          :reply_preview_checkpoint,
          &redact_term(&1, secret_values)
        )

      {:ok,
       %{
         request
         | actor_event: actor_event,
           presentation: redact_term(request.presentation, secret_values),
           previous_presentation: redact_term(request.previous_presentation, secret_values),
           checkpoint: redact_term(request.checkpoint, secret_values),
           outbox: redact_optional_outbox(request.outbox, secret_values)
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
    with {:ok, worker_auth_values} <- worker_auth_values(),
         {:ok, worker_env_values} <- WorkerEnv.sensitive_values(agent_uid) do
      {:ok, normalize_secret_values(worker_auth_values ++ worker_env_values)}
    else
      {:error, reason} -> {:error, {:outbound_secret_filter_unavailable, reason}}
    end
  end

  defp worker_auth_values do
    with :ok <- WorkerAuthKey.ensure_registered() do
      case AppConfigure.get(WorkerAuthKey.definition()) do
        {:ok, value} when is_binary(value) -> {:ok, [value]}
        :error -> {:ok, []}
        {:error, reason} -> {:error, {:worker_auth_key_unavailable, reason}}
        {:ok, _value} -> {:error, :invalid_worker_auth_key}
      end
    end
  end

  defp normalize_secret_values(values) do
    values
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= @minimum_secret_bytes))
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  defp redact_outbox(%OutboxEntry{} = outbox, secret_values) do
    %{
      outbox
      | payload: redact_term(outbox.payload, secret_values),
        fallback_visible_text: redact_term(outbox.fallback_visible_text, secret_values)
    }
  end

  defp redact_optional_outbox(%OutboxEntry{} = outbox, secret_values),
    do: redact_outbox(outbox, secret_values)

  defp redact_optional_outbox(outbox, _secret_values), do: outbox

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
