defmodule Ankole.AIGateway.ConsoleQueriesTest do
  use Ankole.DataCase, async: true

  alias Ankole.AIGateway.ConsoleQueries
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.BackgroundAgentJobs
  alias Ankole.PrincipalsFixtures
  alias Ankole.Repo
  alias Ankole.SignalsGateway.Channel

  describe "list_conversations/1 with min_messages" do
    test "keeps only conversations at or above the message threshold" do
      %{principal: agent} = PrincipalsFixtures.agent_fixture()
      empty = conversation_fixture(agent.uid, "signal-channel:lark:oc_empty")
      stub = conversation_fixture(agent.uid, "signal-channel:lark:oc_stub")
      full = conversation_fixture(agent.uid, "signal-channel:lark:oc_full")
      message_fixture(stub)
      message_fixture(full)
      message_fixture(full)

      assert {:ok, page} =
               ConsoleQueries.list_conversations(subject_uid: agent.uid, min_messages: 2)

      assert Enum.map(page.conversations, & &1.id) == [full.id]

      assert {:ok, page} =
               ConsoleQueries.list_conversations(subject_uid: agent.uid, min_messages: 1)

      assert page.conversations |> Enum.map(& &1.id) |> Enum.sort() ==
               [stub.id, full.id] |> Enum.sort()

      assert {:ok, all} = ConsoleQueries.list_conversations(subject_uid: agent.uid)

      assert all.conversations |> Enum.map(& &1.id) |> Enum.sort() ==
               [empty.id, stub.id, full.id] |> Enum.sort()
    end
  end

  describe "list_conversations/1 with a search" do
    test "matches an exact subject UID, key fragments, and displayed names" do
      %{principal: agent} = PrincipalsFixtures.agent_fixture()
      %{principal: peer} = PrincipalsFixtures.human_fixture(%{display_name: "Boris"})

      channel_fixture("lark:oc_market", kind: :im_group, name: "Ankole 用户群")
      channel_fixture("lark:oc_dm", kind: :im_dm, name: nil)

      group =
        conversation_fixture(agent.uid, "signal-channel:lark:oc_market", %{
          metadata: %{
            "brain" => %{"channel_id" => "lark:oc_market", "channel_kind" => "im_group"}
          }
        })

      dm =
        conversation_fixture(agent.uid, "signal-channel:lark:oc_dm", %{
          metadata: %{
            "brain" => %{
              "channel_id" => "lark:oc_dm",
              "channel_kind" => "im_dm",
              "peer_uid" => peer.uid
            }
          }
        })

      job = conversation_fixture(agent.uid, BackgroundAgentJobs.job_session_id(2000))
      decoy = conversation_fixture(agent.uid, "signal-channel:lark:ocXmarket")

      assert {:ok, page} = ConsoleQueries.list_conversations(search: "用户群")
      assert Enum.map(page.conversations, & &1.id) == [group.id]

      assert {:ok, page} = ConsoleQueries.list_conversations(search: "Bori")
      assert Enum.map(page.conversations, & &1.id) == [dm.id]

      # `_` matches only itself, not any character.
      assert {:ok, page} = ConsoleQueries.list_conversations(search: "oc_market")
      assert Enum.map(page.conversations, & &1.id) == [group.id]

      # Subject input matches regardless of case; stored UIDs are lowercase.
      assert {:ok, page} = ConsoleQueries.list_conversations(search: String.upcase(agent.uid))

      assert page.conversations |> Enum.map(& &1.id) |> Enum.sort() ==
               [group.id, dm.id, job.id, decoy.id] |> Enum.sort()

      assert {:ok, page} = ConsoleQueries.list_conversations(search: "  ")
      assert length(page.conversations) == 4
    end
  end

  describe "console_projection/1 for conversations" do
    test "counts the conversation's messages" do
      %{principal: agent} = PrincipalsFixtures.agent_fixture()

      conversation =
        conversation_fixture(agent.uid, BackgroundAgentJobs.job_session_id(1000))

      message_fixture(conversation)
      message_fixture(conversation)

      projection = conversation |> reload() |> ConsoleQueries.console_projection()

      assert projection.message_count == 2
      assert projection.kind == "job"
      assert projection.display_name == nil
      assert projection.channel_kind == nil
      assert projection.signal_adapter == nil
    end

    test "uses the group name and lark adapter instead of the server domain" do
      %{principal: agent} = PrincipalsFixtures.agent_fixture()

      channel_fixture("lark:oc_named",
        kind: :im_group,
        name: "Ankole 用户群",
        metadata: %{"domain" => "feishu"}
      )

      conversation =
        conversation_fixture(agent.uid, "signal-channel:lark:oc_named", %{
          metadata: %{
            "brain" => %{
              "channel_id" => "lark:oc_named",
              "channel_kind" => "im_group",
              "visibility" => "public"
            }
          }
        })

      projection = conversation |> reload() |> ConsoleQueries.console_projection()

      assert projection.kind == "signal"
      assert projection.display_name == "Ankole 用户群"
      assert projection.channel_kind == "im_group"
      assert projection.signal_adapter == "lark"
    end

    test "uses the peer display name instead of a DM channel name" do
      %{principal: agent} = PrincipalsFixtures.agent_fixture()
      %{principal: peer} = PrincipalsFixtures.human_fixture(%{display_name: "Boris"})
      channel_fixture("lark:oc_dm", kind: :im_dm, name: "Provider DM")

      conversation =
        conversation_fixture(agent.uid, "signal-channel:lark:oc_dm", %{
          metadata: %{
            "brain" => %{
              "channel_id" => "lark:oc_dm",
              "channel_kind" => "im_dm",
              "peer_uid" => peer.uid,
              "visibility" => "dm"
            }
          }
        })

      projection = conversation |> reload() |> ConsoleQueries.console_projection()

      assert projection.display_name == "Boris"
      assert projection.channel_kind == "im_dm"
      assert projection.signal_adapter == "lark"
    end

    test "falls back to the bare peer uid when the peer has no display name" do
      %{principal: agent} = PrincipalsFixtures.agent_fixture()
      channel_fixture("lark:oc_ghost", kind: :im_dm, name: nil)

      conversation =
        conversation_fixture(agent.uid, "signal-channel:lark:oc_ghost", %{
          metadata: %{
            "brain" => %{
              "channel_id" => "lark:oc_ghost",
              "channel_kind" => "im_dm",
              "peer_uid" => "ghost",
              "visibility" => "dm"
            }
          }
        })

      projection = conversation |> reload() |> ConsoleQueries.console_projection()

      assert projection.display_name == "ghost"
    end

    test "dreaming rooms resolve a peer label but carry no signal tags" do
      %{principal: agent} = PrincipalsFixtures.agent_fixture()
      %{principal: peer} = PrincipalsFixtures.human_fixture(%{display_name: "Boris"})
      channel_fixture("lark:oc_dm", kind: :im_dm, name: nil)
      run_id = Ecto.UUID.generate()

      conversation =
        conversation_fixture(agent.uid, "brain.dreaming:#{run_id}:dm:#{peer.uid}", %{
          metadata: %{
            "brain" => %{
              "channel_id" => "lark:oc_dm",
              "channel_kind" => "im_dm",
              "peer_uid" => peer.uid,
              "visibility" => "dm"
            }
          }
        })

      projection = conversation |> reload() |> ConsoleQueries.console_projection()

      assert projection.kind == "dreaming"
      assert projection.display_name == "Boris"
      assert projection.channel_kind == nil
      assert projection.signal_adapter == nil
    end
  end

  describe "console_projections/1" do
    test "decorates a mixed page in batch" do
      %{principal: agent} = PrincipalsFixtures.agent_fixture()
      channel_fixture("lark:oc_batch", kind: :im_group, name: "批量群")

      named =
        conversation_fixture(agent.uid, "signal-channel:lark:oc_batch", %{
          metadata: %{
            "brain" => %{
              "channel_id" => "lark:oc_batch",
              "channel_kind" => "im_group",
              "visibility" => "public"
            }
          }
        })

      plain = conversation_fixture(agent.uid, "brain.dreaming:#{Ecto.UUID.generate()}:public")
      message_fixture(named)

      projections = ConsoleQueries.console_projections([reload(named), reload(plain)])

      assert [%{display_name: "批量群", message_count: 1}, %{display_name: nil, message_count: 0}] =
               projections
    end
  end

  defp reload(conversation), do: ConsoleQueries.get_conversation(conversation.id)

  defp conversation_fixture(subject_uid, key, attrs \\ %{}) do
    %Conversation{}
    |> Conversation.changeset(
      Map.merge(%{subject_uid: subject_uid, conversation_key: key, metadata: %{}}, Map.new(attrs))
    )
    |> Repo.insert!()
  end

  defp message_fixture(conversation) do
    %Message{}
    |> Message.changeset(%{
      subject_uid: conversation.subject_uid,
      conversation_id: conversation.id,
      role: "user",
      type: "message",
      status: "complete",
      content: [%{"type" => "text", "text" => "hi"}],
      metadata: %{}
    })
    |> Repo.insert!()
  end

  defp channel_fixture(id, attrs) do
    now = DateTime.utc_now()

    %Channel{}
    |> Channel.changeset(
      Map.merge(
        %{
          id: id,
          kind: :im_group,
          reply_mode: :entry,
          name: id,
          metadata: %{},
          raw_payload: %{},
          first_seen_at: now,
          last_seen_at: now
        },
        Map.new(attrs)
      )
    )
    |> Repo.insert!()
  end
end
