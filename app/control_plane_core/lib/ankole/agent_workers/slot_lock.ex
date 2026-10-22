defmodule Ankole.AgentWorkers.SlotLock do
  @moduledoc "Serializes each Agent's independent work capacity scopes."

  @scopes [:background_agent_jobs, :workflow, :automation_jobs]

  def lock(repo, scope, agent_uid) when scope in @scopes and is_binary(agent_uid) do
    case Ankole.AdvisoryLock.lock(repo, "#{scope}:running_slots:#{agent_uid}") do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def capacity(:automation_jobs) do
    {:ok, value} = Ankole.AppConfigure.get(automation_capacity_definition())
    value
  end

  def automation_capacity_definition do
    Ankole.AppConfigure.define(
      scope: :tenant,
      key: "automation_jobs.max_running_per_agent",
      encrypted: false,
      schema: Ankole.AppConfigure.Schema.new(&validate_capacity/1),
      default_value: 10,
      description: "Maximum concurrently running automation scripts per Agent."
    )
  end

  defp validate_capacity(value) when is_integer(value) and value in 1..64, do: {:ok, value}
  defp validate_capacity(_value), do: {:error, :invalid_automation_job_capacity}
end
