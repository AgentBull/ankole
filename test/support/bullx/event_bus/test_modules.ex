defmodule BullX.EventBus.TestTarget do
  @moduledoc false

  @behaviour BullX.EventBus.Target

  @impl BullX.EventBus.Target
  def handle_event(invocation, entry) do
    if pid = Application.get_env(:bullx, :event_bus_test_pid) do
      send(pid, {:event_bus_target_called, invocation, entry})
    end

    invocation.close.()
    :ok
  end
end

defmodule BullX.EventBus.TestingChannel do
  @moduledoc false

  @gate_key :event_bus_test_delivery_gate

  def block_next_delivery(content_kind) when is_atom(content_kind) do
    block_next_delivery(Atom.to_string(content_kind))
  end

  def block_next_delivery(content_kind) when is_binary(content_kind) do
    ref = make_ref()
    Application.put_env(:bullx, @gate_key, %{owner: self(), ref: ref, content_kind: content_kind})
    ref
  end

  def await_blocked_delivery(ref, timeout \\ 1_000) do
    receive do
      {:event_bus_test_delivery_blocked, ^ref, blocked} -> {:ok, blocked}
    after
      timeout -> {:error, :timeout}
    end
  end

  def release_delivery(%{pid: pid, ref: ref}) when is_pid(pid) do
    send(pid, {:event_bus_test_delivery_continue, ref})
    :ok
  end

  def clear do
    Application.delete_env(:bullx, @gate_key)
    :ok
  end

  def gate, do: Application.get_env(:bullx, @gate_key)
end

defmodule BullX.EventBus.TestChannelAdapter do
  @moduledoc false

  @behaviour BullX.EventBus.ChannelAdapter

  @impl BullX.EventBus.ChannelAdapter
  def normalize_inbound(source, %{event: event}) do
    {:ok, Map.put(event, "source", source["source"])}
  end

  def normalize_inbound(_source, :ignore), do: :ignore
  def normalize_inbound(_source, _input), do: {:error, %{"kind" => "invalid_input"}}

  @impl BullX.EventBus.ChannelAdapter
  def fetch_source("default"),
    do: {:ok, %{"id" => "default", "source" => "test://source/default"}}

  def fetch_source("other"),
    do: {:ok, %{"id" => "other", "source" => "test://source/other"}}

  def fetch_source(_source_id), do: {:error, :not_found}

  @impl BullX.EventBus.ChannelAdapter
  def consume_stream(source, reply_channel, stream_id, opts) do
    if pid = Application.get_env(:bullx, :event_bus_test_pid) do
      send(pid, {:event_bus_adapter_stream_consumed, source, reply_channel, stream_id})
    end

    _opts = opts
    :ok
  end

  @impl BullX.EventBus.ChannelAdapter
  def deliver(source, reply_channel, %{"force_error" => true} = outbound, _opts) do
    maybe_block_delivery(source, reply_channel, outbound)

    if pid = Application.get_env(:bullx, :event_bus_test_pid) do
      send(pid, {:event_bus_adapter_delivery_failed, source, reply_channel, outbound})
    end

    {:error, %{"kind" => "network", "message" => "test delivery failure", "details" => %{}}}
  end

  def deliver(source, reply_channel, %{"op" => "recall"} = outbound, _opts) do
    maybe_block_delivery(source, reply_channel, outbound)

    if pid = Application.get_env(:bullx, :event_bus_test_pid) do
      send(pid, {:event_bus_adapter_delivered, source, reply_channel, outbound})
    end

    {:ok,
     %{
       "delivery_id" => outbound["id"],
       "status" => "recalled",
       "warnings" => []
     }}
  end

  def deliver(source, reply_channel, outbound, _opts) do
    maybe_block_delivery(source, reply_channel, outbound)

    if pid = Application.get_env(:bullx, :event_bus_test_pid) do
      send(pid, {:event_bus_adapter_delivered, source, reply_channel, outbound})
    end

    primary_external_id = "external:" <> outbound["id"]

    {:ok,
     %{
       "delivery_id" => outbound["id"],
       "primary_external_id" => primary_external_id,
       "external_message_ids" => [primary_external_id],
       "status" => "sent",
       "warnings" => []
     }}
  end

  defp maybe_block_delivery(source, reply_channel, outbound) do
    case BullX.EventBus.TestingChannel.gate() do
      %{owner: owner, ref: ref, content_kind: content_kind} when is_pid(owner) ->
        maybe_block_matching_delivery(owner, ref, content_kind, source, reply_channel, outbound)

      _other ->
        :ok
    end
  end

  defp maybe_block_matching_delivery(owner, ref, content_kind, source, reply_channel, outbound) do
    case outbound_has_content_kind?(outbound, content_kind) do
      true ->
        BullX.EventBus.TestingChannel.clear()

        send(owner, {
          :event_bus_test_delivery_blocked,
          ref,
          %{
            pid: self(),
            ref: ref,
            source: source,
            reply_channel: reply_channel,
            outbound: outbound
          }
        })

        receive do
          {:event_bus_test_delivery_continue, ^ref} -> :ok
        after
          5_000 -> :ok
        end

      false ->
        :ok
    end
  end

  defp outbound_has_content_kind?(%{"content" => content}, content_kind) when is_list(content) do
    Enum.any?(content, &(content_kind(&1) == content_kind))
  end

  defp outbound_has_content_kind?(_outbound, _content_kind), do: false

  defp content_kind(%{"kind" => kind}) when is_binary(kind), do: kind
  defp content_kind(%{"type" => type}) when is_binary(type), do: type
  defp content_kind(%{kind: kind}) when is_atom(kind), do: Atom.to_string(kind)
  defp content_kind(%{kind: kind}) when is_binary(kind), do: kind
  defp content_kind(%{type: type}) when is_atom(type), do: Atom.to_string(type)
  defp content_kind(%{type: type}) when is_binary(type), do: type
  defp content_kind(_block), do: nil
end

defmodule BullX.EventBus.TestAdapterPlugin do
  @moduledoc false

  use BullX.Plugins.Plugin, app: :eventbus_test_plugin

  @impl BullX.Plugins.Plugin
  def extensions do
    [
      %{
        point: :"bullx.event_bus.channel_adapter",
        id: "eventbus_test",
        module: BullX.EventBus.TestChannelAdapter
      }
    ]
  end
end
