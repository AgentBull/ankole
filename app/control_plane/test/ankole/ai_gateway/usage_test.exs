defmodule Ankole.AIGateway.UsageTest do
  use ExUnit.Case, async: true

  alias Ankole.AIGateway.CompactionArtifacts
  alias Ankole.AIGateway.CompactionHistory
  alias Ankole.AIGateway.Schemas.CompactionArtifact
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AIGateway.Usage

  test "canonical nested details survive repeated normalization and artifact projection" do
    usage = %{
      "input_tokens" => 12,
      "output_tokens" => 5,
      "total_tokens" => 17,
      "input_tokens_details" => %{"cached_tokens" => 8},
      "output_tokens_details" => %{"reasoning_tokens" => 3}
    }

    assert Usage.normalize(usage) == usage
    assert Usage.normalize(Usage.normalize(usage)) == usage

    artifact = %CompactionArtifact{content: %{"output" => [], "usage" => usage}}
    assert CompactionArtifacts.response_body(artifact)["usage"] == usage
    assert CompactionHistory.history_usage_tokens([%Message{metadata: %{"usage" => usage}}]) == 17

    multi_round = %Message{
      metadata: %{
        "usage" => %{
          "input_tokens" => 419_000,
          "output_tokens" => 1_229,
          "total_tokens" => 420_229
        },
        "context_usage" => %{
          "input_tokens" => 209_800,
          "output_tokens" => 540,
          "total_tokens" => 210_340
        }
      }
    }

    assert CompactionHistory.history_usage_tokens([multi_round]) == 210_340

    legacy_without_context_usage = %Message{
      metadata: %{
        "usage" => %{
          "input_tokens" => 419_000,
          "output_tokens" => 1_229,
          "total_tokens" => 420_229
        }
      }
    }

    assert CompactionHistory.history_usage_tokens([legacy_without_context_usage]) == 420_229
  end

  test "legacy Provider and flat detail names share the canonical response shape" do
    assert %{
             "input_tokens" => 12,
             "output_tokens" => 5,
             "total_tokens" => 17,
             "input_tokens_details" => %{"cached_tokens" => 8},
             "output_tokens_details" => %{"reasoning_tokens" => 3}
           } =
             Usage.normalize(%{
               "prompt_tokens" => 12,
               "completion_tokens" => 5,
               "cachedTokens" => 8,
               "reasoningTokens" => 3
             })

    assert Usage.normalize(%{
             "prompt_tokens_details" => %{"cached" => 7},
             "completion_tokens_details" => %{"reasoning" => 2}
           })["input_tokens_details"] == %{"cached_tokens" => 7}
  end

  test "nested zero takes priority over legacy fields and invalid counts are ignored" do
    assert %{
             "input_tokens" => 4,
             "output_tokens" => 0,
             "total_tokens" => 0,
             "input_tokens_details" => %{"cached_tokens" => 0},
             "output_tokens_details" => %{"reasoning_tokens" => 2}
           } =
             Usage.normalize(%{
               "input_tokens" => -1,
               "prompt_tokens" => 4,
               "output_tokens" => "3",
               "total_tokens" => 0,
               "input_tokens_details" => %{"cached_tokens" => 0},
               "cached_tokens" => 8,
               "output_tokens_details" => %{"reasoning_tokens" => -1},
               "reasoning_tokens" => 2
             })

    assert Usage.total_tokens(nil) == 0
    assert Usage.normalize(nil) == Usage.normalize(%{})
  end

  test "an explicit total of zero survives normalization while absent and invalid totals use the sum" do
    counts = %{"input_tokens" => 4, "output_tokens" => 3}

    assert Usage.total_tokens(Map.put(counts, "total_tokens", 0)) == 0
    assert Usage.total_tokens(Map.put(counts, "totalTokens", 0)) == 0

    for total <- [nil, -1, "0"] do
      assert Usage.total_tokens(Map.put(counts, "total_tokens", total)) == 7
    end

    assert Usage.total_tokens(counts) == 7
  end

  test "merge canonicalizes legacy token aliases while preserving provider fields and non-token maps" do
    merged =
      Usage.merge(
        %{
          "prompt_tokens" => 10,
          "completion_tokens" => 5,
          "cachedTokens" => 4,
          "cost" => 0.25
        },
        %{
          "input_tokens" => 20,
          "output_tokens" => 8,
          "total_tokens" => 28,
          "output_tokens_details" => %{"reasoning_tokens" => 3}
        }
      )

    assert merged == %{
             "input_tokens" => 30,
             "output_tokens" => 13,
             "total_tokens" => 43,
             "input_tokens_details" => %{"cached_tokens" => 4},
             "output_tokens_details" => %{"reasoning_tokens" => 3},
             "cost" => 0.25
           }

    assert Usage.merge(%{"web_search" => %{"requests" => 1}}, %{
             "web_search" => %{"requests" => 2}
           }) == %{"web_search" => %{"requests" => 3}}
  end

  test "OpenAI cache write lifetimes stay beside the total and the plain input" do
    usage = %{
      "input_tokens" => 12_000,
      "output_tokens" => 40,
      "total_tokens" => 12_040,
      "input_tokens_details" => %{
        "cached_tokens" => 4_000,
        "cache_creation_tokens" => 7_000,
        "cache_creation_30m_tokens" => 3_000,
        "cache_creation_12h_tokens" => 4_000
      }
    }

    assert %{
             input_tokens: 12_000,
             output_tokens: 40,
             cached_input_tokens: 4_000,
             cache_creation_input_tokens: 7_000,
             cache_creation_30m_input_tokens: 3_000,
             cache_creation_12h_input_tokens: 4_000
           } = Usage.counts(usage)

    assert Usage.net_input_tokens(usage) == 1_000
    assert Usage.net_input_tokens(%{"input_tokens" => 10}) == 10

    assert Usage.net_input_tokens(%{
             "input_tokens" => 4,
             "input_tokens_details" => %{"cached_tokens" => 9}
           }) == 0

    assert Usage.net_input_tokens(%{"output_tokens" => 4}) == nil
  end

  test "cache write lifetimes sum across merged rounds without double counting input" do
    round = %{
      "input_tokens" => 1_000,
      "output_tokens" => 10,
      "input_tokens_details" => %{
        "cached_tokens" => 400,
        "cache_creation_tokens" => 300,
        "cache_creation_30m_tokens" => 180,
        "cache_creation_12h_tokens" => 120
      }
    }

    merged = Usage.merge(round, round)

    assert merged["input_tokens"] == 2_000
    assert merged["output_tokens"] == 20

    assert merged["input_tokens_details"] == %{
             "cached_tokens" => 800,
             "cache_creation_tokens" => 600,
             "cache_creation_30m_tokens" => 360,
             "cache_creation_12h_tokens" => 240
           }

    assert Usage.net_input_tokens(merged) == 600
  end
end
