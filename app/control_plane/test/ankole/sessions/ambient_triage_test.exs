defmodule Ankole.Sessions.AmbientTriageTest do
  use Ankole.SessionsCase

  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIAgent.TokenQuota
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.Schemas.Conversation, as: ModelConversation
  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.BackgroundAgentJobs
  alias Ankole.Sessions.{Admission, AmbientJudgment, AmbientTriage, SessionWorkspace}

  setup do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "bot", :may_intervene)
    %{agent: agent}
  end

  test "NOOP from the real provider protocol settles input without a model conversation or epoch",
       %{agent: agent} do
    owner = self()

    configure_model(agent.uid, fn request ->
      send(owner, {:ambient_request, request.body})
      {:json, 200, response("NOOP")}
    end)

    event = ambient_event(agent, "ordinary room chatter")
    key = %{agent_uid: agent.uid, session_id: event.session_id}

    assert {:error, :ambient_turn_not_authorized} = Admission.admit(key, event)
    refute Repo.exists?(SessionWorkspace)
    refute Repo.exists?(ModelConversation)

    assert {:ok, :settled} = AmbientTriage.run(key, event)
    assert_receive {:ambient_request, request}
    refute Map.has_key?(request, "temperature")

    assert %Signal{completed_at: %DateTime{}, turn_outcome: "silent", last_attempt_at: nil} =
             Repo.reload!(event)

    assert %AmbientJudgment{action: "NOOP"} = Repo.get!(AmbientJudgment, event.id)
    refute Repo.exists?(SessionWorkspace)
    refute Repo.exists?(ModelConversation)
  end

  test "a foreground judgment precedes the only epoch increment", %{agent: agent} do
    configure_model(agent.uid, fn _ -> {:json, 200, response("FOREGROUND_REPLY")} end)
    event = ambient_event(agent, "What is the benchmark?")
    key = %{agent_uid: agent.uid, session_id: event.session_id}

    assert {:ok, :intervene, event} = AmbientTriage.run(key, event)

    refute Repo.exists?(SessionWorkspace)
    refute Repo.exists?(ModelConversation)
    assert {:ok, run} = Admission.admit(key, event)
    assert run.epoch == 1
    assert Repo.get!(SessionWorkspace, run.workspace_id).epoch == 1
    assert Repo.aggregate(ModelConversation, :count) == 1
  end

  for restriction <- [:tenant, :agent] do
    @restriction restriction

    test "#{restriction} admission rejects queued ambient input before model I/O", %{
      agent: agent,
      tenant: tenant
    } do
      owner = self()

      configure_model(agent.uid, fn _request ->
        send(owner, :ambient_provider_called)
        {:json, 200, response("NOOP")}
      end)

      event = ambient_event(agent, "ordinary room chatter")
      key = %{agent_uid: agent.uid, session_id: event.session_id}
      reason = restrict_work!(@restriction, tenant, agent)

      assert {:error, ^reason} = AmbientTriage.run(key, event)
      refute_receive :ambient_provider_called, 20
      assert_unclassified(event, 0)
    end

    test "#{restriction} admission is checked again after the model response", %{
      agent: agent,
      tenant: tenant
    } do
      event = ambient_event(agent, "The failed pod reports a database timeout.")
      key = %{agent_uid: agent.uid, session_id: event.session_id}
      job = create_job!(agent, event)
      conversations = Repo.aggregate(ModelConversation, :count)
      owner = self()

      configure_model(agent.uid, fn _request ->
        send(owner, {:classifying, self()})

        receive do
          :finish_classification ->
            {:json, 200, response("HANDOFF", %{"handoff_job_id" => Integer.to_string(job.id)})}
        after
          5_000 -> raise "ambient admission race did not release the provider response"
        end
      end)

      classification =
        Task.async(fn ->
          Repo.with_tenant(tenant.id, fn -> AmbientTriage.run(key, event) end)
        end)

      assert_receive {:classifying, provider}, 10_000
      reason = restrict_work!(@restriction, tenant, agent)
      send(provider, :finish_classification)

      assert {:error, ^reason} = Task.await(classification)
      assert_unclassified(event, conversations)
    end
  end

  for action <- ["HANDOFF", "FOREGROUND_REPLY"] do
    @action action

    test "a batch that expires during model I/O cannot commit #{@action}", %{agent: agent} do
      event = ambient_event(agent, "The failed pod reports a database timeout.")
      key = %{agent_uid: agent.uid, session_id: event.session_id}
      job = create_job!(agent, event)
      conversations = Repo.aggregate(ModelConversation, :count)
      owner = self()

      configure_model(agent.uid, fn _request ->
        send(owner, :ambient_expiring_provider_called)
        Process.sleep(1_500)
        handoff_id = if @action == "HANDOFF", do: Integer.to_string(job.id)
        {:json, 200, response(@action, %{"handoff_job_id" => handoff_id})}
      end)

      expires = DateTime.add(DateTime.utc_now(:microsecond), 1, :second)
      data = put_in(event.data, ["ambient_batch", "expires_at"], DateTime.to_iso8601(expires))
      event = Repo.update!(Ecto.Changeset.change(event, data: data))

      assert {:ok, :settled} = AmbientTriage.run(key, event)

      assert_receive :ambient_expiring_provider_called
      assert DateTime.compare(DateTime.utc_now(:microsecond), expires) == :gt
      assert %Signal{completed_at: %DateTime{}, last_attempt_at: nil} = Repo.reload!(event)
      refute Repo.exists?(AmbientJudgment)
      refute Repo.exists?(from(s in Signal, where: s.type == "command.steer"))
      refute Repo.exists?(SessionWorkspace)
      assert Repo.aggregate(ModelConversation, :count) == conversations
    end
  end

  test "model failures retain batching eligibility and the third failure settles silently", %{
    agent: agent
  } do
    configure_model(agent.uid, fn _ ->
      {:json, 400,
       %{"error" => %{"type" => "invalid_request_error", "message" => "Rejected classification"}}}
    end)

    event = ambient_event(agent, "room chatter")
    key = %{agent_uid: agent.uid, session_id: event.session_id}

    for attempt <- 1..2 do
      assert {:ok, :deferred, current} = AmbientTriage.run(key, event)

      assert current.attempt_count == attempt
      assert current.last_attempt_at == nil
      assert current.completed_at == nil
    end

    assert {:ok, :settled} = AmbientTriage.run(key, event)

    assert %Signal{
             attempt_count: 3,
             last_attempt_at: nil,
             turn_outcome: "silent",
             completed_at: %DateTime{}
           } = Repo.reload!(event)

    refute Repo.exists?(SessionWorkspace)
    refute Repo.exists?(ModelConversation)
  end

  test "quota exhausted after preflight settles at the gateway without a model retry", %{
    agent: agent
  } do
    owner = self()

    configure_model(agent.uid, fn _request ->
      send(owner, :ambient_provider_called)
      {:json, 200, response("FOREGROUND_REPLY")}
    end)

    assert {:ok, _} =
             TokenQuota.put(agent.uid, %{
               "period_days" => 7,
               "period_start_at" => DateTime.to_iso8601(DateTime.utc_now()),
               "limit_tokens" => 1_000
             })

    event = ambient_event(agent, "What is the benchmark?")
    key = %{agent_uid: agent.uid, session_id: event.session_id}
    handler = {__MODULE__, :quota_consumed, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:ankole, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == owner and
               String.starts_with?(metadata.query, "SELECT") and
               String.contains?(metadata.query, "sum(") and
               String.contains?(metadata.query, ~s(FROM "ai_gateway_usage_records")) and
               agent.uid in metadata.params do
            :ok = :telemetry.detach(handler)

            assert {:ok, _record} =
                     Ankole.Ash.create(UsageRecord, :record_round, %{
                       subject_uid: agent.uid,
                       origin: :agent,
                       model: "ambient-triage/gpt-5.5",
                       input_tokens: 1_500,
                       output_tokens: 0
                     })

            send(owner, :ambient_quota_consumed)
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, :settled} = AmbientTriage.run(key, event)

    assert_receive :ambient_quota_consumed
    refute_receive :ambient_provider_called, 20

    assert %Signal{
             completed_at: %DateTime{},
             turn_outcome: "silent",
             attempt_count: 0,
             last_attempt_at: nil
           } = Repo.reload!(event)

    assert %AmbientJudgment{action: "NOOP", authority: "NONE"} =
             Repo.get!(AmbientJudgment, event.id)

    refute Repo.exists?(Intent)
    refute Repo.exists?(SessionWorkspace)
    refute Repo.exists?(ModelConversation)
  end

  test "HANDOFF commits exactly one steer without a foreground epoch or new model history", %{
    agent: agent
  } do
    event = ambient_event(agent, "The failed pod reports a database timeout.")
    key = %{agent_uid: agent.uid, session_id: event.session_id}
    job = create_job!(agent, event)
    conversations = Repo.aggregate(ModelConversation, :count)
    owner = self()

    configure_model(agent.uid, fn request ->
      send(owner, {:triage_request, request})
      {:json, 200, response("HANDOFF", %{"handoff_job_id" => Integer.to_string(job.id)})}
    end)

    assert {:ok, :settled} = AmbientTriage.run(key, event)
    assert_receive {:triage_request, request}
    refute Map.has_key?(request.body, "conversation")
    refute Map.has_key?(request.body, "previous_response_id")
    assert request.body["model"] == "gpt-5.5"

    assert %AmbientJudgment{action: "HANDOFF", handoff_job_id: id} =
             Repo.get!(AmbientJudgment, event.id)

    assert id == job.id

    assert %Signal{completed_at: %DateTime{}, turn_outcome: "silent", last_attempt_at: nil} =
             Repo.reload!(event)

    assert {:ok, :settled} = AmbientTriage.run(key, event)
    refute_receive {:triage_request, _}, 20
    assert Repo.aggregate(from(s in Signal, where: s.type == "command.steer"), :count) == 1
    refute Repo.exists?(SessionWorkspace)
    assert Repo.aggregate(ModelConversation, :count) == conversations
  end

  test "a scene change during the model request rejects its HANDOFF and settles the old batch", %{
    agent: agent
  } do
    event = ambient_event(agent, "The failed pod reports a database timeout.")
    key = %{agent_uid: agent.uid, session_id: event.session_id}
    job = create_job!(agent, event)
    conversations = Repo.aggregate(ModelConversation, :count)
    owner = self()

    configure_model(agent.uid, fn _request ->
      send(owner, {:classifying, self()})

      receive do
        :finish_classification ->
          {:json, 200, response("HANDOFF", %{"handoff_job_id" => Integer.to_string(job.id)})}
      after
        5_000 -> raise "ambient scene race did not release the provider response"
      end
    end)

    tenant_id = Repo.tenant_id!()

    classification =
      Task.async(fn ->
        Repo.with_tenant(tenant_id, fn -> AmbientTriage.run(key, event) end)
      end)

    assert_receive {:classifying, provider}, 10_000
    later = DateTime.add(event.occurred_at, 20, :second)

    assert {:ok, %{signal: newest}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{
                 source_event_id: "ambient-new-scene",
                 provider_message_id: "ambient-new-message",
                 provider_time: later,
                 text: "The database has recovered; stop investigating."
               }),
               now: later
             )

    send(provider, :finish_classification)

    assert {:ok, :settled} = Task.await(classification)

    assert %Signal{completed_at: %DateTime{}} = Repo.reload!(event)
    assert Repo.reload!(newest).completed_at == nil
    refute Repo.exists?(AmbientJudgment)
    refute Repo.exists?(from(s in Signal, where: s.type == "command.steer"))
    refute Repo.exists?(SessionWorkspace)
    assert Repo.aggregate(ModelConversation, :count) == conversations
  end

  test "a failed model request remains eligible for a newer room batch", %{agent: agent} do
    configure_model(agent.uid, fn _ ->
      {:json, 400,
       %{"error" => %{"type" => "invalid_request_error", "message" => "Rejected classification"}}}
    end)

    event = ambient_event(agent, "The pod failed.")
    key = %{agent_uid: agent.uid, session_id: event.session_id}

    assert {:ok, :deferred, failed} = AmbientTriage.run(key, event)

    assert failed.last_attempt_at == nil
    later = DateTime.add(event.occurred_at, 20, :second)

    assert {:ok, %{signal: newest}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{
                 source_event_id: "ambient-retry-new-scene",
                 provider_message_id: "ambient-retry-new-message",
                 provider_time: later,
                 text: "The pod recovered."
               }),
               now: later
             )

    assert {:ok, :settled} = AmbientTriage.run(key, failed)
    assert %Signal{last_attempt_at: nil, completed_at: %DateTime{}} = Repo.reload!(event)

    assert %Signal{attempt_count: 0, last_attempt_at: nil, completed_at: nil} =
             Repo.reload!(newest)

    refute Repo.exists?(AmbientJudgment)
    refute Repo.exists?(SessionWorkspace)
    refute Repo.exists?(ModelConversation)
  end

  defp create_job!(agent, event) do
    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "source_signal_id" => Ankole.WorkFixtures.service_source(agent.uid).id,
               "agent_uid" => agent.uid,
               "owner_session_id" => event.session_id,
               "source_tool_call_id" => "triage-existing-job",
               "title" => "Investigate the pod",
               "task" => "Find the cause of the pod failure.",
               "reply_route" => %{
                 "binding_name" => event.reply_binding_name,
                 "conversation_id" => event.conversation_id,
                 "provider_thread_id" => event.provider_thread_id,
                 "provider_message_id" => event.provider_message_id
               }
             })

    job
  end

  defp restrict_work!(:tenant, tenant, _agent) do
    set_privileged_tenant(create_tenant())
    assert {:ok, _} = Ankole.Tenants.suspend(tenant)
    assert {:error, :tenant_suspended} = Ankole.Tenants.check_work_admission(tenant.id)
    :tenant_suspended
  end

  defp restrict_work!(:agent, _tenant, agent) do
    assert {:ok, %{status: :disabled}} = Ankole.Principals.delete_agent(agent.uid)
    :agent_not_active
  end

  defp assert_unclassified(event, conversations) do
    assert %Signal{
             status: :queued,
             completed_at: nil,
             attempt_count: 0,
             last_attempt_at: nil
           } = Repo.reload!(event)

    refute Repo.exists?(AmbientJudgment)
    refute Repo.exists?(from(s in Signal, where: s.type == "command.steer"))
    refute Repo.exists?(SessionWorkspace)
    assert Repo.aggregate(ModelConversation, :count) == conversations
  end

  defp ambient_event(agent, text) do
    now = DateTime.utc_now(:microsecond)

    assert {:ok, %{signal: event}} =
             emit_entry(
               agent.uid,
               "bot",
               group_entry(%{text: text, provider_time: now}),
               now: now
             )

    event
  end

  defp configure_model(agent_uid, handler) do
    base_url = Ankole.AIGatewayCase.start_upstream_server(handler)

    assert {:ok, _} =
             ProviderConfigs.create_provider(%{
               provider_id: "ambient-triage",
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               credential_pool: %{"entries" => [%{"label" => "Test", "api_key" => "sk-test"}]}
             })

    assert {:ok, _} =
             ModelProfiles.put_model_profile(agent_uid, "light", %{
               provider_id: "ambient-triage",
               model: "gpt-5.5"
             })
  end

  defp response(action, attrs \\ %{}) do
    value =
      Ankole.JSON.encode!(
        Map.merge(
          %{
            "action" => action,
            "authority" => "NONE",
            "handoff_job_id" => nil,
            "asked_by" => nil,
            "reason" => "Chosen ambient route."
          },
          attrs
        )
      )

    %{
      "id" => "resp_triage",
      "object" => "response",
      "status" => "completed",
      "output" => [
        %{
          "type" => "message",
          "role" => "assistant",
          "content" => [%{"type" => "output_text", "text" => value}]
        }
      ],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 10}
    }
  end
end
