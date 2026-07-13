defmodule Ankole.Brain.RuntimeTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.Conversations
  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.RPCBroker
  alias Ankole.Brain.RuntimeContext
  alias Ankole.Brain.Scope
  alias Ankole.Brain.Snapshot
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SubagentDelegations.Schemas.Delegation

  test "conversation snapshot auto-creates the pinned memo and remains frozen" do
    %{principal: agent} = agent_fixture()

    {:ok, conversation} =
      Conversations.ensure_conversation(agent.uid, "brain-snapshot-root",
        metadata: %{"brain" => %{"visibility" => "public"}}
      )

    assert {:ok, first} = Snapshot.get_or_create(conversation)
    assert first["channel_entry"] == nil
    assert first["pinned_memo"]["type"] == "agent_system_pinned_memo"
    refute first["pinned_memo"]["truncated"]

    {:ok, scope} = Scope.for_store(agent.uid, "public")
    pinned_id = first["pinned_memo"]["entry_id"]

    assert {:ok, %{entry: pinned}} = Knowledge.open(scope, pinned_id, block_limit: :all)

    assert {:ok, [bootstrap_audit]} =
             Knowledge.list_audit(scope,
               action: "create_entry",
               entry_id: pinned_id,
               limit: 1
             )

    assert bootstrap_audit.actor_kind == nil
    assert bootstrap_audit.actor_uid == nil
    assert bootstrap_audit.metadata["surface"] == "conversation_snapshot"
    assert bootstrap_audit.metadata["automatic"]

    assert {:ok, _result} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "append_block",
                 entry_id: pinned.id,
                 expected_entry_lock_version: pinned.lock_version,
                 body: "Remember the durable preference"
               },
               %{kind: :agent, uid: agent.uid}
             )

    # The stale caller struct does not bypass the transaction's second check.
    assert {:ok, ^first} = Snapshot.get_or_create(conversation)
    refute first["pinned_memo"]["markdown"] =~ "durable preference"

    {:ok, successor} =
      Conversations.ensure_conversation(agent.uid, "brain-snapshot-successor",
        metadata: %{"brain" => %{"visibility" => "public"}}
      )

    assert {:ok, refreshed} = Snapshot.get_or_create(successor)
    assert refreshed["pinned_memo"]["markdown"] =~ "durable preference"
  end

  test "group snapshot uses channel_id identity and subagents inherit the parent conversation" do
    %{principal: agent} = agent_fixture()
    channel_id = "lark:group:brain-snapshot"
    {:ok, public_scope} = Scope.for_store(agent.uid, "public")

    assert {:ok, %{results: [%{entry_id: entry_id, entry_lock_version: 1}]}} =
             Knowledge.apply_operations(
               public_scope,
               %{
                 operation: "create_entry",
                 name: "Old Channel Display Name",
                 type: "channel",
                 summary: "",
                 properties: %{"channel_id" => channel_id}
               },
               %{kind: :agent, uid: agent.uid}
             )

    assert {:ok, _result} =
             Knowledge.apply_operations(
               public_scope,
               %{
                 operation: "append_block",
                 entry_id: entry_id,
                 expected_entry_lock_version: 1,
                 body: "Channel decisions require an explicit owner"
               },
               %{kind: :agent, uid: agent.uid}
             )

    parent_session = "brain-parent-session"

    {:ok, conversation} =
      Conversations.ensure_conversation(agent.uid, parent_session,
        metadata: %{
          "brain" => %{
            "visibility" => "public",
            "channel_id" => channel_id,
            "channel_kind" => "im_group"
          }
        }
      )

    assert {:ok, parent_snapshot} = Snapshot.get_or_create(conversation)
    assert parent_snapshot["channel_entry"]["entry_id"] == entry_id
    assert parent_snapshot["channel_entry"]["markdown"] =~ "explicit owner"

    delegation =
      %Delegation{}
      |> Delegation.creation_changeset(%{
        agent_uid: agent.uid,
        session_id: parent_session,
        tool_call_id: "brain-subagent-tool-call",
        title: "Brain inheritance",
        task: "Verify inherited Brain snapshot",
        workdir: "/workspace",
        runtime: "codex",
        codex_account_id: "aigateway",
        reply_route: %{"signal_channel_id" => channel_id},
        attempts: 1,
        status: "running",
        result: %{},
        error: %{},
        metadata: %{"brain_parent_conversation_id" => conversation.id}
      })
      |> Repo.insert!()

    conversation
    |> Ecto.Changeset.change(ended_at: DateTime.utc_now(:microsecond))
    |> Repo.update!()

    {:ok, replacement} =
      Conversations.ensure_conversation(agent.uid, parent_session,
        metadata: %{
          "brain" => %{
            "visibility" => "public",
            "channel_id" => channel_id,
            "channel_kind" => "im_group"
          }
        }
      )

    refute replacement.id == conversation.id

    subagent_turn = turn_ref(agent.uid, "subagent:#{delegation.id}")

    assert {:ok, %{conversation: inherited, scope: inherited_scope}} =
             RuntimeContext.resolve(subagent_turn)

    assert inherited.id == conversation.id
    assert inherited_scope.writable_store_key == "public"
    assert {:ok, ^parent_snapshot} = Snapshot.get_or_create(inherited)
  end

  test "RPC derives owner store and author, and opens stable block pages" do
    %{principal: agent} = agent_fixture()
    %{principal: other} = human_fixture()
    session_id = "brain-rpc-session"

    {:ok, _conversation} =
      Conversations.ensure_conversation(agent.uid, session_id,
        metadata: %{"brain" => %{"visibility" => "public"}}
      )

    turn = turn_ref(agent.uid, session_id)

    assert {:ok, create} =
             RPCBroker.handle_update(
               turn,
               %{
                 "request_id" => "brain-create",
                 "operation" => "create_entry",
                 "name" => "RPC Contract",
                 "type" => "fact",
                 "owner_uid" => other.uid,
                 "store_key" => "dm:#{other.uid}",
                 "author_kind" => "human",
                 "author_uid" => other.uid
               },
               "worker-route"
             )

    [created] = create["results"]
    entry_id = created["entry_id"]

    assert {:ok, first_append} =
             RPCBroker.handle_update(
               turn,
               %{
                 "operation" => "append_block",
                 "entry_id" => entry_id,
                 "expected_entry_lock_version" => 1,
                 "body" => "first page"
               },
               "worker-route"
             )

    assert {:ok, _second_append} =
             RPCBroker.handle_update(
               turn,
               %{
                 "operation" => "append_block",
                 "entry_id" => entry_id,
                 "expected_entry_lock_version" =>
                   first_append["results"] |> hd() |> Map.fetch!("entry_lock_version"),
                 "body" => "second page"
               },
               "worker-route"
             )

    assert {:ok, page_one} =
             RPCBroker.handle_open(
               turn,
               %{"entry_id" => entry_id, "block_limit" => 1},
               "worker-route"
             )

    assert page_one["entry"]["owner_uid"] == agent.uid
    assert page_one["entry"]["store_key"] == "public"

    assert [%{"body" => "first page", "author_kind" => "agent", "author_uid" => author}] =
             page_one["blocks"]

    assert author == agent.uid
    assert page_one["history_notice"] =~ "untrusted historical content"
    assert is_binary(page_one["next_block_cursor"])
    assert page_one["markdown"] =~ "first page"
    assert page_one["markdown"] =~ "作者：agent:#{agent.uid}"
    refute page_one["markdown"] =~ "second page"

    assert {:ok, page_two} =
             RPCBroker.handle_open(
               turn,
               %{
                 "entry_id" => entry_id,
                 "block_limit" => 1,
                 "block_cursor" => page_one["next_block_cursor"]
               },
               "worker-route"
             )

    assert [%{"body" => "second page"}] = page_two["blocks"]
    assert page_two["next_block_cursor"] == nil
  end

  defp turn_ref(agent_uid, session_id) do
    %TurnRef{
      agent_uid: agent_uid,
      session_id: session_id,
      activation_uid: "brain-runtime-test",
      actor_epoch: 1,
      actor_event_id: Ecto.UUID.generate(),
      revision: 0
    }
  end
end
