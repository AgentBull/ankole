defmodule Ankole.Sessions.AmbientTest do
  use Ankole.DataCase, async: true
  import Ankole.PrincipalsFixtures
  alias Ankole.Sessions.Ambient
  alias Ankole.Signals.Signal

  @now ~U[2026-07-18 12:05:00Z]

  test "the observation uses execution time, standing orders, backdrop, and new-message ids (G4)" do
    {input, schema, _delta, true} = Ambient.observation(run([row("msg-2", "Bob")]), @now)
    assert input =~ "current_time: 2026-07-18 12:05"
    assert input =~ "Only speak when CI turns red."
    assert input =~ "Yesterday the deploy went fine."
    assert input =~ "[id:msg-2]"
    refute input =~ "[id:msg-0]"
    assert schema["properties"]["asked_by"]["enum"] == ["msg-2", nil]
  end

  test "HANDOFF can name only an exact complete candidate (G4)" do
    run = run([row("msg-1", "Alice")])

    assert decide(run, %{"action" => "HANDOFF", "handoff_job_id" => "1001"})["action"] ==
             "HANDOFF"

    assert decide(run, %{"action" => "HANDOFF", "handoff_job_id" => "1002"})["action"] == "NOOP"
    assert decide(run, %{"action" => "NEW_WORK", "handoff_job_id" => "1001"})["action"] == "NOOP"

    run = put_in(run.spec.request_context["ambient_work_candidates"]["complete"], false)
    {input, schema, _, _} = Ambient.observation(run, @now)
    assert input =~ "The list is incomplete; HANDOFF is unavailable."
    assert input =~ "Investigate deploy failure"
    refute "HANDOFF" in schema["properties"]["action"]["enum"]
    assert decide(run, %{"action" => "HANDOFF", "handoff_job_id" => "1001"})["action"] == "NOOP"
  end

  test "fallback context cannot grant HANDOFF even when a candidate list says complete (G4)" do
    run = run([])
    run = put_in(run.event.data["unreplied_messages"], [row("msg-1", "Alice")])
    {input, schema, _, _} = Ambient.observation(run, @now)
    assert input =~ "Investigate deploy failure"
    refute "HANDOFF" in schema["properties"]["action"]["enum"]
  end

  test "NEW_WORK authority needs a current human ask or standing orders (G4)" do
    alice = row("msg-1", "Alice")
    bob = row("msg-2", "Bob")
    base = %{"action" => "NEW_WORK", "authority" => "EXPLICIT_REQUEST", "asked_by" => "msg-1"}
    accepted = decide(run([alice]), base)
    assert accepted["authority"] == "EXPLICIT_REQUEST"
    assert accepted["asked_by_state"] == "accepted"
    assert decide(run([alice, row("msg-2", "Alice")]), base)["authority"] == "EXPLICIT_REQUEST"

    stale = decide(run([alice, bob]), base)
    assert stale["authority"] == "NONE"
    assert stale["asked_by_state"] == "degraded"
    assert stale["reason"] =~ "not present in the current ambient observation"

    assert decide(run([Map.put(alice, "role", "agent")]), base)["authority"] == "NONE"
    assert decide(run([alice]), Map.put(base, "asked_by", "missing"))["action"] == "NOOP"

    orders = %{"action" => "NEW_WORK", "authority" => "STANDING_ORDER"}
    assert decide(run([alice]), orders)["authority"] == "STANDING_ORDER"
    no_orders = run([alice])
    room = Repo.get_by!(Ankole.Conversations.Conversation, id: no_orders.event.conversation_id)
    Repo.update!(Ecto.Changeset.change(room, ambient_standing_orders: ""))
    assert decide(no_orders, orders)["action"] == "NOOP"
  end

  test "a bounded reply strips authority without changing its reason or anchor (G4)" do
    value =
      decide(run([row("msg-1", "Alice")]), %{
        "action" => "FOREGROUND_REPLY",
        "authority" => "EXPLICIT_REQUEST",
        "asked_by" => "msg-1"
      })

    assert value["authority"] == "NONE"
    assert value["reason"] == "Chosen route."
    assert value["asked_by_message_id"] == "msg-1"
  end

  test "invalid structured routes stay silent (G4)" do
    for overrides <- [
          %{"reason" => "   "},
          %{"reason" => String.duplicate("x", 301)},
          %{"action" => "SPEAK"},
          %{"extra" => true},
          %{"authority" => "operator"}
        ] do
      assert decide(run([row("msg-1", "Alice")]), overrides)["action"] == "NOOP"
    end

    assert decide(run([]), %{"reason" => "  Chosen route.  "})["reason"] == "Chosen route."
  end

  defp decide(run, overrides) do
    {_input, schema, delta, orders?} = Ambient.observation(run, @now)

    value =
      Map.merge(
        %{
          "action" => "NOOP",
          "authority" => "NONE",
          "handoff_job_id" => nil,
          "asked_by" => nil,
          "reason" => "Chosen route."
        },
        overrides
      )

    Ambient.decision(Ankole.JSON.encode!(value), schema, delta, orders?)
  end

  defp row(id, speaker),
    do: %{
      "message_id" => id,
      "sent_at" => "2026-07-18T12:00:00Z",
      "speaker" => speaker,
      "role" => "human",
      "text" => "Bot, can you check CI?"
    }

  defp run(messages) do
    %{principal: agent} = agent_fixture()
    %{principal: human} = human_fixture()

    assert {:ok, _} =
             Ankole.Signals.Bindings.upsert_binding(%{
               agent_uid: agent.uid,
               name: "room",
               adapter: "lark",
               config_ref: "app-config://ambient-test",
               filters: %{},
               target: %{},
               unaddressed_group_message_policy: :may_intervene
             })

    assert {:ok, room} =
             Repo.transact(
               &Ankole.Conversations.External.observe_conversation_in_tx(
                 &1,
                 %{agent_uid: agent.uid},
                 %{
                   provider_conversation_id: "room:#{Ecto.UUID.generate()}",
                   external_kind: :im_group,
                   title: "Ops",
                   reply_mode: :entry
                 },
                 @now
               )
             )

    Repo.update!(
      Ecto.Changeset.change(room, ambient_standing_orders: "Only speak when CI turns red.")
    )

    assert {:ok, %{message: message}} =
             Repo.transact(
               &Ankole.Conversations.External.observe_in_tx(
                 &1,
                 room.id,
                 %{
                   provider_message_id: "current",
                   text: "Current ambient message",
                   author: %{"principal_uid" => human.uid}
                 },
                 @now
               )
             )

    %{
      event: %Signal{
        producer: :kernel,
        agent_uid: agent.uid,
        conversation_id: room.id,
        message_id: message.id,
        reply_binding_name: "room",
        type: "im.message.may_intervene",
        data: %{
          "observed_messages" => messages,
          "backdrop_messages" => [
            %{"text" => "Yesterday the deploy went fine.", "message_id" => "msg-0"}
          ]
        }
      },
      context: %{
        conversation: %{timezone: "UTC", origin_channel: %{adapter: "lark", label: "Ops"}}
      },
      spec: %{
        request_context: %{
          "ambient_work_candidates" => %{
            "complete" => true,
            "jobs" => [
              %{
                "job_id" => "1001",
                "status" => "running",
                "title" => "Investigate deploy failure"
              }
            ]
          }
        }
      }
    }
  end
end
