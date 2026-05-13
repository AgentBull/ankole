defmodule Discord.ContentMapperTest do
  use ExUnit.Case, async: true

  alias Discord.{ContentMapper, Source}

  setup do
    source = %Source{
      adapter: "discord",
      channel_id: "main",
      bot_user_id: "9999"
    }

    {:ok, source: source}
  end

  describe "inbound_blocks/2" do
    test "text content produces a single text block", %{source: source} do
      message = %{
        "content" => "hello bot",
        "channel_id" => "100"
      }

      assert {:ok, [%{"kind" => "text", "body" => %{"text" => "hello bot"}}], "hello bot"} =
               ContentMapper.inbound_blocks(message, source)
    end

    test "bot mentions are stripped from primary text but preserved elsewhere", %{source: source} do
      message = %{
        "content" => "<@9999> what's up",
        "channel_id" => "100"
      }

      assert {:ok, [block], text} = ContentMapper.inbound_blocks(message, source)
      assert block["body"]["text"] == "what's up"
      assert text == "what's up"
    end

    test "image attachments produce native image block with stable URI", %{source: source} do
      message = %{
        "channel_id" => "100",
        "content" => "",
        "attachments" => [
          %{"id" => "att1", "content_type" => "image/png", "filename" => "pic.png"}
        ]
      }

      assert {:ok, [image], nil} = ContentMapper.inbound_blocks(message, source)
      assert image["kind"] == "image"
      assert image["body"]["url"] == "discord://attachment/100/att1"
      assert image["body"]["filename"] == "pic.png"
    end

    test "non-image content types fall through to file", %{source: source} do
      message = %{
        "channel_id" => "100",
        "attachments" => [
          %{"id" => "att2", "content_type" => "application/pdf", "filename" => "doc.pdf"}
        ]
      }

      assert {:ok, [file], nil} = ContentMapper.inbound_blocks(message, source)
      assert file["kind"] == "file"
    end

    test "empty content with no media returns a payload error", %{source: source} do
      message = %{"content" => "", "channel_id" => "100"}
      assert {:error, %{"kind" => "payload"}} = ContentMapper.inbound_blocks(message, source)
    end
  end

  describe "render_outbound/1" do
    test "passes text through" do
      assert {:ok, "hello", []} =
               ContentMapper.render_outbound(%{
                 "kind" => "text",
                 "body" => %{"text" => "hello"}
               })
    end

    test "degrades image with fallback_text and warns" do
      assert {:ok, "preview", warnings} =
               ContentMapper.render_outbound(%{
                 "kind" => "image",
                 "body" => %{"fallback_text" => "preview"}
               })

      assert "image_degraded_to_fallback_text" in warnings
    end

    test "rejects image without fallback_text" do
      assert {:error, %{"kind" => "unsupported"}} =
               ContentMapper.render_outbound(%{"kind" => "image", "body" => %{}})
    end
  end

  describe "split_message/2" do
    test "single chunk under limit" do
      assert ["short"] = ContentMapper.split_message("short", 100)
    end

    test "splits at limit boundary" do
      text = String.duplicate("a", 10)
      assert ["aaaaa", "aaaaa"] = ContentMapper.split_message(text, 5)
    end

    test "UTF-16 surrogate pair codepoint counts as 2 units" do
      # 👋 is U+1F44B which is above 0xFFFF; counts as 2 UTF-16 units.
      text = "👋👋👋"
      # If we use limit 4, we should get 2 chunks of 2 emoji each
      chunks = ContentMapper.split_message(text, 4)
      assert length(chunks) >= 2
      assert Enum.all?(chunks, fn chunk -> ContentMapper.utf16_units(chunk) <= 4 end)
    end
  end

  describe "strip_bot_mentions/2" do
    test "strips configured bot id when known", %{source: source} do
      assert "rest" = ContentMapper.strip_bot_mentions("<@9999> rest", source) |> String.trim()
      assert "rest" = ContentMapper.strip_bot_mentions("<@!9999> rest", source) |> String.trim()
    end

    test "strips any mention when bot_user_id is unknown" do
      source = %Source{adapter: "discord", channel_id: "main", bot_user_id: nil}
      assert "rest" = ContentMapper.strip_bot_mentions("<@1234> rest", source) |> String.trim()
    end
  end
end
