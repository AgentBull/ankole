defmodule Ankole.ConversationsModelPreferencesTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures, only: [human_fixture: 0]
  import Ankole.SessionsCase, only: [agent_fixture: 1]
  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.Conversations
  alias Ankole.Conversations.{Message, ModelPreferences}
  alias Ankole.Sessions.{Admission, Model, Run}
  alias Ankole.Signals.Signal

  setup do
    human = human_fixture().principal
    agent = agent_fixture(%{owner_principal_uid: human.uid}).principal
    Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)
    {:ok, heavy} = ModelProfiles.get_model_profile(agent.uid, "heavy")

    {:ok, _} =
      ModelProfiles.put_model_profile(
        agent.uid,
        "careful",
        Map.put(heavy, "description", "Careful analysis")
      )

    attrs = %{
      conversation_id: Ecto.UUID.generate(),
      message_id: Ecto.UUID.generate(),
      agent_uid: agent.uid,
      text: "Initial work"
    }

    {:ok, detail} =
      Conversations.create(Ankole.PrincipalsFixtures.actor_fixture(human.uid), attrs)

    input = Repo.get_by!(Signal, message_id: attrs.message_id)
    key = %{agent_uid: agent.uid, session_id: detail.session_id}

    %{
      human: human,
      agent: agent,
      id: detail.conversation.id,
      attrs: attrs,
      input: input,
      key: key
    }
  end

  test "a preference survives reopening without changing the Agent or accepted inputs", ctx do
    {:ok, before} = ModelProfiles.get_model_profiles(ctx.agent.uid)
    assert ctx.input.data["model_profile"] == "primary"
    :ok = Conversations.Events.subscribe(ctx.id)

    assert {:ok, %{profile: "careful"}} =
             Conversations.set_model_profile(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
               ctx.id,
               "careful"
             )

    id = ctx.id
    assert_receive {:conversation_event, ^id, :status}

    assert {:ok,
            %{
              profile: "careful",
              profiles: [%{"name" => "careful", "description" => "Careful analysis"}]
            }} =
             Conversations.model_preferences(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
               ctx.id
             )

    assert ModelProfiles.get_model_profiles(ctx.agent.uid) == {:ok, before}
    assert Repo.reload!(ctx.input).data["model_profile"] == "primary"

    # A delayed response retry must retain both its first input and the later preference.
    assert {:ok, _} =
             Conversations.create(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
               ctx.attrs
             )

    assert {:ok, %{profile: "careful"}} =
             Conversations.model_preferences(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
               ctx.id
             )

    assert Repo.aggregate(Message, :count) == 1
    assert Repo.reload!(ctx.input).data["model_profile"] == "primary"
  end

  test "a different profile requires a new turn and queued messages retain their sending-time selection",
       ctx do
    {:ok, run} = Admission.admit(ctx.key, ctx.input)
    assert run.spec.model_ref["profile"] == "primary"

    {:ok, _} =
      Conversations.set_model_profile(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
        ctx.id,
        "careful"
      )

    assert {:ok, %{active_profile: "primary"}} =
             Conversations.model_preferences(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
               ctx.id
             )

    rejected_id = Ecto.UUID.generate()

    assert {:error, :requires_queue_for_profile} =
             Conversations.post(Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid), ctx.id, %{
               message_id: rejected_id,
               text: "Use the new model",
               delivery_mode: "steer"
             })

    refute Repo.get_by(Message, id: rejected_id)
    refute Repo.get_by(Signal, message_id: rejected_id)

    id = Ecto.UUID.generate()

    assert {:ok, detail} =
             Conversations.post(Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid), ctx.id, %{
               message_id: id,
               text: "Next model turn",
               delivery_mode: "queue"
             })

    queued = Repo.get_by!(Signal, message_id: id)

    assert Enum.find(detail.pending_inputs, &(&1.message_id == id)).data["model_profile"] ==
             "careful"

    {:ok, _} =
      Conversations.set_model_profile(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
        ctx.id,
        nil
      )

    assert Repo.reload!(queued).data["model_profile"] == "careful"

    assert {:error, :requires_queue_for_profile} =
             Conversations.update_queue(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
               ctx.id,
               %{
                 action: "steer",
                 message_id: id,
                 agent_uid: ctx.agent.uid,
                 expected_version:
                   Ankole.Conversations.NativeQueue.queue_version(
                     detail.conversation,
                     Enum.filter(detail.pending_inputs, &(&1.agent_uid == ctx.agent.uid)),
                     ctx.agent.uid
                   )
               }
             )

    assert Repo.reload!(queued).data["delivery_mode"] == "queue"
    assert {:ok, []} = Run.inject(run, [queued])
    assert is_nil(Repo.reload!(queued).last_attempt_at)

    assert {:ok, _} = Run.finalize(run, :silent)
    assert {:ok, next} = Admission.admit(ctx.key, queued)
    assert next.spec.model_ref["profile"] == "careful"
    assert {:ok, {:preparing, next}} = Model.prepare(next)

    assert Model.request(next)["model"] ==
             next.spec.model_ref["provider_id"] <> "/" <> next.spec.model_ref["model"]
  end

  test "the first input can choose a custom profile and its next default reply follows the Agent",
       ctx do
    attrs = %{ctx.attrs | conversation_id: Ecto.UUID.generate(), message_id: Ecto.UUID.generate()}

    {:ok, detail} =
      Conversations.create(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
        Map.put(attrs, :model_profile, "careful")
      )

    input = Repo.get_by!(Signal, message_id: attrs.message_id)
    key = %{ctx.key | session_id: detail.session_id}
    assert input.data["model_profile"] == "careful"
    {:ok, run} = Admission.admit(key, input)
    assert run.spec.model_ref["profile"] == "careful"
    {:ok, _} = Run.finalize(run, :silent)

    {:ok, _} =
      Conversations.set_model_profile(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
        detail.conversation.id,
        nil
      )

    id = Ecto.UUID.generate()

    {:ok, _} =
      Conversations.post(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
        detail.conversation.id,
        %{
          message_id: id,
          text: "Follow the default"
        }
      )

    {:ok, next} = Admission.admit(key, Repo.get_by!(Signal, message_id: id))
    assert next.spec.model_ref["profile"] == "primary"
  end

  test "unlisted profiles and unrelated Humans cannot change the preference", ctx do
    stranger = human_fixture().principal

    assert {:error, :conversation_not_found} =
             Conversations.set_model_profile(
               Ankole.PrincipalsFixtures.actor_fixture(stranger.uid),
               ctx.id,
               "careful"
             )

    for choice <- ["primary", "heavy", "coding", "unknown", 7] do
      assert {:error, :model_profile_unavailable} =
               Conversations.set_model_profile(
                 Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
                 ctx.id,
                 choice
               )
    end

    assert {:ok, %{profile: nil}} =
             Conversations.model_preferences(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
               ctx.id
             )
  end

  test "removed profiles fail explicitly without committing a new message", ctx do
    {:ok, _} =
      Conversations.set_model_profile(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
        ctx.id,
        "careful"
      )

    {:ok, _} = ModelProfiles.put_model_profile(ctx.agent.uid, "careful", nil)
    id = Ecto.UUID.generate()

    assert {:error, :model_profile_unavailable} =
             Conversations.post(Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid), ctx.id, %{
               message_id: id,
               text: "Keep my draft"
             })

    refute Repo.get_by(Message, id: id)

    assert {:ok, %{profile: "careful", profiles: []}} =
             Conversations.model_preferences(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
               ctx.id
             )

    assert {:ok, %{profile: nil}} =
             Conversations.set_model_profile(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
               ctx.id,
               nil
             )
  end

  test "the final injection fence rejects a different captured profile even if mode is changed directly",
       ctx do
    {:ok, run} = Admission.admit(ctx.key, ctx.input)

    {:ok, _} =
      Conversations.set_model_profile(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
        ctx.id,
        "careful"
      )

    id = Ecto.UUID.generate()

    {:ok, _} =
      Conversations.post(Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid), ctx.id, %{
        message_id: id,
        text: "Separate model",
        delivery_mode: "queue"
      })

    queued = Repo.get_by!(Signal, message_id: id)

    {:ok, queued} =
      Repo.transact(fn _ ->
        Ankole.Ash.update(queued, :revise_input, %{
          data: Map.put(queued.data, "delivery_mode", "steer")
        })
      end)

    assert ModelPreferences.compatible?(queued, "primary") == false
    assert {:ok, []} = Run.inject(run, [queued])
    assert is_nil(Repo.reload!(queued).last_attempt_at)
  end

  test "an automatic Main wake freezes the Chat preference on admission", ctx do
    {:ok, run} = Admission.admit(ctx.key, ctx.input)
    {:ok, _} = Run.finalize(run, :silent)

    {:ok, _} =
      Conversations.set_model_profile(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
        ctx.id,
        "careful"
      )

    {:ok, wake} =
      Repo.transact(fn ->
        Ankole.Signals.accept_in_tx(%{
          producer: :kernel,
          source: "model-preference-test",
          id: Ecto.UUID.generate(),
          type: "background_agent_job.completed",
          sender: ctx.human.uid,
          target: %{agent_uid: ctx.agent.uid, conversation_id: ctx.id},
          data: %{"job_id" => 1001}
        })
      end)

    assert is_nil(wake.data["model_profile"])
    assert {:ok, next} = Admission.admit(ctx.key, wake)
    assert next.spec.model_ref["profile"] == "careful"
    assert Repo.reload!(wake).data["model_profile"] == "careful"

    {:ok, _} =
      Conversations.set_model_profile(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
        ctx.id,
        nil
      )

    assert {:ok, %{profile: nil, active_profile: "careful"}} =
             Conversations.model_preferences(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
               ctx.id
             )
  end

  test "revoking a shared anchor prevents reading or changing its Chat model preference", ctx do
    owner = human_fixture().principal

    {:ok, page} =
      Ankole.Pod.Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
        private_owner_uid: owner.uid
      })

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
        grants: [%{principal_uid: ctx.human.uid, role: "edit"}]
      })

    id = Ecto.UUID.generate()

    {:ok, _} =
      Conversations.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid), %{
        conversation_id: id,
        message_id: Ecto.UUID.generate(),
        agent_uid: ctx.agent.uid,
        page_id: page.id,
        access_scope: :anchor_page,
        text: "Work on this Page"
      })

    assert {:ok, _} =
             Conversations.set_model_profile(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
               id,
               "careful"
             )

    {:ok, _} = Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{grants: []})

    assert {:error, :conversation_not_found} =
             Conversations.model_preferences(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
               id
             )

    assert {:error, :conversation_not_found} =
             Conversations.set_model_profile(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
               id,
               nil
             )
  end

  test "a provider-capacity deferred wake retains the profile selected at its first admission",
       ctx do
    {:ok, run} = Admission.admit(ctx.key, ctx.input)
    {:ok, _} = Run.finalize(run, :silent)

    {:ok, _} =
      Conversations.set_model_profile(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
        ctx.id,
        "careful"
      )

    {:ok, wake} =
      Repo.transact(fn ->
        Ankole.Signals.accept_in_tx(%{
          producer: :kernel,
          source: "deferred-model-test",
          id: Ecto.UUID.generate(),
          type: "background_agent_job.completed",
          sender: ctx.human.uid,
          target: %{agent_uid: ctx.agent.uid, conversation_id: ctx.id},
          data: %{"job_id" => 1001}
        })
      end)

    capacity =
      {:error,
       {:model_profile_unavailable, "careful",
        %{"error_code" => "credential_pool_exhausted", "retryable" => true}}}

    assert {:ok, %{status: :deferred}} =
             Admission.admit(ctx.key, wake, turn_start_overrides: capacity)

    deferred = Repo.reload!(wake)
    assert deferred.data["model_profile"] == "careful"

    {:ok, _} =
      Conversations.set_model_profile(
        Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
        ctx.id,
        nil
      )

    assert {:ok, %{active_profile: "careful"}} =
             Conversations.model_preferences(
               Ankole.PrincipalsFixtures.actor_fixture(ctx.human.uid),
               ctx.id
             )

    assert {:ok, resumed} = Admission.admit(ctx.key, deferred, now: deferred.available_at)
    assert resumed.spec.model_ref["profile"] == "careful"
  end
end
