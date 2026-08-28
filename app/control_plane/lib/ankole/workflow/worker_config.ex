defmodule Ankole.Workflow.WorkerConfig do
  @moduledoc """
  AppConfigure-backed capacity limits for Workflow runs and tasks.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema

  @max_agent_calls_key "workflow.max_agent_calls_per_run"
  @max_agent_calls_default 32
  @max_agent_calls_maximum 1_024

  @max_running_key "workflow.max_running_per_agent"
  @max_running_default 8
  @max_running_maximum 64

  @max_concurrency_key "workflow.max_concurrency_per_run"
  @max_concurrency_default 8
  @max_concurrency_maximum 32

  @spec definitions() :: [Definition.t()]
  def definitions do
    [
      max_agent_calls_definition(),
      max_running_definition(),
      max_concurrency_definition()
    ]
  end

  @spec max_agent_calls_definition() :: Definition.t()
  def max_agent_calls_definition do
    AppConfigure.define(
      key: @max_agent_calls_key,
      encrypted: false,
      schema: Schema.new(&validate_max_agent_calls/1),
      default_value: @max_agent_calls_default,
      description: "Maximum Agent calls that one Workflow run can create."
    )
  end

  @spec max_running_definition() :: Definition.t()
  def max_running_definition do
    AppConfigure.define(
      key: @max_running_key,
      encrypted: false,
      schema: Schema.new(&validate_max_running/1),
      default_value: @max_running_default,
      description: "Maximum concurrently running Workflow tasks for one Agent."
    )
  end

  @spec max_concurrency_definition() :: Definition.t()
  def max_concurrency_definition do
    AppConfigure.define(
      key: @max_concurrency_key,
      encrypted: false,
      schema: Schema.new(&validate_max_concurrency/1),
      default_value: @max_concurrency_default,
      description: "Maximum task concurrency that one Workflow run can request."
    )
  end

  @spec max_agent_calls_per_run() :: pos_integer()
  def max_agent_calls_per_run,
    do: configured(max_agent_calls_definition(), @max_agent_calls_default)

  @spec max_running_per_agent() :: pos_integer()
  def max_running_per_agent,
    do: configured(max_running_definition(), @max_running_default)

  @spec max_concurrency_per_run() :: pos_integer()
  def max_concurrency_per_run,
    do: configured(max_concurrency_definition(), @max_concurrency_default)

  defp configured(definition, default) do
    case AppConfigure.get(definition) do
      {:ok, value} -> value
      _error -> default
    end
  end

  defp validate_max_agent_calls(value)
       when is_integer(value) and value >= 1 and value <= @max_agent_calls_maximum,
       do: {:ok, value}

  defp validate_max_agent_calls(_value),
    do: {:error, {:invalid_workflow_max_agent_calls, %{min: 1, max: @max_agent_calls_maximum}}}

  defp validate_max_running(value)
       when is_integer(value) and value >= 1 and value <= @max_running_maximum,
       do: {:ok, value}

  defp validate_max_running(_value),
    do: {:error, {:invalid_workflow_max_running, %{min: 1, max: @max_running_maximum}}}

  defp validate_max_concurrency(value)
       when is_integer(value) and value >= 1 and value <= @max_concurrency_maximum,
       do: {:ok, value}

  defp validate_max_concurrency(_value),
    do: {:error, {:invalid_workflow_max_concurrency, %{min: 1, max: @max_concurrency_maximum}}}
end
