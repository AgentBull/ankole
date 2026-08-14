defmodule Ankole.AIGateway.MaxToolCalls do
  @moduledoc """
  Tracks one public Response's `max_tool_calls` budget.

  Provider effects enter the budget from provider item lifecycle events.
  Gateway effects enter it after the provider terminal fixes that round's
  irreversible provider effects. Both sources use the same identity ledger,
  so lifecycle replays are idempotent and later calls are rejected when the
  limit is full.
  """

  alias Ankole.AIGateway.ResponseItems

  @native_responses_resolvers [
    :openai_responses,
    "openai_responses",
    :hosted_responses,
    "hosted_responses"
  ]
  @terminal_call_statuses ["completed", "failed", "incomplete", "cancelled"]

  @enforce_keys [:limit]
  defstruct limit: nil, started: MapSet.new(), observed: MapSet.new()

  @type t :: %__MODULE__{
          limit: non_neg_integer(),
          started: MapSet.t(),
          observed: MapSet.t()
        }

  @spec new(term(), term(), keyword()) :: t() | nil
  def new(limit, resolver, opts \\ [])

  def new(limit, resolver, opts)
      when is_integer(limit) and limit >= 0 and is_list(opts) do
    if Keyword.get(opts, :force, false) or
         resolver not in [nil | @native_responses_resolvers] do
      %__MODULE__{limit: limit}
    end
  end

  def new(_limit, _resolver, _opts), do: nil

  @doc "Observes one provider-owned built-in effect lifecycle event."
  @spec observe_provider_event(t() | nil, map(), term()) :: t() | nil
  def observe_provider_event(policy, event, scope \\ :single_response)
  def observe_provider_event(nil, _event, _scope), do: nil

  def observe_provider_event(
        %__MODULE__{} = policy,
        %{"type" => "response.output_item.added", "item" => %{} = item} = event,
        scope
      ) do
    observe_provider_item(policy, item, event, :added, scope)
  end

  def observe_provider_event(
        %__MODULE__{} = policy,
        %{"type" => "response.output_item.done", "item" => %{} = item} = event,
        scope
      ) do
    observe_provider_item(policy, item, event, :done, scope)
  end

  def observe_provider_event(%__MODULE__{} = policy, _event, _scope), do: policy

  @doc "Reconciles provider effects when a terminal omits item lifecycle events."
  @spec reconcile_provider_items(t() | nil, [map()], term()) :: t() | nil
  def reconcile_provider_items(nil, _items, _scope), do: nil

  def reconcile_provider_items(%__MODULE__{} = policy, items, scope) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce(policy, fn
      {%{} = item, output_index}, policy ->
        observe_provider_item(policy, item, %{"output_index" => output_index}, :terminal, scope)

      {_invalid, _output_index}, policy ->
        policy
    end)
  end

  @doc "Admits gateway effects after provider effects for the round are known."
  @spec admit_gateway_items(t() | nil, [map()], term()) :: t() | nil
  def admit_gateway_items(nil, _items, _scope), do: nil

  def admit_gateway_items(%__MODULE__{} = policy, items, scope) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce(policy, fn
      {%{} = item, output_index}, policy ->
        admit_gateway_item(policy, item, %{"output_index" => output_index}, :terminal, scope)

      {_invalid, _output_index}, policy ->
        policy
    end)
  end

  @spec exhausted?(t() | nil) :: boolean()
  def exhausted?(nil), do: false
  def exhausted?(%__MODULE__{limit: 0}), do: true

  def exhausted?(%__MODULE__{} = policy) do
    MapSet.size(policy.started) >= policy.limit and
      MapSet.subset?(policy.started, policy.observed)
  end

  @spec remaining(t() | nil) :: non_neg_integer() | nil
  def remaining(nil), do: nil

  def remaining(%__MODULE__{} = policy) do
    max(policy.limit - MapSet.size(policy.started), 0)
  end

  @doc "Returns whether one completed call item was admitted by the shared budget."
  @spec item_admitted?(t() | nil, map(), term()) :: boolean()
  def item_admitted?(policy, item, scope \\ :single_response)
  def item_admitted?(nil, _item, _scope), do: true

  def item_admitted?(%__MODULE__{} = policy, %{} = item, scope) do
    case ResponseItems.budget_role(item) do
      role when role in [:gateway_effect, :provider_effect] ->
        case call_key(%{}, item, :terminal, scope) do
          nil -> true
          key -> MapSet.member?(policy.started, key)
        end

      :none ->
        true
    end
  end

  @doc "Returns whether the call item in one lifecycle event was admitted."
  @spec event_item_admitted?(t() | nil, map(), term()) :: boolean()
  def event_item_admitted?(policy, event, scope \\ :single_response)
  def event_item_admitted?(nil, _event, _scope), do: true

  def event_item_admitted?(%__MODULE__{} = policy, %{"item" => %{} = item} = event, scope) do
    case ResponseItems.budget_role(item) do
      role when role in [:gateway_effect, :provider_effect] ->
        phase = if event["type"] == "response.output_item.added", do: :added, else: :done

        case call_key(event, item, phase, scope) do
          nil -> true
          key -> MapSet.member?(policy.started, key)
        end

      :none ->
        true
    end
  end

  def event_item_admitted?(%__MODULE__{}, _event, _scope), do: true

  @spec details(t()) :: %{required(String.t()) => non_neg_integer()}
  def details(%__MODULE__{} = policy) do
    observed = MapSet.size(policy.observed)

    %{
      "limit" => policy.limit,
      "observed" => observed,
      "overshoot" => max(observed - policy.limit, 0)
    }
  end

  defp observe_provider_item(policy, item, event, phase, scope) do
    if ResponseItems.budget_role(item) == :provider_effect do
      {policy, key} = resolve_call_key(policy, event, item, phase, scope)

      case admit_call(policy, key) do
        {:admitted, policy} ->
          maybe_finish_call(
            policy,
            key,
            phase != :added or item["status"] in @terminal_call_statuses
          )

        :ignored ->
          policy
      end
    else
      policy
    end
  end

  defp admit_gateway_item(policy, item, event, phase, scope) do
    if ResponseItems.budget_role(item) == :gateway_effect and
         ResponseItems.executable_call?(item) do
      {policy, key} = resolve_call_key(policy, event, item, phase, scope)

      case admit_call(policy, key) do
        {:admitted, policy} -> finish_call(policy, key)
        :ignored -> policy
      end
    else
      policy
    end
  end

  defp resolve_call_key(policy, event, item, phase, scope) do
    key = call_key(event, item, phase, scope)

    case {phase, event, key, item["type"]} do
      {phase, %{"output_index" => output_index}, stable_key, type}
      when phase in [:done, :terminal] and is_integer(output_index) and
             not is_nil(stable_key) and is_binary(type) ->
        provisional = {scope, type, :output_index, output_index}
        {remap_key(policy, provisional, stable_key), stable_key}

      _no_alias ->
        {policy, key}
    end
  end

  defp remap_key(policy, key, key), do: policy

  defp remap_key(policy, provisional, stable) do
    %{
      policy
      | started: replace_key(policy.started, provisional, stable),
        observed: replace_key(policy.observed, provisional, stable)
    }
  end

  defp replace_key(set, old, new) do
    if MapSet.member?(set, old) do
      set |> MapSet.delete(old) |> MapSet.put(new)
    else
      set
    end
  end

  defp call_key(_event, %{"type" => "program", "call_id" => call_id}, _phase, scope)
       when is_binary(call_id) and call_id != "",
       do: {scope, :program, :call_id, call_id}

  defp call_key(
         _event,
         %{"type" => "tool_search_call", "execution" => "client", "call_id" => call_id},
         _phase,
         scope
       )
       when is_binary(call_id) and call_id != "",
       do: {scope, :tool_search, :call_id, call_id}

  defp call_key(
         _event,
         %{"type" => "tool_search_call", "execution" => "server", "id" => id},
         _phase,
         scope
       )
       when is_binary(id) and id != "",
       do: {scope, :tool_search, :id, id}

  defp call_key(_event, %{"type" => type, "id" => id}, _phase, scope)
       when is_binary(type) and is_binary(id) and id != "",
       do: {scope, type, :id, id}

  defp call_key(_event, %{"type" => type, "call_id" => call_id}, _phase, scope)
       when is_binary(type) and is_binary(call_id) and call_id != "",
       do: {scope, type, :call_id, call_id}

  defp call_key(%{"output_index" => output_index}, %{"type" => type}, _phase, scope)
       when is_integer(output_index) and is_binary(type),
       do: {scope, type, :output_index, output_index}

  defp call_key(
         %{"sequence_number" => sequence_number},
         %{"type" => type},
         phase,
         scope
       )
       when phase in [:done, :terminal] and is_integer(sequence_number) and is_binary(type),
       do: {scope, type, :sequence, sequence_number}

  defp call_key(_event, _item, _phase, _scope), do: nil

  defp admit_call(policy, nil), do: {:admitted, policy}

  defp admit_call(%__MODULE__{} = policy, key) do
    cond do
      MapSet.member?(policy.started, key) ->
        {:admitted, policy}

      MapSet.size(policy.started) < policy.limit ->
        {:admitted, %{policy | started: MapSet.put(policy.started, key)}}

      true ->
        :ignored
    end
  end

  defp finish_call(policy, nil), do: policy

  defp finish_call(%__MODULE__{} = policy, key),
    do: %{policy | observed: MapSet.put(policy.observed, key)}

  defp maybe_finish_call(policy, key, true), do: finish_call(policy, key)
  defp maybe_finish_call(policy, _key, false), do: policy
end
