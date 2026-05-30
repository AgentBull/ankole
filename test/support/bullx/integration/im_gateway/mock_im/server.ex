defmodule BullX.Integration.IMGateway.MockIM.Server do
  @moduledoc """
  In-memory state for the mock IM channel.

  Holds the inbound message store (so edits/recalls can reference an original
  provider message) and the captured outbound transcript (every `deliver/4` and
  `consume_stream/4` the agent performs back through the adapter). A single named
  `Agent` keeps the transcript reachable from the test process no matter which
  process ran the generation.
  """

  use Agent

  @name __MODULE__

  def child_spec(_opts), do: %{id: @name, start: {__MODULE__, :start_link, [[]]}}

  def start_link(_opts \\ []), do: Agent.start_link(fn -> initial_state() end, name: @name)

  def reset, do: Agent.update(@name, fn _state -> initial_state() end)

  defp initial_state,
    do: %{
      seq: 0,
      messages: %{},
      outbound: [],
      delivery_failures: [],
      streams: [],
      fail_delivery: false
    }

  @doc "Make the next deliveries fail (drives the outbound delivery-failure path)."
  def fail_delivery(value \\ true), do: Agent.update(@name, &%{&1 | fail_delivery: value})
  def fail_delivery?, do: Agent.get(@name, & &1.fail_delivery)

  @doc "Monotonic counter used to order inbound and outbound events deterministically."
  def next_seq, do: Agent.get_and_update(@name, fn s -> {s.seq + 1, %{s | seq: s.seq + 1}} end)

  # ---- inbound message store ------------------------------------------------

  def put_message(message_id, attrs) when is_binary(message_id) do
    Agent.update(@name, fn state ->
      put_in(state, [:messages, message_id], Map.put(attrs, :id, message_id))
    end)

    message_id
  end

  def update_message(message_id, fun) when is_binary(message_id) and is_function(fun, 1) do
    Agent.update(@name, fn state ->
      case state.messages do
        %{^message_id => msg} -> put_in(state, [:messages, message_id], fun.(msg))
        _missing -> state
      end
    end)
  end

  def get_message(message_id), do: Agent.get(@name, &Map.get(&1.messages, message_id))

  # ---- outbound transcript --------------------------------------------------

  def record_outbound(record) when is_map(record) do
    seq = next_seq()
    Agent.update(@name, &%{&1 | outbound: &1.outbound ++ [Map.put(record, :seq, seq)]})
  end

  def record_delivery_failure(record) when is_map(record) do
    seq = next_seq()

    Agent.update(
      @name,
      &%{&1 | delivery_failures: &1.delivery_failures ++ [Map.put(record, :seq, seq)]}
    )
  end

  def record_stream(record) when is_map(record) do
    seq = next_seq()
    Agent.update(@name, &%{&1 | streams: &1.streams ++ [Map.put(record, :seq, seq)]})
  end

  @doc "Full outbound transcript in chronological order."
  def outbound, do: Agent.get(@name, & &1.outbound)

  @doc "Outbound records limited to one scope (group/dm) id."
  def outbound(scope_id) when is_binary(scope_id),
    do: Enum.filter(outbound(), &(&1[:scope_id] == scope_id))

  def delivery_failures, do: Agent.get(@name, & &1.delivery_failures)

  def delivery_failures(scope_id) when is_binary(scope_id),
    do: Enum.filter(delivery_failures(), &(&1[:scope_id] == scope_id))

  def streams, do: Agent.get(@name, & &1.streams)
end
