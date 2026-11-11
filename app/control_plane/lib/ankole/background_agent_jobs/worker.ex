defmodule Ankole.BackgroundAgentJobs.Worker do
  @moduledoc false

  alias Ankole.AgentWorkers
  alias Ankole.AgentWorkers.RunnerDevices
  alias Ankole.BackgroundAgentJobs.Schemas.Job

  def authorize_for_work(_human_uid, _agent_uid, nil), do: :ok

  def authorize_for_work(human_uid, agent_uid, runner_id),
    do: RunnerDevices.authorize_for_job(human_uid, agent_uid, runner_id)

  def lock_in_tx(%Job{agent_uid: agent_uid, runner_id: nil}),
    do: AgentWorkers.lock_in_tx(agent_uid)

  def lock_in_tx(%Job{agent_uid: agent_uid, runner_id: runner_id}) do
    _runner = RunnerDevices.lock_runner_in_tx(runner_id)
    RunnerDevices.lock_binding_in_tx(agent_uid, runner_id)
  end

  def reserve_in_tx(%Job{agent_uid: agent_uid, runner_id: nil}),
    do: AgentWorkers.reserve_slot_in_tx(agent_uid)

  def reserve_in_tx(%Job{agent_uid: agent_uid, runner_id: runner_id}),
    do: RunnerDevices.reserve_slot_in_tx(agent_uid, runner_id)

  def connected(agent_uid, nil), do: AgentWorkers.connected_worker(agent_uid)

  def connected(agent_uid, runner_id),
    do: RunnerDevices.connected_worker(agent_uid, runner_id)

  def ready_for_mode?(agent_uid, runner_id, "adopt"),
    do: match?({:ok, _worker}, connected(agent_uid, runner_id))

  def ready_for_mode?(agent_uid, nil, _mode),
    do: match?({:ok, _worker}, AgentWorkers.ready_worker(agent_uid))

  def ready_for_mode?(agent_uid, runner_id, _mode),
    do: match?({:ok, %{state: :ready}}, connected(agent_uid, runner_id))
end
