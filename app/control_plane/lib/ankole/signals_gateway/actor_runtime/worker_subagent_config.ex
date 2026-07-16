defmodule Ankole.SignalsGateway.ActorRuntime.WorkerSubagentConfig do
  @moduledoc """
  AppConfigure-backed worker placement policy for subagent delegation turns.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema

  @key "agent_computer.subagent.max_delegation_turns_per_worker"
  @default 9
  @maximum 1_024

  @spec definition() :: Definition.t()
  def definition do
    AppConfigure.define(
      key: @key,
      encrypted: false,
      schema: Schema.new(&validate/1),
      default_value: @default,
      description:
        "Maximum concurrent subagent delegation turns placed on one Agent Computer worker."
    )
  end

  @spec ensure_registered() :: :ok | {:error, term()}
  def ensure_registered do
    case AppConfigure.register_definitions([definition()]) do
      :ok -> :ok
      {:error, {:duplicate_key, _key}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec max_delegation_turns_per_worker() :: pos_integer()
  def max_delegation_turns_per_worker do
    with :ok <- ensure_registered(),
         {:ok, value} <- AppConfigure.get(definition()) do
      value
    else
      _error -> @default
    end
  end

  defp validate(value) when is_integer(value) and value >= 1 and value <= @maximum,
    do: {:ok, value}

  defp validate(_value),
    do: {:error, {:invalid_max_delegation_turns_per_worker, %{min: 1, max: @maximum}}}
end
