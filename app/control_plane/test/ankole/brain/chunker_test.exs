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
    test "short text is a single chunk" do
      assert [%{text: "short text", index: 0}] = Chunker.chunk_text("short text", @chunking)
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

    test "token cap holds on dense text under the char cap" do
      chunking = Map.put(@chunking, "max_tokens", 60)
      text = String.duplicate("知识空间中的一段稠密中文内容。", 40)

      chunks = Chunker.chunk_text(text, chunking)
      assert length(chunks) > 1

      for chunk <- chunks do
        assert Chunker.estimate_tokens(chunk.text) <= 60
      end
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
