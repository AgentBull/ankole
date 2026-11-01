defmodule Ankole.Brain.ChunkerTest do
  use ExUnit.Case, async: true

  alias Ankole.Brain.Chunker

  @chunking %{
    "chunk_size" => 300,
    "chunk_overlap" => 50,
    "max_chars" => 6_000,
    "max_tokens" => 1_500
  }

  describe "count_words/1" do
    test "Latin text counts whitespace tokens" do
      assert Chunker.count_words("one two three") == 3
    end

    test "CJK-dense text counts non-whitespace graphemes" do
      assert Chunker.count_words("这是一个中文句子") == 8
    end

    test "Latin-dominant text with one CJK term stays whitespace-tokenized" do
      text = "an english sentence with one 词 in the middle of many latin words"
      assert Chunker.count_words(text) == length(String.split(text))
    end

    test "empty and whitespace-only text counts zero" do
      assert Chunker.count_words("") == 0
      assert Chunker.count_words("   \n ") == 0
    end
  end

  describe "chunk_text/2" do
    test "short text is a single chunk with exact token_count" do
      assert [%{text: "short text", index: 0, token_count: token_count}] =
               Chunker.chunk_text("short text", @chunking)

      assert token_count == Chunker.estimate_tokens("short text")
    end

    test "blank text produces no chunks" do
      assert Chunker.chunk_text("  \n ", @chunking) == []
    end

    test "long Latin text splits with overlap" do
      paragraph = Enum.map_join(1..120, " ", fn i -> "word#{i}" end)
      text = Enum.map_join(1..8, "\n\n", fn _paragraph -> paragraph end)

      chunks = Chunker.chunk_text(text, @chunking)
      assert length(chunks) > 1
      assert Enum.map(chunks, & &1.index) == Enum.to_list(0..(length(chunks) - 1))

      # Overlap: a later chunk starts with trailing words of the previous one.
      [first, second | _rest] = chunks
      trailing = first.text |> String.split() |> List.last()
      assert String.contains?(second.text, trailing)
    end

    test "whitespace-less CJK paragraph still splits" do
      text = String.duplicate("这是一个没有空格的很长的中文段落，用来验证切分器能持续推进。", 60)

      chunks = Chunker.chunk_text(text, @chunking)
      assert length(chunks) > 1

      for chunk <- chunks do
        assert String.length(chunk.text) <= 6_000
        assert Chunker.estimate_tokens(chunk.text) <= 1_500
      end
    end

    test "CJK chunks carry the configured trailing context without whitespace" do
      text = Enum.map_join(0x4E00..0x4E50, &<<&1::utf8>>)
      settings = Map.merge(@chunking, %{"chunk_size" => 20, "chunk_overlap" => 6})
      [first, second | _] = Chunker.chunk_text(text, settings)

      assert String.starts_with?(second.text, String.slice(first.text, -6, 6))
      assert String.contains?(second.text, String.slice(text, String.length(first.text), 20))
    end

    test "token cap holds on dense text under the char cap" do
      chunking = Map.put(@chunking, "max_tokens", 60)
      text = String.duplicate("知识空间中的一段稠密中文内容。", 40)

      chunks = Chunker.chunk_text(text, chunking)
      assert length(chunks) > 1

      for chunk <- chunks do
        assert chunk.token_count <= 60
        assert chunk.token_count == Chunker.estimate_tokens(chunk.text)
      end
    end

    test "attaches exact token_count across overlapped multi-chunk splits" do
      paragraph = Enum.map_join(1..150, " ", fn i -> "Sentence #{i} carries context." end)
      chunks = Chunker.chunk_text(paragraph, @chunking)
      assert length(chunks) > 1

      for chunk <- chunks do
        assert chunk.token_count == Chunker.estimate_tokens(chunk.text)
      end
    end

    test "rejects invalid chunking bounds" do
      assert_raise ArgumentError, ~r/chunk_size must be positive/, fn ->
        Chunker.chunk_text("hello", Map.put(@chunking, "chunk_size", 0))
      end

      assert_raise ArgumentError, ~r/chunk_overlap must be less than chunk_size/, fn ->
        Chunker.chunk_text(
          "hello",
          Map.merge(@chunking, %{"chunk_size" => 10, "chunk_overlap" => 10})
        )
      end
    end

    test "handles zero overlap, CRLF paragraphs, flag graphemes, and irreducible emoji caps" do
      no_overlap_cfg = Map.merge(@chunking, %{"chunk_size" => 10, "chunk_overlap" => 0})
      crlf_text = Enum.map_join(1..8, "\r\n\r\n", fn i -> "Paragraph #{i} has five words." end)
      no_overlap_chunks = Chunker.chunk_text(crlf_text, no_overlap_cfg)
      assert length(no_overlap_chunks) > 1

      flag_text = String.duplicate("中文🇺🇸段落。\n", 12)

      flag_chunks =
        Chunker.chunk_text(flag_text, %{
          "chunk_size" => 20,
          "chunk_overlap" => 4,
          "max_chars" => 6_000,
          "max_tokens" => 1_500
        })

      assert length(flag_chunks) > 1

      tiny_cap = Map.put(@chunking, "max_tokens", 1)
      emoji_chunks = Chunker.chunk_text("👨‍👩‍👧‍👦👨‍👩‍👧‍👦", tiny_cap)
      assert Enum.map(emoji_chunks, & &1.text) == ["👨‍👩‍👧‍👦", "👨‍👩‍👧‍👦"]
    end
  end

  describe "signature/1" do
    test "changes with any chunking parameter" do
      base = Chunker.signature(@chunking)

      for key <- Map.keys(@chunking) do
        changed = Chunker.signature(Map.update!(@chunking, key, &(&1 + 1)))
        assert changed != base, "signature must change when #{key} changes"
      end
    end
  end
end
