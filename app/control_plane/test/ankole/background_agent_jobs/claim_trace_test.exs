defmodule Ankole.BackgroundAgentJobs.ClaimTraceTest do
  @moduledoc """
  Model-driven trace conformance for `Ankole.BackgroundAgentJobs.Lifecycle`.

  `tools/formal/lean/BackgroundAgentJob.lean` proves the claim-budget and
  slot-accounting contracts. This test drives the real claim, continuation, and
  status-commit paths against PostgreSQL and checks the model's counters.
  """

  use Ankole.AIGatewayCase, async: false

  import Ecto.Query

  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Lifecycle
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Repo

  @moduletag :trace_conformance
  @max_claims 25
  @max_execution_failures 5

  test "claim budgets, expected attempts, and terminal states reject" do
    %{principal: agent} = background_agent_fixture()
    job = job!(agent.uid, "budget")
    spec = %{model_ref: %{"provider_id" => "test"}, request_context: %{}}

    assert {:error, :background_agent_job_attempt_changed} =
             claim(job, agent.uid, job.attempts + 2, spec, 10)

    set_job!(job, attempts: @max_claims)

    assert {:error, :background_agent_job_claims_exhausted} =
             claim(job, agent.uid, @max_claims + 1, spec, 10)

    set_job!(job, attempts: 0, execution_failures: @max_execution_failures)

    assert {:error, :background_agent_job_attempts_exhausted} =
             claim(job, agent.uid, 1, spec, 10)

    set_job!(job, execution_failures: 0, status: :succeeded)

    assert {:error, {:background_agent_job_terminal, %Job{status: :succeeded}}} =
             claim(job, agent.uid, 1, spec, 10)
  end

  test "a running Job holds one slot and leaving running frees it" do
    %{principal: agent} = background_agent_fixture()
    first = job!(agent.uid, "slot-a")
    second = job!(agent.uid, "slot-b")
    spec = %{model_ref: %{"provider_id" => "test"}, request_context: %{}}

    assert {:ok, %Job{status: :running, attempts: 1}} =
             claim(first, agent.uid, 1, spec, 1)

    assert {:error, :background_agent_job_agent_at_capacity} =
             claim(second, agent.uid, 1, spec, 1)

    assert {:ok, %Job{status: :stopped}} = Ankole.Ash.update(first, :stop, %{})

    assert {:ok, %Job{status: :running, attempts: 1}} =
             claim(second, agent.uid, 1, spec, 1)
  end

  test "continuation claims obey the attempt budget" do
    %{principal: agent} = background_agent_fixture()
    job = job!(agent.uid, "continuation")
    spec = %{model_ref: %{"provider_id" => "test"}, request_context: %{}}

    set_job!(job, status: :queued, attempts: 1)
    assert {:ok, %Job{status: :running, attempts: 2}} = continuation(job, agent.uid, 2, spec, 10)

    set_job!(job, status: :queued, attempts: @max_claims)

    assert {:error, :background_agent_job_claims_exhausted} =
             continuation(job, agent.uid, @max_claims + 1, spec, 10)
  end

  test "a claimed attempt cannot be claimed again" do
    %{principal: agent} = background_agent_fixture()
    job = job!(agent.uid, "concurrent")
    spec = %{model_ref: %{"provider_id" => "test"}, request_context: %{}}

    assert {:ok, %Job{status: :running, attempts: 1}} = claim(job, agent.uid, 1, spec, 10)
    assert {:error, :background_agent_job_attempt_changed} = claim(job, agent.uid, 1, spec, 10)
    assert %Job{status: :running, attempts: 1} = fetch!(job)
  end

  defp claim(%Job{} = job, agent_uid, expected_attempt, spec, cap) do
    Repo.transact(fn ->
      Lifecycle.claim_attempt_in_tx(job.id, agent_uid, expected_attempt, spec, cap)
    end)
  end

  defp continuation(%Job{} = job, agent_uid, expected_attempt, spec, cap) do
    Repo.transact(fn ->
      Lifecycle.claim_continuation_in_tx(job.id, agent_uid, expected_attempt, spec, cap)
    end)
  end

  defp set_job!(%Job{} = job, attrs) do
    Repo.update_all(from(j in Job, where: j.id == ^job.id), set: attrs)
  end

  defp fetch!(%Job{} = job), do: Repo.get!(Job, job.id)

  defp job!(agent_uid, suffix) do
    source = Ankole.WorkFixtures.service_source(agent_uid)
    room = room!(agent_uid, "claim-trace-#{suffix}")

    assert {:ok, %{job: %Job{} = job}} =
             BackgroundAgentJobs.create_with_dispatch(%{
               "source_signal_id" => source.id,
               "agent_uid" => agent_uid,
               "owner_session_id" => "parent-session",
               "source_tool_call_id" => "tool-claim-trace-#{suffix}",
               "title" => "Claim trace #{suffix}",
               "task" => "Exercise the claim budget.",
               "reply_route" => %{
                 "binding_name" => "lark",
                 "conversation_id" => room,
                 "provider_thread_id" => "thread-#{suffix}",
                 "provider_message_id" => "message-#{suffix}"
               }
             })

    job
  end

  defp room!(agent_uid, provider_id) do
    binding =
      Ankole.SignalsFixtures.binding_fixture(agent_uid, "lark", :record_only, adapter: "mock")

    {:ok, conversation} =
      Repo.transact(fn ->
        Ankole.Conversations.External.observe_conversation_in_tx(
          binding,
          %{
            provider_conversation_id: "test:claim-trace:#{provider_id}",
            external_kind: :im_group,
            reply_mode: :entry
          },
          DateTime.utc_now(:microsecond)
        )
      end)

    conversation.id
  end
end
