defmodule Ankole.Sessions.BackgroundAgentJobCap do
  @moduledoc """
  AppConfigure-backed concurrency cap of BackgroundAgentJobs per Agent.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema

  @agent_cap_key "background_agent_jobs.max_running_per_agent"
  @agent_cap_default 3
  @agent_cap_maximum 64

  # Raising this cap raises provider-facing concurrency for the Agent. Confirm
  # provider quota first: parallelism ahead of quota only amplifies rate
  # limiting.
  @spec definition() :: Definition.t()
  def definition do
    AppConfigure.define(
      scope: :tenant,
      key: @agent_cap_key,
      encrypted: false,
      schema: Schema.new(&validate_agent_cap/1),
      default_value: @agent_cap_default,
      description: "Maximum concurrently running BackgroundAgentJobs per Agent."
    )
  end

  @spec max_running_per_agent() :: pos_integer()
  def max_running_per_agent do
    {:ok, value} = AppConfigure.get(definition())
    value
  end

  defp validate_agent_cap(value)
       when is_integer(value) and value >= 1 and value <= @agent_cap_maximum,
       do: {:ok, value}

  defp validate_agent_cap(_value),
    do:
      {:error, {:invalid_max_background_agent_jobs_per_agent, %{min: 1, max: @agent_cap_maximum}}}
end
