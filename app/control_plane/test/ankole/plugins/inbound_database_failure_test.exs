defmodule Ankole.Plugins.InboundDatabaseFailureTest do
  use ExUnit.Case, async: false

  alias Ankole.Conversations.AdapterContext
  alias Ankole.Plugins.LineAdapter.Inbound, as: LineInbound
  alias Ankole.Plugins.TelegramAdapter.Inbound, as: TelegramInbound

  setup do
    # Do not borrow a shared owner left by the previous serial case.
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Ankole.Repo, :manual)
  end

  # No Sandbox checkout: the real Repo adapter rejects both lookups.
  # A database error must not become a successful negative lookup.
  test "LINE quote lookup propagates database failures" do
    consumer = LineInbound.chat_consumer(context("line"), %{})

    envelope = %{
      "destination" => "bot",
      "event" => %{
        "type" => "message",
        "webhookEventId" => "event",
        "timestamp" => 1_700_000_000_000,
        "source" => %{"type" => "group", "groupId" => "group", "userId" => "user"},
        "message" => %{
          "id" => "message",
          "type" => "text",
          "text" => "A reply",
          "quotedMessageId" => "prior-message"
        }
      }
    }

    # The lookup reads through the Conversations domain, so Ash wraps the error.
    Ankole.Repo.with_tenant(Ankole.Ecto.UUIDv7.autogenerate(), fn ->
      assert_raise Ash.Error.Unknown, ~r/DBConnection.OwnershipError/, fn ->
        LineInbound.normalize_message_receive(envelope, consumer)
      end
    end)
  end

  test "Telegram topic lookup propagates database failures before a reaction is accepted" do
    consumer = TelegramInbound.chat_consumer(context("telegram"), %{})

    update = %{
      "update_id" => 10,
      "bot" => %{id: "77"},
      "message_reaction" => %{
        "message_id" => 7,
        "chat" => %{"id" => -100_501},
        "user" => %{"id" => 102, "is_bot" => false},
        "old_reaction" => [],
        "new_reaction" => [%{"type" => "emoji", "emoji" => "👍"}]
      }
    }

    # The lookup reads through the Conversations domain, so Ash wraps the error.
    Ankole.Repo.with_tenant(Ankole.Ecto.UUIDv7.autogenerate(), fn ->
      assert_raise Ash.Error.Unknown, ~r/DBConnection.OwnershipError/, fn ->
        TelegramInbound.handle_reaction_update("message_reaction", update, [consumer])
      end
    end)
  end

  defp context(adapter) do
    AdapterContext.new(
      binding_id: Ecto.UUID.generate(),
      agent_uid: "agent",
      binding_name: "main",
      adapter: adapter,
      user_name: adapter
    )
  end
end
