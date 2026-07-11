defmodule Ankole.AIGateway.MaxToolCalls do
  @moduledoc """
  Tracks the best-effort `max_tool_calls` fallback for non-native resolvers.

  It counts only completed, provider-executed built-in calls in one Response.
  Calls already observed as in flight are allowed to finish before the socket
  cancels at an output-item boundary, so this is intentionally not a hard quota.
  """

  @native_responses_resolvers [:openai_responses, "openai_responses"]
  @terminal_call_statuses ["completed", "failed", "incomplete", "cancelled"]
  @provider_executed_built_in_call_types ~w(
    code_interpreter_call
    file_search_call
    image_generation_call
    mcp_call
    mcp_list_tools
    tool_search_call
    web_search_call
  )

  @enforce_keys [:limit]
  defstruct limit: nil, started: MapSet.new(), observed: MapSet.new()

  @type t :: %__MODULE__{
          limit: non_neg_integer(),
          started: MapSet.t(),
          observed: MapSet.t()
        }

  @spec new(term(), term()) :: t() | nil
  def new(limit, resolver)
      when is_integer(limit) and limit >= 0 and
             resolver not in [nil | @native_responses_resolvers] do
    %__MODULE__{limit: limit}
  end

  def new(_limit, _resolver), do: nil

  @spec observe(t() | nil, map()) :: t() | nil
  def observe(nil, _event), do: nil

  def observe(
        %__MODULE__{} = policy,
        %{
          "type" => "response.output_item.added",
          "item" => %{} = item
        } = event
      ) do
    if built_in_call?(item) do
      case call_key(event, item, :added) do
        nil ->
          policy

        key ->
          policy
          |> start_call(key)
          |> maybe_finish_call(key, item["status"] in @terminal_call_statuses)
      end
    else
      policy
    end
  end

  def observe(
        %__MODULE__{} = policy,
        %{
          "type" => "response.output_item.done",
          "item" => %{} = item
        } = event
      ) do
    if built_in_call?(item) do
      key = call_key(event, item, :done)

      policy
      |> start_call(key)
      |> finish_call(key)
    else
      policy
    end
  end

  def observe(%__MODULE__{} = policy, _event), do: policy

  @spec stop?(t() | nil) :: boolean()
  def stop?(nil), do: false

  def stop?(%__MODULE__{} = policy) do
    observed = MapSet.size(policy.observed)

    # Waiting for all observed in-flight calls is what permits parallel
    # overshoot without cancelling a call halfway through its result event.
    observed > 0 and observed >= policy.limit and
      MapSet.subset?(policy.started, policy.observed)
  end

  @spec details(t()) :: %{
          required(String.t()) => non_neg_integer()
        }
  def details(%__MODULE__{} = policy) do
    observed = MapSet.size(policy.observed)

    %{
      "limit" => policy.limit,
      "observed" => observed,
      "overshoot" => max(observed - policy.limit, 0)
    }
  end

  defp built_in_call?(%{"type" => type}) when is_binary(type),
    do: type in @provider_executed_built_in_call_types

  defp built_in_call?(_item), do: false

  defp call_key(_event, %{"id" => id}, _phase) when is_binary(id) and id != "",
    do: {:id, id}

  defp call_key(_event, %{"call_id" => call_id}, _phase)
       when is_binary(call_id) and call_id != "",
       do: {:call_id, call_id}

  defp call_key(%{"output_index" => output_index}, %{"type" => type}, _phase)
       when is_integer(output_index) and is_binary(type),
       do: {:output_index, output_index, type}

  defp call_key(%{"sequence_number" => sequence_number}, %{"type" => type}, :done)
       when is_integer(sequence_number) and is_binary(type),
       do: {:done_sequence, sequence_number, type}

  defp call_key(_event, _item, _phase), do: nil

  defp start_call(policy, nil), do: policy

  defp start_call(%__MODULE__{} = policy, key),
    do: %{policy | started: MapSet.put(policy.started, key)}

  defp finish_call(policy, nil), do: policy

  defp finish_call(%__MODULE__{} = policy, key),
    do: %{policy | observed: MapSet.put(policy.observed, key)}

  defp maybe_finish_call(policy, key, true), do: finish_call(policy, key)
  defp maybe_finish_call(policy, _key, false), do: policy
end
