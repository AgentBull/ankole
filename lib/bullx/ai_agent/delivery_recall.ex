defmodule BullX.AIAgent.DeliveryRecall do
  @moduledoc false

  alias BullX.AIAgent.Message
  alias BullX.IMGateway.ChannelAdapter

  @spec targets_for_messages([Message.t()]) :: [map()]
  def targets_for_messages(messages) when is_list(messages) do
    messages
    |> Enum.filter(&assistant_message?/1)
    |> Enum.flat_map(&message_recall_targets/1)
    |> Enum.uniq_by(& &1["external_id"])
  end

  @spec deliver_targets(map() | nil, [map()], map(), (term() -> term())) ::
          :recalled | :not_recalled
  def deliver_targets(reply_address, targets, context, on_error \\ fn _reason -> :ok end)

  def deliver_targets(%{} = reply_address, [_ | _] = targets, context, on_error)
      when is_map(context) and is_function(on_error, 1) do
    targets
    |> Enum.map(&deliver_target(reply_address, &1, context, on_error))
    |> Enum.all?(&(&1 == :recalled))
    |> case do
      true -> :recalled
      false -> :not_recalled
    end
  end

  def deliver_targets(_reply_address, _targets, _context, _on_error), do: :not_recalled

  defp deliver_target(reply_address, %{"external_id" => external_id} = target, context, on_error)
       when is_binary(external_id) and external_id != "" do
    outbound = %{
      "id" => recall_id(context, target),
      "op" => "recall",
      "target_external_id" => external_id
    }

    case ChannelAdapter.deliver(reply_address, outbound) do
      {:ok, _result} ->
        :recalled

      {:error, reason} ->
        on_error.(reason)
        :not_recalled
    end
  end

  defp deliver_target(_reply_address, _target, _context, _on_error), do: :not_recalled

  defp recall_id(context, target) do
    payload =
      context
      |> stringify_keys()
      |> Map.merge(%{
        "message_id" => Map.get(target, "message_id"),
        "target_external_id" => Map.get(target, "external_id"),
        "op" => "recall"
      })

    "sha256:" <> BullX.Ext.generic_hash(Jason.encode!(payload))
  end

  defp assistant_message?(%Message{role: :assistant}), do: true
  defp assistant_message?(_message), do: false

  defp message_recall_targets(%Message{id: message_id, metadata: metadata}) do
    delivery = Map.get(metadata, "delivery") || %{}

    delivery
    |> adapter_result_ref()
    |> Map.merge(delivery)
    |> external_message_ids()
    |> Enum.map(&%{"message_id" => message_id, "external_id" => &1})
  end

  defp adapter_result_ref(%{"adapter_result_ref" => ref}) when is_binary(ref) do
    case Jason.decode(ref) do
      {:ok, %{} = decoded} -> decoded
      _error -> %{}
    end
  end

  defp adapter_result_ref(%{"adapter_result_ref" => %{} = ref}), do: ref
  defp adapter_result_ref(_delivery), do: %{}

  defp external_message_ids(metadata) when is_map(metadata) do
    [
      map_value(metadata, "primary_external_id"),
      map_value(metadata, "message_id"),
      map_value(metadata, "external_id")
      | List.wrap(map_value(metadata, "external_message_ids"))
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp external_message_ids(_metadata), do: []

  defp map_value(%{} = map, key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
