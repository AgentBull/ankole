defmodule Ankole.Sessions.AgentTokenQuotaTest do
  use Ankole.SessionsCase

  alias Ankole.AIAgent.TokenQuota
  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.BackgroundAgentJobs
  alias Ankole.Sessions.Admission
  alias Ankole.Sessions.AmbientJudgment
  alias Ankole.Sessions.AmbientTriage
  alias Ankole.Sessions.CodexJob
  alias Ankole.Sessions.Run

  describe "a turn that cannot start" do
    test "an addressed message is completed with a durable quota notice" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      exhaust_quota!(agent.uid, 1_000, 1_500)

      assert {:ok, %{signal: input}} =
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
                posted: %{intents: [%Intent{} = notice]},
                notice_error: nil
              }} =
               Admission.admit(%{agent_uid: agent.uid, session_id: input.session_id}, input,
                 now: DateTime.add(@base_time, 20, :second)
               )

      assert window.used_tokens == 1_500
      assert window.limit_tokens == 1_000
      assert window.exceeded

      assert notice.outbound_key == "ai-token-quota-exceeded:#{input.id}"
      assert notice.operation == :reply
      assert notice.reply_to_provider_message_id == input.provider_message_id
      assert notice.payload["text"] == expected_notice_text(agent.uid, input.id)

      assert notice.payload["metadata"] == %{
               "signal_id" => input.id,
               "source" => "session_token_quota_exceeded_notice"
             }

      assert %Signal{producer: :kernel, completed_at: %DateTime{}} = Repo.get!(Signal, input.id)
      assert Repo.get!(AgentWorker, agent.uid).state == :absent
    end

    test "an ambient message is completed without a notice" do
      now = DateTime.utc_now(:microsecond)
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :may_intervene)
      exhaust_quota!(agent.uid, 1_000, 1_500)

      assert {:ok, %{signal: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "ambient message", provider_time: now}),
                 now: now
               )

      assert input.type == "im.message.may_intervene"

      assert {:ok,
              %{
                status: :agent_token_quota_exceeded,
                token_quota: window,
                posted: %{intents: []},
                notice_error: nil
              }} =
               AmbientTriage.run(%{agent_uid: agent.uid, session_id: input.session_id}, input)

      assert window.used_tokens == 1_500
      assert window.limit_tokens == 1_000
      assert window.exceeded

      assert %Signal{
               producer: :kernel,
               completed_at: %DateTime{},
               turn_outcome: "silent",
               attempt_count: 0,
               last_attempt_at: nil
             } = Repo.get!(Signal, input.id)

      assert %AmbientJudgment{action: "NOOP", authority: "NONE"} =
               Repo.get!(AmbientJudgment, input.id)

      refute Repo.get_by(Intent, source_signal_id: input.id)
      refute Repo.exists?(Ankole.Sessions.SessionWorkspace)
      refute Repo.exists?(Ankole.AIGateway.Schemas.Conversation)
      assert Repo.get!(AgentWorker, agent.uid).state == :absent
    end
  end

  describe "a turn that crosses the quota while it runs" do
    test "the dead-letter notice states the quota instead of the retry text" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore)
      put_quota!(agent.uid, 1_000)

      assert {:ok, %{signal: input}} =
               emit_entry(
                 agent.uid,
                 "bot",
                 group_entry(%{text: "long task", explicit: true}),
                 now: @base_time
               )

      started_at = DateTime.add(@base_time, 20, :second)

      assert {:ok, run} =
               Admission.admit(%{agent_uid: agent.uid, session_id: input.session_id}, input,
                 now: started_at
               )

      record_usage!(agent.uid, 900, 600)

      assert {:ok, %{status: :completed}} =
               Run.finalize(run, :dead_letter, %{
                 "code" => "agent_token_quota_exceeded",
                 "message" => "The Agent has used its token quota for the current period.",
                 "retryable" => false
               })

      dead_lettered = Repo.get!(Signal, input.id)
      assert dead_lettered.id == input.id
      assert Repo.get!(Signal, input.id).status == :dead_letter

      notice = Repo.get_by!(Intent, outbound_key: "ai-dead-letter:#{input.id}")

      assert String.starts_with?(
               notice.fallback_visible_text,
               expected_notice_text(agent.uid, input.id)
             )

      refute notice.fallback_visible_text =~
               Ankole.I18n.t("conversations.delivery.reply.dead_letter", %{"ref" => input.id})
    end
  end

  describe "background agent jobs" do
    test "a quota rejection fails the Job without a requeue" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
      route = unique_route()
      :ok = WorkerRoute.register_local_worker(route, self())
      on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      job = create_job!(agent.uid, "token-quota")

      session_key = %{
        agent_uid: agent.uid,
        session_id: BackgroundAgentJobs.job_session_id(job.id)
      }

      ready_at = DateTime.add(job.queued_at, 1, :second)

      # Job turns pass `conversation: :none`, so an exhausted quota does not stop
      # the dispatch: the first Codex request is what AIGateway rejects.
      exhaust_quota!(agent.uid, 1_000, 1_500)

      event = Queue.next_ready_event(agent.uid, session_key.session_id, ready_at)
      assert {:ok, run} = Admission.admit(session_key, event, now: ready_at)
      assert {:ok, _sent} = CodexJob.start(run)
      assert_receive {:actor_lane, envelope}, 2_000
      assert turn_start_payload!(envelope).turn.job_id == job.id

      assert {:ok, dead_lettered} =
               CodexJob.abort(run.job_ref, agent.uid, %{
                 "code" => "worker_turn_failed",
                 "message" => "The Agent has used its token quota for the current period.",
                 "details_json" => %{
                   "error_code" => "agent_token_quota_exceeded",
                   "retryable" => false
                 }
               })

      assert dead_lettered.status == :dead_letter

      failed = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)
      assert failed.status == :failed
      assert failed.error["code"] == "agent_token_quota_exceeded"
      assert failed.error["details"]["error_code"] == "agent_token_quota_exceeded"
      assert failed.attempts == 1

      assert Repo.get_by!(Signal,
               agent_uid: agent.uid,
               session_id: job.owner_session_id,
               type: "background_agent_job.failed"
             )
    end
  end

  for exhausted? <- [true, false] do
    @exhausted? exhausted?
    test "a pooled Codex error checks the quota before settlement: exhausted=#{exhausted?}" do
      %{principal: agent} = agent_fixture()
      binding_fixture(agent.uid, "bot", :ignore, adapter: "mock-provider")
      route = unique_route()
      :ok = WorkerRoute.register_local_worker(route, self())
      on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
      assert {:ok, _worker} = admit_worker(route)

      job = create_job!(agent.uid, "pooled-quota")
      key = %{agent_uid: agent.uid, session_id: BackgroundAgentJobs.job_session_id(job.id)}
      ready_at = DateTime.add(job.queued_at, 1, :second)
      put_quota!(agent.uid, 1_000)
      if @exhausted?, do: record_usage!(agent.uid, 1_500, 0)

      event = Queue.next_ready_event(agent.uid, key.session_id, ready_at)
      assert {:ok, run} = Admission.admit(key, event, now: ready_at)
      assert {:ok, _sent} = CodexJob.start(run)
      assert_receive {:actor_lane, _envelope}, 2_000
      retry_at = DateTime.add(DateTime.utc_now(:microsecond), 300, :second)

      assert {:ok, event} =
               CodexJob.abort(run.job_ref, agent.uid, %{
                 "code" => "worker_turn_failed",
                 "message" => "You've hit your usage limit.",
                 "details_json" => %{
                   "runtime" => "bun",
                   "error_code" => "credential_pool_exhausted",
                   "retryable" => true,
                   "retry_at" => DateTime.to_iso8601(retry_at)
                 }
               })

      settled = BackgroundAgentJobs.get_job_for_agent(job.id, agent.uid)

      if @exhausted? do
        assert event.status == :dead_letter
        assert settled.status == :failed
        assert settled.error["code"] == "agent_token_quota_exceeded"

        assert settled.error["summary"] ==
                 "The Agent has used its token quota for the current period."

        assert settled.error["details"]["error_code"] == "agent_token_quota_exceeded"

        assert Repo.get_by!(Signal,
                 agent_uid: agent.uid,
                 session_id: job.owner_session_id,
                 type: "background_agent_job.failed"
               )
      else
        assert event.status == :queued
        assert event.available_at == retry_at
        assert settled.status == :queued
        assert settled.execution_failures == 0

        refute Repo.get_by(Signal,
                 agent_uid: agent.uid,
                 session_id: job.owner_session_id,
                 type: "background_agent_job.failed"
               )
      end
    end
  end

  defp expected_notice_text(agent_uid, signal_id) do
    assert {:ok, %{usage: %{} = window}} = TokenQuota.status(agent_uid)

    Ankole.Sessions.Notices.token_quota_notice_text(
      window,
      signal_id
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
    assert {:ok, _record} =
             Ankole.Ash.create(UsageRecord, :record_round, %{
               subject_uid: agent_uid,
               origin: :agent,
               model: "test-provider/test-model",
               input_tokens: input_tokens,
               output_tokens: output_tokens
             })
  end

  defp create_job!(agent_uid, suffix) do
    assert {:ok, %{job: job}} =
             Repo.transact(fn _repo ->
               BackgroundAgentJobs.create_with_dispatch(%{
                 "source_signal_id" => Ankole.WorkFixtures.service_source(agent_uid).id,
                 "agent_uid" => agent_uid,
                 "owner_session_id" => "owner-session-#{suffix}",
                 "source_tool_call_id" => "tool-background-agent-job-#{suffix}",
                 "title" => "Job #{suffix}",
                 "task" => "Complete job #{suffix}.",
                 "reply_route" => %{
                   "binding_name" => "bot",
                   "conversation_id" =>
                     Ankole.ExternalConversationsFixtures.external_conversation_id(
                       "chat-#{suffix}"
                     )
                 }
               })
             end)

    job
  end
end
