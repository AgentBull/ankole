defmodule BullX.IMGateway.TestingChannel do
  @moduledoc false

  @gate_key :im_gateway_test_delivery_gate

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
      {:im_gateway_test_delivery_blocked, ^ref, blocked} -> {:ok, blocked}
    after
      timeout -> {:error, :timeout}
    end
  end

  def release_delivery(%{pid: pid, ref: ref}) when is_pid(pid) do
    send(pid, {:im_gateway_test_delivery_continue, ref})
    :ok
  end

  def clear do
    Application.delete_env(:bullx, @gate_key)
    :ok
  end

  def gate, do: Application.get_env(:bullx, @gate_key)
end

defmodule BullX.IMGateway.TestChannelAdapter do
  @moduledoc false

  @behaviour BullX.IMGateway.ChannelAdapter

  @impl BullX.IMGateway.ChannelAdapter
  def normalize_inbound(source, %{event: event}) do
    {:ok, Map.put(event, "source", source["source"])}
  end

  def normalize_inbound(_source, :ignore), do: :ignore
  def normalize_inbound(_source, _input), do: {:error, %{"kind" => "invalid_input"}}

  @impl BullX.IMGateway.ChannelAdapter
  def fetch_source("default"),
    do: {:ok, %{"id" => "default", "source" => "test://source/default"}}

  def fetch_source("other"),
    do: {:ok, %{"id" => "other", "source" => "test://source/other"}}

  def fetch_source(_source_id), do: {:error, :not_found}

  @impl BullX.IMGateway.ChannelAdapter
  def consume_stream(source, reply_address, stream_id, opts) do
    if pid = Application.get_env(:bullx, :im_gateway_test_pid) do
      send(pid, {:im_gateway_adapter_stream_consumed, source, reply_address, stream_id})
    end

    _opts = opts
    :ok
  end

  @impl BullX.IMGateway.ChannelAdapter
  def deliver(source, reply_address, %{"force_error" => true} = outbound, _opts) do
    maybe_block_delivery(source, reply_address, outbound)

    if pid = Application.get_env(:bullx, :im_gateway_test_pid) do
      send(pid, {:im_gateway_adapter_delivery_failed, source, reply_address, outbound})
    end

    {:error, %{"kind" => "network", "message" => "test delivery failure", "details" => %{}}}
  end

  def deliver(source, reply_address, %{"op" => "recall"} = outbound, _opts) do
    maybe_block_delivery(source, reply_address, outbound)

    if pid = Application.get_env(:bullx, :im_gateway_test_pid) do
      send(pid, {:im_gateway_adapter_delivered, source, reply_address, outbound})
    end

    {:ok,
     %{
       "delivery_id" => outbound["id"],
       "status" => "recalled",
       "warnings" => []
     }}
  end

  def deliver(source, reply_address, outbound, _opts) do
    maybe_block_delivery(source, reply_address, outbound)

    if pid = Application.get_env(:bullx, :im_gateway_test_pid) do
      send(pid, {:im_gateway_adapter_delivered, source, reply_address, outbound})
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

  defp maybe_block_delivery(source, reply_address, outbound) do
    case BullX.IMGateway.TestingChannel.gate() do
      %{owner: owner, ref: ref, content_kind: content_kind} when is_pid(owner) ->
        maybe_block_matching_delivery(owner, ref, content_kind, source, reply_address, outbound)

      _other ->
        :ok
    end
  end

  defp maybe_block_matching_delivery(owner, ref, content_kind, source, reply_address, outbound) do
    case outbound_has_content_kind?(outbound, content_kind) do
      true ->
        BullX.IMGateway.TestingChannel.clear()

        send(owner, {
          :im_gateway_test_delivery_blocked,
          ref,
          %{
            pid: self(),
            ref: ref,
            source: source,
            reply_address: reply_address,
            outbound: outbound
          }
        })

        receive do
          {:im_gateway_test_delivery_continue, ^ref} -> :ok
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

defmodule BullX.IMGateway.TestAdapterPlugin do
  @moduledoc false

  use BullX.Plugins.Plugin, app: :im_gateway_test_plugin

  @impl BullX.Plugins.Plugin
  def extensions do
    [
      %{
        point: :"bullx.im_gateway.channel_adapter",
        id: "im_gateway_test",
        module: BullX.IMGateway.TestChannelAdapter
      }
    ]
  end
end
