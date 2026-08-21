defmodule Ankole.SignalsGateway.ActorRuntime.AgentConfig do
  @moduledoc """
  AppConfigure-backed policy for one Agent Computer loop.

  These settings are snapshotted into `turn_start.request_context.ai_agent`.
  They belong to the actor turn rather than to any individual LLM Response.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema

  @max_output_tokens_key "ai_agent.max_output_tokens"
  @inactivity_timeout_ms_key "ai_agent.inactivity_timeout_ms"
  @max_iterations_key "ai_agent.max_iterations"
  @default_inactivity_timeout_ms 30 * 60 * 1_000
  @default_max_iterations 90

  @spec max_output_tokens_definition() :: Definition.t()
  def max_output_tokens_definition do
    AppConfigure.define(
      key: @max_output_tokens_key,
      scope: :scoped,
      encrypted: false,
      schema: max_output_tokens_schema(),
      default_value: nil,
      description:
        "Optional Agent Computer max output tokens for one model response. nil means no explicit request cap."
    )
  end

  @spec inactivity_timeout_ms_definition() :: Definition.t()
  def inactivity_timeout_ms_definition do
    AppConfigure.define(
      key: @inactivity_timeout_ms_key,
      scope: :scoped,
      encrypted: false,
      schema: inactivity_timeout_ms_schema(),
      default_value: @default_inactivity_timeout_ms,
      description:
        "Agent Computer model/provider inactivity timeout in milliseconds. Running tools own their lifecycle; 0 disables the watchdog."
    )
  end

  @doc """
  Returns the scoped turn-iteration budget definition.

  One iteration is one logical model call. Provider retries inside that call do
  not consume another iteration, and a redelivered Actor turn starts fresh.
  """
  @spec max_iterations_definition() :: Definition.t()
  def max_iterations_definition do
    AppConfigure.define(
      key: @max_iterations_key,
      scope: :scoped,
      encrypted: false,
      schema: max_iterations_schema(),
      default_value: @default_max_iterations,
      description: "Maximum logical model iterations for one Agent Computer turn execution."
    )
  end

  @spec definitions() :: [Definition.t()]
  def definitions do
    [
      max_output_tokens_definition(),
      inactivity_timeout_ms_definition(),
      max_iterations_definition()
    ]
  end

  @spec runtime_policy(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def runtime_policy(agent_uid, opts \\ []) when is_binary(agent_uid) do
    with {:ok, max_output_tokens} <- resolve_max_output_tokens(agent_uid, opts),
         {:ok, inactivity_timeout_ms} <- resolve(agent_uid, inactivity_timeout_ms_definition()),
         {:ok, max_iterations} <- resolve(agent_uid, max_iterations_definition()) do
      {:ok,
       %{
         "max_output_tokens" => max_output_tokens,
         "inactivity_timeout_ms" => inactivity_timeout_ms,
         "max_iterations" => max_iterations
       }}
    end
  end

  @spec default_inactivity_timeout_ms() :: pos_integer()
  def default_inactivity_timeout_ms, do: @default_inactivity_timeout_ms

  @spec default_max_iterations() :: pos_integer()
  def default_max_iterations, do: @default_max_iterations

  defp resolve_max_output_tokens(agent_uid, opts) do
    max_completion_tokens = Keyword.get(opts, :max_completion_tokens)

    with {:ok, value} <- resolve(agent_uid, max_output_tokens_definition()) do
      {:ok, clamp_max_output_tokens(value, max_completion_tokens)}
    end
  end

  defp resolve(agent_uid, definition) do
    with {:ok, resolution} <- AppConfigure.resolve(definition, agent_id: agent_uid) do
      {:ok, resolution.value}
    end
  end

  defp max_output_tokens_schema do
    Schema.new(fn
      nil -> {:ok, nil}
      value when is_integer(value) and value > 0 -> {:ok, value}
      _value -> {:error, :invalid_ai_agent_max_output_tokens}
    end)
  end

  defp inactivity_timeout_ms_schema do
    Schema.new(fn
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _value -> {:error, :invalid_ai_agent_inactivity_timeout_ms}
    end)
  end

  defp max_iterations_schema do
    Schema.new(fn
      value when is_integer(value) and value > 0 -> {:ok, value}
      _value -> {:error, :invalid_ai_agent_max_iterations}
    end)
  end

  defp clamp_max_output_tokens(nil, _max_completion_tokens), do: nil

  defp clamp_max_output_tokens(value, max_completion_tokens)
       when is_integer(value) and is_integer(max_completion_tokens) and max_completion_tokens > 0 do
    min(value, max_completion_tokens)
  end

  defp clamp_max_output_tokens(value, _max_completion_tokens), do: value
end
