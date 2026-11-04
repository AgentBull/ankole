defmodule Ankole.Conversations.ReplySuggestionTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Ecto.Query

  alias Ankole.AIGateway.{ModelProfiles, ProviderConfigs}
  alias Ankole.Conversations
  alias Ankole.Conversations.{NativeRoom, ReplySuggestion}
  alias Ankole.Signals.Signal

  setup do
    alice = human_fixture(%{display_name: "Alice"}).principal
    bob = human_fixture(%{display_name: "Bob"}).principal
    agent = agent_fixture(%{owner_principal_uid: alice.uid, display_name: "Planner"}).principal

    for human <- [alice, bob], do: Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)

    id = Ash.UUIDv7.generate()

    {:ok, _} =
      Ankole.ConversationsFixtures.create(alice.uid, %{
        conversation_id: id,
        message_id: Ash.UUIDv7.generate(),
        agent_uid: agent.uid,
        room_mode: :group,
        text: "Draft the restock plan"
      })

    %{alice: alice, bob: bob, agent: agent, id: id, actor: actor_fixture(alice.uid)}
  end

  test "after an Agent reply the only Human gets one line drafted by that Agent", ctx do
    owner = self()

    configure_model(ctx.agent.uid, fn request ->
      send(owner, {:suggestion_request, request.body})
      {:json, 200, response(%{"suggestion" => "  Split the order by warehouse  "})}
    end)

    reply = agent_reply!(ctx, "The plan is ready. Should I split it by warehouse?")

    assert {:ok, %{message_id: message_id, text: "Split the order by warehouse"}} =
             Conversations.reply_suggestion(ctx.actor, ctx.id, locale: "en-US")

    assert message_id == reply.id
    assert_receive {:suggestion_request, body}
    text = body["input"] |> hd() |> Map.fetch!("content") |> hd() |> Map.fetch!("text")
    assert text =~ "Human: Draft the restock plan"
    assert text =~ "Planner: The plan is ready."
    assert body["instructions"] =~ "language the Human writes in this conversation"
    assert body["instructions"] =~ "en-US"
  end

  test "a room with another Human or a latest Human message asks no model", ctx do
    owner = self()

    configure_model(ctx.agent.uid, fn _request ->
      send(owner, :suggestion_requested)
      {:json, 200, response(%{"suggestion" => "Unexpected"})}
    end)

    assert {:ok, %{text: nil}} = ReplySuggestion.suggest(ctx.actor, ctx.id)

    agent_reply!(ctx, "Done.")
    assert {:ok, _} = NativeRoom.manage(ctx.actor, ctx.id, %{add_uids: [ctx.bob.uid]})
    assert ctx.bob.uid in Enum.map(NativeRoom.participants(ctx.id), & &1.principal_uid)
    assert {:ok, %{text: nil}} = ReplySuggestion.suggest(ctx.actor, ctx.id)
    refute_receive :suggestion_requested, 50
  end

  test "a Human outside the room cannot ask for a suggestion", ctx do
    carol = human_fixture(%{display_name: "Carol"}).principal
    assert {:error, :not_found} = ReplySuggestion.suggest(actor_fixture(carol.uid), ctx.id)
  end

  test "only one new line that does not echo the Human is usable" do
    assert ReplySuggestion.usable(" Send it ", "Draft it") == "Send it"
    assert ReplySuggestion.usable("Draft it", "draft it ") == nil
    assert ReplySuggestion.usable("First\nSecond", nil) == nil
    assert ReplySuggestion.usable(String.duplicate("a", 121), nil) == nil
    assert ReplySuggestion.usable(nil, nil) == nil
  end

  defp agent_reply!(ctx, text) do
    signal = Repo.one!(from s in Signal, where: s.conversation_id == ^ctx.id, limit: 1)

    {:ok, message} =
      Repo.transact(fn ->
        conversation = Conversations.get_conversation!(ctx.id)
        {:ok, conversation} = Ankole.Ash.update(conversation, :advance_notifiable_sequence, %{})

        Ankole.Ash.create(Ankole.Conversations.Message, :record, %{
          id: Ash.UUIDv7.generate(),
          conversation_id: ctx.id,
          seq: conversation.sequence_high_water,
          author_type: :agent,
          author_uid: ctx.agent.uid,
          text: text,
          signal_id: signal.id,
          origin: :native,
          session_id: signal.session_id,
          created_at: DateTime.utc_now(:microsecond)
        })
      end)

    message
  end

  defp configure_model(agent_uid, handler) do
    base_url = Ankole.AIGatewayCase.start_upstream_server(handler)

    assert {:ok, _} =
             ProviderConfigs.create_provider(%{
               provider_id: "reply-suggestion",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{"entries" => [%{"label" => "Test", "api_key" => "sk-test"}]}
             })

    assert {:ok, _} =
             ModelProfiles.put_model_profile(agent_uid, "light", %{
               provider_id: "reply-suggestion",
               model: "gpt-5.5"
             })
  end

  defp response(value) do
    %{
      "id" => "resp_reply_suggestion",
      "object" => "response",
      "status" => "completed",
      "output" => [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => Ankole.JSON.encode!(value)}]
        }
      ],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 10}
    }
  end
end
