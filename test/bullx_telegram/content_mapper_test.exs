defmodule BullXTelegram.ContentMapperTest do
  use ExUnit.Case, async: true

  alias BullXGateway.Delivery.Content
  alias BullXTelegram.ContentMapper

  test "maps location messages to text content" do
    assert {:ok, [%Content{kind: :text, body: %{"text" => text}}]} =
             ContentMapper.inbound_blocks(%{
               "location" => %{"latitude" => 31.2, "longitude" => 121.5},
               "venue" => %{"title" => "Office", "address" => "Pudong"}
             })

    assert text =~ "Office"
    assert text =~ "31.2, 121.5"
    assert text =~ "maps.google.com"
  end

  test "maps Telegram media file ids to adapter-local URIs and fallback text" do
    assert {:ok, [%Content{kind: :image, body: body}]} =
             ContentMapper.inbound_blocks(%{
               "photo" => [
                 %{"file_id" => "small"},
                 %{"file_id" => "large"}
               ]
             })

    assert body["url"] == "telegram://file/large"
    assert body["fallback_text"] =~ "image"
  end

  test "preserves caption and media content for captioned files" do
    assert {:ok,
            [
              %Content{kind: :text, body: %{"text" => "caption"}},
              %Content{kind: :file, body: body}
            ]} =
             ContentMapper.inbound_blocks(%{
               "caption" => "caption",
               "document" => %{"file_id" => "doc-1"}
             })

    assert body["url"] == "telegram://file/doc-1"
  end

  test "renders fallback text for outbound rich content" do
    content = %Content{kind: :card, body: %{"fallback_text" => "hello"}}

    assert {:ok, "hello", ["card_degraded_to_fallback_text"]} =
             ContentMapper.render_outbound(content)
  end
end
