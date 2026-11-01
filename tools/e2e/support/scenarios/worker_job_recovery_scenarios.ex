defmodule Ankole.E2E.Scenarios.WorkerJobRecovery do
  @moduledoc "Codex Jobs keep their thread and files through disconnection and Worker replacement."

  import Ecto.Query
  import ExUnit.Assertions
  import Ankole.E2E.Harness
  import Ankole.E2E.WaitHelpers

  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.E2E.DockerWorker
  alias Ankole.E2E.FakeOpenAIState
  alias Ankole.Repo
  alias Ankole.Signals.Signal
  alias Ankole.AgentWorkers.Providers
  alias Ankole.AgentWorkers.AgentWorker

  def reconnect(max_slots) do
    ctx = start_worker_e2e_stack!(worker: false)
    provider_id = DockerWorker.provider_id!()
    {:ok, provider} = Providers.load(provider_id)

    config =
      put_in(provider.settings, ["env", "ANKOLE_MAX_CONCURRENT_SLOTS"], to_string(max_slots))

    assert {:ok, _} = Providers.update(provider_id, %{config: Ankole.JSON.encode!(config)})
    ctx = Map.merge(ctx, start_worker!([ctx.agent.uid], server_port: ctx.server_port))
    uid = ctx.agent.uid
    {:ok, profile} = ModelProfiles.get_model_profile(uid, "primary")
    assert {:ok, _} = ModelProfiles.put_model_profile(uid, "coding", profile)

    input = send!(ctx, "reconnect", "CHAOS_JOB_CREATE_RECONNECT")
    assert {:ok, _, _} = wait_for_completed_final_reply(ctx.container, input.id, deadline(60_000))
    job = Repo.one!(from j in Job, where: j.source_signal_id == ^input.id)
    event = dispatch!(job)
    workspace = "/workspace/jobs/#{job.id}"

    assert {:ok, true} =
             wait_until(deadline(30_000), fn ->
               DockerWorker.exec!(ctx.container, [
                 "sh",
                 "-c",
                 "cat #{workspace}/state.txt 2>/dev/null || true"
               ]) == "JOB_FILE_BEFORE"
             end)

    before = Repo.get_by!(AgentWorker, agent_uid: uid)
    running = Repo.get!(Job, job.id)
    assert running.status == :running
    assert is_binary(running.runtime_thread_id)
    assert before.capacity["max_slots"] == max_slots

    command_pid =
      DockerWorker.exec!(ctx.container, ["cat", "#{workspace}/old-command.pid"]) |> String.trim()

    driver =
      Ankole.Sessions.driver_pid(%{
        agent_uid: uid,
        session_id: Ankole.BackgroundAgentJobs.job_session_id(job.id)
      })

    assert is_pid(driver)
    assert :ok = DynamicSupervisor.terminate_child(Ankole.Sessions.Drivers, driver)
    restart_control_plane_http_server!(ctx.server_port)

    assert {:ok, rejoined} =
             wait_until(deadline(30_000), fn ->
               worker = Repo.get_by!(AgentWorker, agent_uid: uid)

               (worker.state == :ready and worker.transport_route != before.transport_route) &&
                 worker
             end)

    assert rejoined.generation == before.generation
    assert rejoined.incarnation_id == before.incarnation_id
    retry_until_sent!(Repo.get!(Signal, event.id), DateTime.utc_now(:microsecond))

    assert DockerWorker.exec!(ctx.container, [
             "sh",
             "-c",
             "kill -0 #{command_pid} && touch #{workspace}/allow-write"
           ]) == ""

    completed = wait_job!(job.id, :succeeded)
    assert completed.attempts == running.attempts
    assert completed.runtime_thread_id == running.runtime_thread_id
    assert completed.workspace_owner_job_id == running.workspace_owner_job_id
    assert completed.execution_failures == 0
    assert completed.result["output_text"] =~ "CHAOS_JOB_RECONNECTED"

    assert DockerWorker.exec!(ctx.container, ["cat", "#{workspace}/state.txt"]) ==
             "JOB_FILE_BEFOREJOB_FILE_AFTER"

    assert DockerWorker.exec!(ctx.container, [
             "sh",
             "-c",
             "test -e #{workspace}/late-write.txt && echo survived"
           ]) == "survived\n"

    refute DockerWorker.logs(ctx.container) =~ "already owned by another Job"
  end

  def run do
    # Idle release deletes the instance, and the reply wakes a new one.
    ctx = start_worker_e2e_stack!(replaces_workers: true)
    uid = ctx.agent.uid
    {:ok, profile} = ModelProfiles.get_model_profile(uid, "primary")
    assert {:ok, _profile} = ModelProfiles.put_model_profile(uid, "coding", profile)

    start = send!(ctx, "create", "CHAOS_JOB_CREATE")

    assert {:ok, _reply, _message} =
             wait_for_completed_final_reply(ctx.container, start.id, deadline(60_000))

    assert [created] =
             tool_results(ai_messages_for_signal(start.id), "create_background_job")

    refute tool_result_error?(created)
    job = Repo.one!(from j in Job, where: j.source_signal_id == ^start.id)

    dispatch!(job)
    waiting = wait_job!(job.id, :waiting_on_user)
    assert is_binary(waiting.runtime_thread_id)
    assert waiting.metadata["legacy_thread_replay"] != true
    assert waiting.workspace_owner_job_id == job.id
    path = "/workspace/jobs/#{job.id}/state.txt"
    assert DockerWorker.exec!(ctx.container, ["cat", path]) == "JOB_FILE_BEFORE"

    notice =
      Repo.one!(
        from e in Signal,
          where: e.agent_uid == ^uid and e.type == "background_agent_job.waiting"
      )

    assert {:ok, _} =
             ensure_input_driver!(notice, DateTime.add(notice.available_at, 1, :second))

    assert {:ok, _reply, _message} =
             wait_for_completed_final_reply(ctx.container, notice.id, deadline(60_000))

    old = Repo.get_by!(AgentWorker, agent_uid: uid)
    old_container = DockerWorker.container_name(uid)
    {:ok, provider} = Providers.load(old.provider_id)
    config = provider.settings |> Map.put("idleReleaseAfter", "1s") |> Ankole.JSON.encode!()
    assert {:ok, _provider} = Providers.update(provider.provider_id, %{config: config})

    # Use the real demand deadline. A sandbox transaction would freeze now().
    assert {:ok, true} =
             wait_until(deadline(360_000), fn ->
               Repo.get_by!(AgentWorker, agent_uid: uid).state == :absent
             end)

    assert DockerWorker.container_info(old_container) == nil
    assert Repo.get!(Job, job.id).status == :waiting_on_user

    reply = send!(ctx, "reply", "CHAOS_JOB_REPLY #{job.id}")

    assert {:ok, _reply, _message} =
             wait_for_completed_final_reply(ctx.container, reply.id, deadline(90_000))

    assert [sent] =
             tool_results(ai_messages_for_signal(reply.id), "send_message_to_background_job")

    refute tool_result_error?(sent)

    dispatch!(job, "command.steer")
    completed = wait_job!(job.id, :succeeded)
    assert completed.runtime_thread_id == waiting.runtime_thread_id
    assert completed.workspace_owner_job_id == waiting.workspace_owner_job_id
    assert completed.result["output_text"] =~ "CHAOS_JOB_FINISHED"
    assert Repo.get_by!(AgentWorker, agent_uid: uid).generation != old.generation
    assert DockerWorker.exec!(ctx.container, ["cat", path]) == "JOB_FILE_BEFOREJOB_FILE_AFTER"

    [resume | _] = Enum.filter(FakeOpenAIState.requests(), &(&1.kind == :job_finish))
    assert Ankole.JSON.encode!(resume.request) =~ "JOB_FILE_BEFORE"
    assert Ankole.JSON.encode!(resume.request) =~ "call_job_write"
  end

  defp send!(ctx, suffix, text) do
    message_id = "om_job_recovery_#{suffix}"

    assert :ok =
             FakeFeishu.State.user_sends_message(ctx.fake_feishu.state,
               event_id: "evt_job_recovery_#{suffix}",
               message_id: message_id,
               chat_id: "oc_job_recovery",
               chat_type: "p2p",
               text: "@_user_1 #{text}",
               mentions: [lark_bot_mention()]
             )

    event = signal_by_provider_message_id!(ctx.agent.uid, message_id)
    retry_until_sent!(event, DateTime.add(event.available_at, 1, :second))
    event
  end

  defp dispatch!(job, type \\ "background_agent_job.dispatch") do
    assert {:ok, event} =
             wait_until(deadline(15_000), fn ->
               Repo.one(
                 from e in Signal,
                   where:
                     e.agent_uid == ^job.agent_uid and
                       e.session_id == ^Ankole.BackgroundAgentJobs.job_session_id(job.id) and
                       e.type == ^type,
                   order_by: [desc: e.queue_sequence],
                   limit: 1
               )
             end)

    retry_until_sent!(event, DateTime.add(event.available_at, 1, :second))
    event
  end

  defp wait_job!(id, status) do
    assert {:ok, job} =
             wait_until(deadline(120_000), fn ->
               case Repo.get!(Job, id) do
                 %Job{status: ^status} = job ->
                   job

                 %Job{status: failed} = job when failed in [:failed, :stopped] ->
                   flunk("Job #{id} #{failed}: #{inspect(job.error)}")

                 _job ->
                   nil
               end
             end)

    job
  end
end
