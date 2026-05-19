defmodule Discord.OutboundTest do
  use ExUnit.Case, async: true

  alias Discord.{ContentMapper, Outbound, Source}

  defmodule API do
    def request(_source, :create_message, %{"body" => %{"content" => content}}),
      do: {:ok, %{"id" => content}}

    def request(_source, :edit_message, %{"message_id" => message_id}),
      do: {:ok, %{"id" => message_id}}
  end

  test "send renders safe Discord message creates" do
    source = %Source{id: "main", application_id: "app_1", bot_token: "token", api_module: API}

    assert {:ok, result} =
             Outbound.deliver(
               source,
               %{"scope_id" => "chan_1", "reply_to_external_id" => "msg_1"},
               %{
                 "op" => "send",
                 "content" => [%{"kind" => "text", "body" => %{"text" => "hello"}}]
               }
             )

    assert result["status"] == "sent"
    assert result["external_message_ids"] == ["hello"]
  end

  test "degrades control notices to regular Discord messages" do
    notice = %{"kind" => "control_notice", "body" => %{"text" => "New session started"}}

    assert {:ok, ["New session started"], ["control_notice_degraded_to_text"]} =
             ContentMapper.render_outbound(notice)
  end
end
