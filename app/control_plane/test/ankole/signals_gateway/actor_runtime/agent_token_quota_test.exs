defmodule Ankole.SignalsGateway.ActorRuntime.AgentTokenQuotaTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.AIAgent.TokenQuota
  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.BackgroundAgentJobs
  alias Ankole.SignalsGateway.ActorRuntime.ReadyEventProcessor

  describe "a turn that cannot start" do
    test "an addressed message is completed with a durable quota notice" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      assert {:ok, _worker} = admit_worker(unique_route())
      exhaust_quota!(agent.uid, 1_000, 1_500)

      assert {:ok, %{actor_event: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "hello", explicit: true}),
                 now: @base_time
               )

      assert {:ok,
              %{
                status: :agent_token_quota_exceeded,
                token_quota: window,
                notice_outbox: %OutboxEntry{} = notice,
                notice_error: nil
              }} =
               process_ready_events_once(now: DateTime.add(@base_time, 20, :second))

      assert window.used_tokens == 1_500
      assert window.limit_tokens == 1_000
      assert window.exceeded

      assert notice.outbound_key == "ai-token-quota-exceeded:#{input.id}"
      assert notice.operation == :reply
      assert notice.reply_to_source_entry_id == input.source_entry_id
      assert notice.payload["text"] == expected_notice_text(agent.uid, input.id)

      assert notice.payload["metadata"] == %{
               "actor_event_id" => input.id,
               "source" => "actor_token_quota_exceeded_notice"
             }

      assert %ActorEvent{completed_at: %DateTime{}} = Repo.get!(ActorEvent, input.id)
      refute Repo.get_by(ActorEventDelivery, actor_event_id: input.id)
    end

    test "an ambient message is completed without a notice" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :may_intervene)
      assert {:ok, _worker} = admit_worker(unique_route())
      exhaust_quota!(agent.uid, 1_000, 1_500)

      assert {:ok, %{actor_event: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "ambient message"}),
                 now: @base_time
               )

      assert input.type == "im.message.may_intervene"

      assert {:ok, %{status: :agent_token_quota_exceeded, notice_outbox: nil, notice_error: nil}} =
               process_ready_events_once(now: DateTime.add(@base_time, 20, :second))

      assert %ActorEvent{completed_at: %DateTime{}} = Repo.get!(ActorEvent, input.id)
      refute Repo.get_by(OutboxEntry, source_actor_event_id: input.id)
      refute Repo.get_by(ActorEventDelivery, actor_event_id: input.id)
    end
  end

  describe "a turn that crosses the quota while it runs" do
    test "the dead-letter notice states the quota instead of the retry text" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      route = unique_route()
      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      put_quota!(agent.uid, 1_000)

      assert {:ok, %{actor_event: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "long task", explicit: true}),
                 now: @base_time
               )

      started_at = DateTime.add(@base_time, 20, :second)
      assert {:ok, %{turn_ref: _turn_ref}} = process_ready_events_once(now: started_at)
      assert_receive {:actor_lane, envelope}, 2_000
      turn_ref = turn_start_payload!(envelope).turn

      # The turn started under the limit and its own rounds crossed it.
      record_usage!(agent.uid, 900, 600)

      assert {:ok, %{status: :turn_dead_lettered, actor_event: dead_lettered}} =
               fail_turn(
                 turn_ref,
                 "worker_turn_failed",
                 "The Agent has used its token quota for the current period.",
                 %{"error_code" => "agent_token_quota_exceeded", "retryable" => false},
                 now: DateTime.add(started_at, 1, :second)
               )

      assert dead_lettered.id == input.id
      assert Repo.get!(ActorEvent, input.id).input_state == "dead_letter"

      notice = Repo.get_by!(OutboxEntry, outbound_key: "ai-dead-letter:#{input.id}")

      assert String.starts_with?(
               notice.fallback_visible_text,
               expected_notice_text(agent.uid, input.id)
             )

      refute notice.fallback_visible_text =~
               Ankole.I18n.t("signals_gateway.reply.dead_letter", %{"ref" => input.id})
    end
  end

  describe "background agent jobs" do
    test "a quota rejection fails the Job without a requeue" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
      route = unique_route()
      :ok = Broker.register_local_worker(route, self())
      on_exit(fn -> Broker.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      job = create_job!(agent.uid, "token-quota")
      actor_key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
      ready_at = DateTime.add(job.queued_at, 1, :second)

      # Job turns pass `conversation: :none`, so an exhausted quota does not stop
      # the dispatch: the first Codex request is what AIGateway rejects.
      exhaust_quota!(agent.uid, 1_000, 1_500)

      assert {:ok, %{send_outcome: "sent_or_queued"}} =
               ReadyEventProcessor.process_ready_event_for_actor(actor_key,
                 now: ready_at,
                 lease_seconds: @long_lease_seconds
               )

      assert_receive {:actor_lane, envelope}, 2_000
      turn_ref = turn_start_payload!(envelope).turn
      failure_time = DateTime.add(ready_at, 1, :second)

      assert {:ok, %{status: :background_agent_job_failed, actor_event: dead_lettered}} =
               fail_turn(
                 turn_ref,
                 "worker_turn_failed",
                 "The Agent has used its token quota for the current period.",
                 %{"error_code" => "agent_token_quota_exceeded", "retryable" => false},
                 now: failure_time
               )

      assert dead_lettered.input_state == "dead_letter"

      failed = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
      assert failed.status == "failed"
      assert failed.error["code"] == "agent_token_quota_exceeded"
      assert failed.error["details"]["error_code"] == "agent_token_quota_exceeded"
      assert failed.attempts == 1

      assert Repo.get_by!(ActorEvent,
               agent_uid: agent.uid,
               session_id: job.owner_session_id,
               type: "background_agent_job.failed"
             )
    end
  end

  defp expected_notice_text(agent_uid, actor_event_id) do
    assert {:ok, %{usage: %{} = window}} = TokenQuota.status(agent_uid)

    Ankole.SignalsGateway.ActorRuntime.TurnStartFailure.token_quota_notice_text(
      window,
      actor_event_id
    )
  end

  defp put_quota!(agent_uid, limit_tokens) do
    assert {:ok, _quota} =
             TokenQuota.put(agent_uid, %{
               "period_days" => 7,
               "period_start_at" =>
                 @base_time |> DateTime.add(-3_600, :second) |> DateTime.to_iso8601(),
               "limit_tokens" => limit_tokens
             })
  end

  defp exhaust_quota!(agent_uid, limit_tokens, used_tokens) do
    put_quota!(agent_uid, limit_tokens)
    record_usage!(agent_uid, used_tokens, 0)
  end

  defp record_usage!(agent_uid, input_tokens, output_tokens) do
    Repo.insert!(%UsageRecord{
      subject_uid: agent_uid,
      origin: "agent",
      model: "test-provider/test-model",
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      inserted_at: DateTime.utc_now(:microsecond)
    })
  end

  defp create_job!(agent_uid, suffix) do
    assert {:ok, %{job: job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "agent_uid" => agent_uid,
               "owner_session_id" => "owner-session-#{suffix}",
               "source_tool_call_id" => "tool-background-agent-job-#{suffix}",
               "title" => "Job #{suffix}",
               "task" => "Complete job #{suffix}.",
               "reply_route" => %{
                 "binding_name" => "bot",
                 "signal_channel_id" => "chat-#{suffix}"
               }
             })

    job
  end
end
