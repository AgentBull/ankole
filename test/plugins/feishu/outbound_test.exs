defmodule Feishu.OutboundTest do
  use ExUnit.Case, async: true

  alias Feishu.{Outbound, Source}

  test "materializes one stable delivery id when upstream omits it" do
    source = %Source{id: "main", app_id: "cli_x", app_secret: "secret_x"}
    reply_channel = %{"scope_id" => "oc_chat", "reply_to_external_id" => "om_msg"}
    outbound = %{"op" => "send", "content" => [%{"kind" => "text", "body" => %{"text" => "hi"}}]}

    delivery_fun = fn delivery, _source, _opts ->
      assert is_binary(delivery["id"])
      assert delivery["id"] != ""

      {:ok,
       %{
         "delivery_id" => delivery["id"],
         "status" => "sent",
         "primary_external_id" => "om_reply",
         "warnings" => []
       }}
    end

    assert {:ok, %{"delivery_id" => delivery_id, "status" => "sent"}} =
             Outbound.deliver(source, reply_channel, outbound, delivery_fun: delivery_fun)

    assert is_binary(delivery_id)
  end
end
