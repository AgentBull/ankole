defmodule Ankole.Plugins.ReplyPreviewSurfaceTest do
  @moduledoc false
  # Each reply-preview module owns the checkpoint keys that name its provider
  # surface. The host asks `surface_ids/1` and `surface_open?/1` and never reads
  # provider vocabulary itself, so these cases pin what each adapter answers
  # for its own ledger shape.
  use ExUnit.Case, async: true

  alias Ankole.Plugins.DingTalkAdapter.AICard
  alias Ankole.Plugins.DiscordAdapter.ReplyPreview, as: DiscordPreview
  alias Ankole.Plugins.LarkAdapter.CardKit
  alias Ankole.Plugins.SlackAdapter.ReplyPreview, as: SlackPreview
  alias Ankole.Plugins.TelegramAdapter.ReplyPreview, as: TelegramPreview
  alias Ankole.Plugins.WeComAdapter.AIStream
  alias Ankole.SignalsGateway.ReplyPreviewAdapter

  describe "message ledgers (slack, discord, telegram)" do
    for module <- [SlackPreview, DiscordPreview, TelegramPreview] do
      @module module

      test "#{inspect(module)} names every message as an entry and reads streaming_state" do
        ledger = %{
          "message_id" => "m1",
          "messages" => [
            %{"index" => 1, "message_id" => "m2"},
            %{"index" => 0, "message_id" => "m1"}
          ],
          "streaming_state" => "open"
        }

        assert @module.surface_ids(ledger) == [{:entry, "m1"}, {:entry, "m2"}]
        assert @module.surface_open?(ledger)

        assert @module.surface_ids(%{"message_id" => "legacy"}) == [{:entry, "legacy"}]
        assert @module.surface_ids(%{}) == []
        refute @module.surface_open?(Map.put(ledger, "streaming_state", "closed"))
      end
    end
  end

  test "lark names card ids as handles and card messages as entries" do
    chain = %{
      "card_id" => "card-b",
      "message_id" => "om_b",
      "active_card_index" => 1,
      "streaming_state" => "closed",
      "cards" => [
        %{
          "index" => 0,
          "card_id" => "card-a",
          "message_id" => "om_a",
          "streaming_state" => "closed"
        },
        %{
          "index" => 1,
          "card_id" => "card-b",
          "message_id" => "om_b",
          "streaming_state" => "open"
        }
      ]
    }

    assert CardKit.surface_ids(chain) == [
             {:handle, "card-a"},
             {:entry, "om_a"},
             {:handle, "card-b"},
             {:entry, "om_b"}
           ]

    assert CardKit.surface_open?(chain)

    unsent = %{"card_id" => "card-unsent", "streaming_state" => "open"}
    assert CardKit.surface_ids(unsent) == [{:handle, "card-unsent"}]
    assert CardKit.surface_open?(unsent)
    assert CardKit.surface_ids(%{}) == []
    refute CardKit.surface_open?(Map.put(chain, "cards", []) |> Map.delete("card_id"))
  end

  test "dingtalk names page card instances as entries" do
    ledger = %{
      "streaming_state" => "open",
      "pages" => [
        %{"index" => 0, "out_track_id" => "ankole:e:0", "sealed" => true},
        %{"index" => 1, "out_track_id" => "ankole:e:1", "sealed" => false}
      ]
    }

    assert AICard.surface_ids(ledger) == [{:entry, "ankole:e:0"}, {:entry, "ankole:e:1"}]
    assert AICard.surface_open?(ledger)
    assert AICard.surface_ids(%{"degraded" => true}) == []
    refute AICard.surface_open?(Map.put(ledger, "streaming_state", "closed"))
  end

  test "wecom names page stream messages as entries" do
    ledger = %{
      "streaming_state" => "closed",
      "pages" => [%{"index" => 0, "stream_id" => "ankole:e:0", "sealed" => true}]
    }

    assert AIStream.surface_ids(ledger) == [{:entry, "ankole:e:0"}]
    refute AIStream.surface_open?(ledger)
    assert AIStream.surface_ids(%{}) == []
  end

  test "the host derives entries and presence from the adapter answer" do
    {:ok, adapter} = ReplyPreviewAdapter.from_module(CardKit)
    chain = %{"card_id" => "card-a", "message_id" => "om_a"}

    assert ReplyPreviewAdapter.surface_entry_ids(adapter, chain) == ["om_a"]
    assert ReplyPreviewAdapter.surface?(adapter, chain)
    refute ReplyPreviewAdapter.surface?(adapter, %{})
    assert ReplyPreviewAdapter.surface_entry_ids(nil, chain) == []
    refute ReplyPreviewAdapter.surface_open?(nil, chain)
  end
end
