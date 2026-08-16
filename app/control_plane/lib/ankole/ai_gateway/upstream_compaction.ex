defmodule Ankole.AIGateway.UpstreamCompaction do
  @moduledoc """
  Selects and executes a provider-native Responses compact operation.

  The first real compact request is also the capability probe. Only a stable
  unsupported result is cached; all other failures remain eligible for a later
  retry and let the caller choose its local fallback.
  """

  alias Ankole.AIGateway.ModelMetadata.Cache
  alias Ankole.AIGateway.Observability
  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.AIGateway.Providers
  alias Ankole.AIGateway.ResponsesPreparation
  alias Ankole.AIGateway.ResponseStream
  alias Ankole.Logging

  @negative_ttl_ms :timer.hours(1)
  @compact_request_fields ~w(
    instructions tools parallel_tool_calls reasoning service_tier
    prompt_cache_key text
  )

  @type success :: %{
          output: [term()],
          usage: map(),
          binding: map()
        }

  @spec compact(map(), [term()], map(), keyword()) ::
          {:ok, success()} | {:fallback, term()}
  def compact(runtime, input, request, opts \\ [])
      when is_map(runtime) and is_list(input) and is_map(request) do
    enabled? = Keyword.get(opts, :enabled?, false)

    cond do
      not enabled? ->
        {:fallback, :upstream_compaction_disabled}

      not Providers.responses_endpoint?(runtime) ->
        {:fallback, :responses_compaction_not_applicable}

      true ->
        compact_responses(runtime, input, request, Keyword.get(opts, :subject_uid))
    end
  end

  @spec runtime_binding(map()) :: {:ok, map()} | {:error, :invalid_upstream_compaction_binding}
  def runtime_binding(%{
        "provider" => %Provider{id: provider_row_id, updated_at: %DateTime{} = updated_at},
        "model" => model
      })
      when is_binary(provider_row_id) and is_binary(model) and model != "" do
    {:ok,
     %{
       "provider_row_id" => provider_row_id,
       "provider_updated_at" => DateTime.to_iso8601(updated_at),
       "model" => model
     }}
  end

  def runtime_binding(_runtime), do: {:error, :invalid_upstream_compaction_binding}

  @spec binding_matches?(map(), map()) :: boolean()
  def binding_matches?(stored_binding, runtime) when is_map(stored_binding) do
    case runtime_binding(runtime) do
      {:ok, current_binding} -> stored_binding == current_binding
      {:error, _reason} -> false
    end
  end

  def binding_matches?(_stored_binding, _runtime), do: false

  defp compact_responses(runtime, input, request, subject_uid) do
    with {:ok, binding} <- runtime_binding(runtime) do
      cache_key = cache_key(binding)

      case Cache.lookup(cache_key) do
        {:fresh, :unsupported} ->
          {:fallback, :upstream_compaction_unsupported}

        _miss_or_stale ->
          request = compact_request(runtime, input, request)

          case execute(runtime, request, subject_uid) do
            {:ok, %{output: output, usage: usage}} ->
              {:ok, %{output: output, usage: usage, binding: binding}}

            {:unsupported, reason} ->
              :ok = Cache.put(cache_key, :unsupported, @negative_ttl_ms)
              log_degraded(binding, reason, true)
              {:fallback, reason}

            {:fallback, reason} ->
              log_degraded(binding, reason, false)
              {:fallback, reason}
          end
      end
    else
      {:error, reason} -> {:fallback, reason}
    end
  end

  # The compaction trigger is the Provider-native request: a normal Responses
  # request whose input ends with the trigger. Codex moved off the dedicated
  # compact endpoint, and the trigger is the protocol both client generations
  # share. The request uses the standard streaming preparation and stream
  # owner, because some upstreams (the ChatGPT backend) accept nothing else;
  # the stream is collected to its terminal Response and checked before any of
  # it can reach a caller.
  defp execute(runtime, request, subject_uid) do
    with {:ok, %{request: request, spec: prepared_request}} <-
           ResponsesPreparation.prepare_with_runtime(subject_uid, runtime, request, stream?: true),
         {:ok, %{body: body}} <-
           Observability.record_compact(subject_uid, runtime, request, fn ->
             with {:ok, outcome, _meta} <-
                    ResponseStream.collect(subject_uid, request, prepared_request,
                      caller: "compaction.upstream"
                    ),
                  {:ok, body} <- terminal_body(outcome) do
               {:ok, %{body: body}}
             end
           end) do
      compact_response(body)
    else
      {:error, reason} -> classify_error(reason)
    end
  end

  defp terminal_body(%{terminal_error: nil, terminal_response: %{} = response}),
    do: {:ok, response}

  defp terminal_body(%{terminal_error: error}), do: {:error, error}

  defp terminal_body(_outcome),
    do: {:error, :upstream_compaction_missing_terminal_response}

  # Exactly one compaction item is the whole contract. Anything else means the
  # Provider answered a normal turn instead of compacting, and using that output
  # would silently replace the history with a model reply. The rest of the output
  # is kept, because the Provider decided what its compacted history retains.
  defp compact_response(%{"output" => output} = body) when is_list(output) do
    case Enum.count(output, &compaction_item?/1) do
      1 ->
        usage = Map.get(body, "usage", %{})
        {:ok, %{output: output, usage: if(is_map(usage), do: usage, else: %{})}}

      count ->
        {:fallback, {:invalid_upstream_compaction_output, count}}
    end
  end

  defp compact_response(_response), do: {:fallback, :invalid_upstream_compaction_output}

  defp compaction_item?(%{"type" => "compaction"}), do: true
  defp compaction_item?(_item), do: false

  defp classify_error({:upstream_response_failed, status, _body} = reason)
       when status in [404, 405],
       do: {:unsupported, reason}

  defp classify_error({:upstream_response_failed, status, _body, _headers} = reason)
       when status in [404, 405],
       do: {:unsupported, reason}

  defp classify_error(reason), do: {:fallback, reason}

  # A real compact request that ends in local compaction is the fact an operator
  # needs. Silent degradation looks the same as a working switch while every
  # compaction still pays the round trip. A disabled switch, a non-Responses
  # wire, and a cached unsupported result send no request and stay silent.
  defp log_degraded(binding, reason, cached?) do
    Logging.warning(
      "ai_gateway.upstream_compaction_degraded",
      "AIGateway upstream compaction fell back to local compaction",
      %{
        provider_row_id: binding["provider_row_id"],
        model: binding["model"],
        unsupported_cached: cached?,
        reason: inspect(reason, limit: 5, printable_limit: 256)
      }
    )
  end

  defp compact_request(runtime, input, request) do
    request
    |> Map.take(@compact_request_fields)
    |> Map.put("model", Map.fetch!(runtime, "model"))
    |> Map.put("input", input ++ [%{"type" => "compaction_trigger"}])
  end

  defp cache_key(binding) do
    {:responses_compact_unsupported, binding["provider_row_id"], binding["provider_updated_at"],
     binding["model"]}
  end
end
