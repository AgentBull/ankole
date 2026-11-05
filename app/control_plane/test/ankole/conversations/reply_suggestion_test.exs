defmodule Ankole.Conversations.ReplySuggestionTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Ecto.Query

  alias Ankole.AIGateway.{ModelProfiles, ProviderConfigs}
  alias Ankole.{BackgroundAgentJobs, Conversations, Workflow}
  alias Ankole.Conversations.{Executions, NativeRoom, Peers, ReplySuggestion}
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

  test "a room with active session work, a Background Agent Job, a Workflow, or a peer exchange asks no model",
       ctx do
    owner = self()

    configure_model(ctx.agent.uid, fn _request ->
      send(owner, :suggestion_requested)
      {:json, 200, response(%{"suggestion" => "Paste the rebuilt webhook token"})}
    end)

    source = Repo.one!(from s in Signal, where: s.conversation_id == ^ctx.id, limit: 1)

    # An interim Agent reply while the room's own Signal is still running/queued does not predict.
    interim =
      agent_reply!(ctx, "Working on it...", complete_signal?: false, delivery_key: "interim")

    assert {:ok, %{message_id: message_id, text: nil}} =
             Conversations.reply_suggestion(ctx.actor, ctx.id, locale: "en-US")

    assert message_id == interim.id
    refute_receive :suggestion_requested, 50

    reply = agent_reply!(ctx, "Rebuilding the webhook now; I will paste the token once done.")

    # A live Background Agent Job suppresses prediction until it settles.
    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "source_signal_id" => source.id,
               "agent_uid" => ctx.agent.uid,
               "owner_session_id" => source.session_id,
               "source_tool_call_id" => "reply-suggestion-job",
               "title" => "Build waitlist management app and webhook auth",
               "task" => "Revoke the old webhook and create a new one.",
               "created_by" => %{"type" => "human", "uid" => ctx.alice.uid},
               "reply_route" => %{"conversation_id" => ctx.id}
             })

    reply_id = reply.id

    assert {:ok, %{message_id: ^reply_id, text: nil}} =
             Conversations.reply_suggestion(ctx.actor, ctx.id, locale: "en-US")

    refute_receive :suggestion_requested, 50

    assert {:ok, %{status: "stopped"}} =
             Executions.stop(ctx.actor, ctx.id, :background_agent_job, job.id)

    assert {:ok, %{message_id: reply_id, text: "Paste the rebuilt webhook token"}} =
             Conversations.reply_suggestion(ctx.actor, ctx.id, locale: "en-US")

    assert reply_id == reply.id
    assert_receive :suggestion_requested

    # A running Workflow also suppresses prediction until stopped.
    assert {:ok, %{run: workflow}} =
             Workflow.create_with_dispatch(%{
               "source_signal_id" => source.id,
               "agent_uid" => ctx.agent.uid,
               "owner_session_id" => source.session_id,
               "source_tool_call_id" => "reply-suggestion-workflow",
               "reply_route" => %{"conversation_id" => ctx.id},
               "title" => "Rotate webhook endpoints",
               "script" => "return null;",
               "concurrency" => 1,
               "max_agent_calls" => 4
             })

    Ankole.SessionsCase.stub_workflow_drivers(workflow)

    assert {:ok, %{text: nil}} =
             Conversations.reply_suggestion(ctx.actor, ctx.id, locale: "en-US")

    refute_receive :suggestion_requested, 50

    assert {:ok, %{status: "cancelled"}} =
             Executions.stop(ctx.actor, ctx.id, :workflow, workflow.id)

    assert {:ok, %{text: "Paste the rebuilt webhook token"}} =
             Conversations.reply_suggestion(ctx.actor, ctx.id, locale: "en-US")

    assert_receive :suggestion_requested

    # A delegated colleague exchange running in the background also suppresses prediction.
    assistant =
      agent_fixture(%{
        owner_principal_uid: ctx.alice.uid,
        display_name: "Assistant",
        type: :personal_assistant
      }).principal

    colleague =
      agent_fixture(%{owner_principal_uid: ctx.alice.uid, display_name: "Reviewer"}).principal

    Ankole.ConversationsFixtures.grant_chat(ctx.alice.uid, colleague.uid)

    task_id = Ash.UUIDv7.generate()

    {:ok, _} =
      Ankole.ConversationsFixtures.create(ctx.alice.uid, %{
        conversation_id: task_id,
        message_id: Ash.UUIDv7.generate(),
        agent_uid: assistant.uid,
        room_mode: :dm,
        text: "Ask Reviewer to audit the contract"
      })

    configure_model(assistant.uid, fn _request ->
      send(owner, :assistant_suggestion_requested)
      {:json, 200, response(%{"suggestion" => "Send the summary"})}
    end)

    task_signal = Repo.one!(from s in Signal, where: s.conversation_id == ^task_id, limit: 1)

    {:ok, peer_id} =
      Repo.transact_top_level(fn ->
        run = %{
          agent_uid: assistant.uid,
          session_id: task_signal.session_id,
          signal_id: task_signal.id,
          event: task_signal,
          peer_call_id: "#{task_signal.id}:peer-1"
        }

        {:ok, keys, commit} =
          Peers.prepare_send(run, %{
            "target_agent_uid" => colleague.uid,
            "message" => "Audit the contract clauses"
          })

        :ok = Ankole.Sessions.Queue.lock_sessions_in_tx(keys)
        {:ok, %{details: %{exchange_id: exchange_id}}, _publications} = commit.()
        {:ok, exchange_id}
      end)

    agent_reply!(
      %{id: task_id, agent: assistant},
      "I handed the contract to Reviewer and will report back once ready."
    )

    assert {:ok, %{text: nil}} =
             Conversations.reply_suggestion(ctx.actor, task_id, locale: "en-US")

    refute_receive :assistant_suggestion_requested, 50

    assert {:ok, _} = Peers.stop(ctx.actor, task_id, peer_id)

    assert {:ok, %{text: "Send the summary"}} =
             Conversations.reply_suggestion(ctx.actor, task_id, locale: "en-US")

    assert_receive :assistant_suggestion_requested
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

  defp agent_reply!(ctx, text, opts \\ []) do
    complete_signal? = Keyword.get(opts, :complete_signal?, true)
    delivery_key = Keyword.get(opts, :delivery_key, "final")
    signal = Repo.one!(from s in Signal, where: s.conversation_id == ^ctx.id, limit: 1)

    {:ok, message} =
      Repo.transact(fn ->
        now = DateTime.utc_now(:microsecond)
        :ok = Ankole.Sessions.Queue.lock_session_in_tx(signal.agent_uid, signal.session_id)

        if complete_signal? do
          {:ok, _} = Ankole.Sessions.Queue.mark_event_completed_in_tx(signal, now)
        end

        conversation = Conversations.get_conversation!(ctx.id)
        {:ok, conversation} = Ankole.Ash.update(conversation, :advance_notifiable_sequence, %{})

        Ankole.Ash.create(Ankole.Conversations.Message, :record, %{
          id: Ash.UUIDv7.generate(),
          conversation_id: ctx.id,
          seq: conversation.sequence_high_water,
          author_type: :agent,
          author_uid: ctx.agent.uid,
          delivery_key: delivery_key,
          text: text,
          signal_id: signal.id,
          origin: :native,
          session_id: signal.session_id,
          created_at: now
        })
      end)

    message
  end

  defp configure_model(agent_uid, handler) do
    base_url = Ankole.AIGatewayCase.start_upstream_server(handler)

    background_url =
      Ankole.AIGatewayCase.start_upstream_server(fn _request ->
        {:json, 200, response(%{"ok" => true})}
      end)

    provider_id = "reply-suggestion-#{agent_uid}"
    background_provider_id = "reply-suggestion-bg-#{agent_uid}"

    for {id, url} <- [{provider_id, base_url}, {background_provider_id, background_url}] do
      assert {:ok, _} =
               ProviderConfigs.create_provider(%{
                 provider_id: id,
                 provider_kind: "openai",
                 base_url: "#{url}/v1",
                 credential_pool: %{"entries" => [%{"label" => "Test", "api_key" => "sk-test"}]}
               })
    end

    assert {:ok, _} =
             ModelProfiles.put_model_profile(agent_uid, "light", %{
               provider_id: provider_id,
               model: "gpt-5.5"
             })

    for profile <- ["primary", "heavy"] do
      assert {:ok, _} =
               ModelProfiles.put_model_profile(agent_uid, profile, %{
                 provider_id: background_provider_id,
                 model: "gpt-5.5"
               })
    end
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
