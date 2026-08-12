defmodule Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobWorkerConfig do
  @moduledoc """
  AppConfigure-backed worker placement policy for BackgroundAgentJob turns.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema

  @key "agent_computer.background_agent_job.max_turns_per_worker"
  @default 9
  @maximum 1_024

  @agent_cap_key "agent_computer.background_agent_job.max_running_per_agent"
  @agent_cap_default 3
  @agent_cap_maximum 64

  @spec definition() :: Definition.t()
  def definition do
    AppConfigure.define(
      key: @key,
      encrypted: false,
      schema: Schema.new(&validate/1),
      default_value: @default,
      description:
        "Maximum concurrent BackgroundAgentJob turns placed on one Agent Computer worker."
    )
  end

  # Raising this cap raises provider-facing concurrency for the Agent. Confirm
  # provider quota first: parallelism ahead of quota only amplifies rate
  # limiting.
  @spec agent_cap_definition() :: Definition.t()
  def agent_cap_definition do
    AppConfigure.define(
      key: @agent_cap_key,
      encrypted: false,
      schema: Schema.new(&validate_agent_cap/1),
      default_value: @agent_cap_default,
      description:
        "Maximum concurrently running BackgroundAgentJobs per Agent across all workers."
    )
  end

  @spec ensure_registered() :: :ok | {:error, term()}
  def ensure_registered do
    case AppConfigure.register_definitions([definition(), agent_cap_definition()]) do
      :ok -> :ok
      {:error, {:duplicate_key, _key}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec max_turns_per_worker() :: pos_integer()
  def max_turns_per_worker do
    with :ok <- ensure_registered(),
         {:ok, value} <- AppConfigure.get(definition()) do
      value
    else
      _error -> @default
    end
  end

  @spec max_running_per_agent() :: pos_integer()
  def max_running_per_agent do
    with :ok <- ensure_registered(),
         {:ok, value} <- AppConfigure.get(agent_cap_definition()) do
      value
    else
      _error -> @agent_cap_default
    end
  end

  defp validate(value) when is_integer(value) and value >= 1 and value <= @maximum,
    do: {:ok, value}

  defp validate(_value),
    do: {:error, {:invalid_max_background_agent_job_turns_per_worker, %{min: 1, max: @maximum}}}

  defp validate_agent_cap(value)
       when is_integer(value) and value >= 1 and value <= @agent_cap_maximum,
       do: {:ok, value}

  defp validate_agent_cap(_value),
    do:
      {:error, {:invalid_max_background_agent_jobs_per_agent, %{min: 1, max: @agent_cap_maximum}}}
end
