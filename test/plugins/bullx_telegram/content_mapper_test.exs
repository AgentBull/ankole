defmodule BullxTelegram.ContentMapperTest do
  use ExUnit.Case, async: true

  alias BullxTelegram.ContentMapper

  describe "inbound_blocks/1" do
    test "text message yields one text block" do
      assert {:ok, [%{"kind" => "text", "body" => %{"text" => "hello"}}]} =
               ContentMapper.inbound_blocks(%{"text" => "hello"})
    end

    test "photo message yields native image block with telegram URI" do
      message = %{
        "photo" => [
          %{"file_id" => "small_id", "width" => 100},
          %{"file_id" => "large_id", "width" => 800}
        ]
      }

      assert {:ok, [%{"kind" => "image", "body" => %{"url" => url, "fallback_text" => _}}]} =
               ContentMapper.inbound_blocks(message)

      assert url == "telegram://file/large_id"
    end

    test "photo with caption yields caption text block then media block" do
      message = %{
        "caption" => "a sunset",
        "photo" => [%{"file_id" => "fid"}]
      }

      assert {:ok, [text_block, image_block]} = ContentMapper.inbound_blocks(message)
      assert text_block == %{"kind" => "text", "body" => %{"text" => "a sunset"}}
      assert image_block["kind"] == "image"
      assert image_block["body"]["url"] == "telegram://file/fid"
    end

    test "document yields :file native block with filename" do
      message = %{
        "document" => %{
          "file_id" => "doc_id",
          "file_name" => "report.pdf"
        }
      }

      assert {:ok, [block]} = ContentMapper.inbound_blocks(message)
      assert block["kind"] == "file"
      assert block["body"]["filename"] == "report.pdf"
      assert block["body"]["fallback_text"] == "report.pdf"
    end

    test "voice message yields :audio block" do
      message = %{"voice" => %{"file_id" => "voice_id"}}

      assert {:ok, [%{"kind" => "audio", "body" => %{"url" => "telegram://file/voice_id"}}]} =
               ContentMapper.inbound_blocks(message)
    end

    test "video, animation, video_note, sticker map correctly" do
      assert {:ok, [%{"kind" => "video"}]} =
               ContentMapper.inbound_blocks(%{"video" => %{"file_id" => "v"}})

      assert {:ok, [%{"kind" => "video"}]} =
               ContentMapper.inbound_blocks(%{"animation" => %{"file_id" => "v"}})

      assert {:ok, [%{"kind" => "video"}]} =
               ContentMapper.inbound_blocks(%{"video_note" => %{"file_id" => "v"}})

      assert {:ok, [%{"kind" => "image"}]} =
               ContentMapper.inbound_blocks(%{"sticker" => %{"file_id" => "s"}})
    end

    test "location message yields text block with maps URL" do
      message = %{"location" => %{"latitude" => 1.5, "longitude" => 2.5}}

      assert {:ok, [%{"kind" => "text", "body" => %{"text" => text}}]} =
               ContentMapper.inbound_blocks(message)

      assert String.contains?(text, "Location: 1.5, 2.5")
      assert String.contains?(text, "https://maps.google.com/?q=1.5,2.5")
    end

    test "unsupported message kind falls back to localized text" do
      assert {:ok, [%{"kind" => "text", "body" => %{"text" => _text}}]} =
               ContentMapper.inbound_blocks(%{"dice" => %{"value" => 6}})
    end
  end

  describe "render_outbound/1" do
    test "text content returns text and no warnings" do
      assert {:ok, "hi", []} =
               ContentMapper.render_outbound(%{"kind" => "text", "body" => %{"text" => "hi"}})
    end

    test "image content with fallback_text degrades to text with warning" do
      block = %{"kind" => "image", "body" => %{"fallback_text" => "[photo]"}}

      assert {:ok, "[photo]", ["image_degraded_to_fallback_text"]} =
               ContentMapper.render_outbound(block)
    end

    test "card content with fallback_text degrades to text" do
      block = %{"kind" => "card", "body" => %{"fallback_text" => "card summary"}}

      assert {:ok, "card summary", ["card_degraded_to_fallback_text"]} =
               ContentMapper.render_outbound(block)
    end

    test "media without fallback_text returns unsupported error" do
      block = %{"kind" => "video", "body" => %{"url" => "https://example.com/v.mp4"}}

      assert {:error, %{"kind" => "unsupported"}} = ContentMapper.render_outbound(block)
    end

    test "nil or empty list returns payload error" do
      assert {:error, %{"kind" => "payload"}} = ContentMapper.render_outbound(nil)
      assert {:error, %{"kind" => "payload"}} = ContentMapper.render_outbound([])
    end

    test "list of blocks picks the first block" do
      blocks = [
        %{"kind" => "text", "body" => %{"text" => "first"}},
        %{"kind" => "text", "body" => %{"text" => "second"}}
      ]

      assert {:ok, "first", []} = ContentMapper.render_outbound(blocks)
    end
  end

  describe "utf16_units/1" do
    test "counts BMP codepoints as 1 unit" do
      assert ContentMapper.utf16_units("hello") == 5
      assert ContentMapper.utf16_units("你好") == 2
    end

    test "counts supplementary-plane codepoints as 2 units" do
      # 🚀 is U+1F680, supplementary plane → 2 UTF-16 code units
      assert ContentMapper.utf16_units("🚀") == 2
      assert ContentMapper.utf16_units("a🚀b") == 4
    end
  end

  describe "split_message/2" do
    test "short message returns single chunk" do
      assert ContentMapper.split_message("hello world", 100) == ["hello world"]
    end

    test "long ASCII message splits at limit boundary" do
      text = String.duplicate("a", 250)
      chunks = ContentMapper.split_message(text, 100)

      assert length(chunks) == 3
      assert Enum.all?(chunks, fn chunk -> byte_size(chunk) <= 100 end)
      assert Enum.join(chunks) == text
    end

    test "emoji-heavy text splits by UTF-16 units, not bytes" do
      # 50 rockets = 100 UTF-16 units, should split into 2 chunks at limit 60
      text = String.duplicate("🚀", 50)
      chunks = ContentMapper.split_message(text, 60)

      assert length(chunks) >= 2
      assert Enum.join(chunks) == text

      Enum.each(chunks, fn chunk ->
        assert ContentMapper.utf16_units(chunk) <= 60
      end)
    end

    test "empty string falls back to localized placeholder" do
      assert [_placeholder] = ContentMapper.split_message("", 100)
    end
  end
end
