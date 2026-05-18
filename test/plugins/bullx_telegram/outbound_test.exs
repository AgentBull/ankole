defmodule BullxTelegram.OutboundTest do
  use ExUnit.Case, async: true

  alias BullxTelegram.{Outbound, Source}

  defmodule API do
    def request(_source, "sendMessage", params) do
      {:ok, %{"message_id" => Map.fetch!(params, "text")}}
    end

    def request(_source, "editMessageText", params) do
      {:ok, %{"message_id" => Map.fetch!(params, "message_id")}}
    end
  end

  test "send renders text through Telegram sendMessage" do
    source = %Source{id: "main", bot_token: "123456:ABC", api_module: API}

    assert {:ok, result} =
             Outbound.deliver(
               source,
               %{"scope_id" => "100", "reply_to_external_id" => "9"},
               %{
                 "op" => "send",
                 "content" => [%{"kind" => "text", "body" => %{"text" => "hello"}}]
               }
             )

    assert result["status"] == "sent"
    assert result["external_message_ids"] == ["hello"]
  end
end
