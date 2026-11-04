defmodule Ankole.AgentWorkers.SlotLock do
  @moduledoc "Serializes each Agent's independent work capacity scopes."

  @scopes [:background_agent_jobs, :workflow]

  def lock(scope, agent_uid) when scope in @scopes and is_binary(agent_uid) do
    case Ankole.AdvisoryLock.lock(Ankole.Repo, "#{scope}:running_slots:#{agent_uid}") do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
