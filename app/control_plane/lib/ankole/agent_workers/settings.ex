defmodule Ankole.AgentWorkers.Settings do
  @moduledoc "The installation's Worker readiness timeout. Other lifecycle settings belong to providers."

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema

  @default_seconds 600
  @maximum_seconds 365 * 24 * 3600

  @spec definitions() :: [Definition.t()]
  def definitions do
    [
      AppConfigure.define(
        key: "agent_workers.ready_timeout_seconds",
        scope: :global,
        encrypted: false,
        schema: Schema.new(&validate_seconds/1),
        default_value: @default_seconds,
        description:
          "Worker readiness timeout in seconds for instance rebuilds and new task attempts."
      )
    ]
  end

  @spec current() :: %{ready_timeout_ms: pos_integer()}
  def current do
    [definition] = definitions()

    {:ok, seconds} = AppConfigure.get(definition)
    %{ready_timeout_ms: seconds * 1000}
  end

  defp validate_seconds(value)
       when is_integer(value) and value >= 1 and value <= @maximum_seconds,
       do: {:ok, value}

  defp validate_seconds(_value),
    do: {:error, {:invalid_worker_lifecycle_seconds, %{min: 1, max: @maximum_seconds}}}
end
