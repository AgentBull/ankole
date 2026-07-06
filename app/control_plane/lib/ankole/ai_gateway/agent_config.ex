defmodule Ankole.AIGateway.AgentConfig do
  @moduledoc """
  AppConfigure-backed AI agent runtime policy.

  These settings describe agent behavior, not worker process startup. Resolution
  is scoped: an agent override wins over the installation-wide value, which wins
  over the code default.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema

  @max_output_tokens_key "ai_agent.max_output_tokens"
  @inactivity_timeout_ms_key "ai_agent.inactivity_timeout_ms"
  @default_inactivity_timeout_ms 30 * 60 * 1_000

  @doc """
  Returns the scoped AppConfigure definition for the per-call output cap.

  `nil` means the agent does not request a cap, matching Hermes main-agent
  behavior. Provider/model metadata may describe a maximum, but that capability
  ceiling is not itself a request limit.
  """
  @spec max_output_tokens_definition() :: Definition.t()
  def max_output_tokens_definition do
    AppConfigure.define(
      key: @max_output_tokens_key,
      scope: :scoped,
      encrypted: false,
      schema: max_output_tokens_schema(),
      default_value: nil,
      description:
        "Optional AI agent max output tokens for one model response. nil means no explicit request cap."
    )
  end

  @doc """
  Returns the scoped AppConfigure definition for agent inactivity timeout.

  The value is a model/provider no-activity timeout, not a wall-clock turn cap.
  Tool calls own their own lifecycle semantics while they are running; some
  tracked background tools intentionally continue until completion or explicit
  cancellation. `0` disables the watchdog for agents that are expected to run
  unattended for very long periods.
  """
  @spec inactivity_timeout_ms_definition() :: Definition.t()
  def inactivity_timeout_ms_definition do
    AppConfigure.define(
      key: @inactivity_timeout_ms_key,
      scope: :scoped,
      encrypted: false,
      schema: inactivity_timeout_ms_schema(),
      default_value: @default_inactivity_timeout_ms,
      description:
        "AI agent model/provider inactivity timeout in milliseconds. Running tools own their own lifecycle; 0 disables the watchdog."
    )
  end

  @doc """
  Returns all AppConfigure definitions owned by AI agent runtime policy.
  """
  @spec definitions() :: [Definition.t()]
  def definitions do
    [max_output_tokens_definition(), inactivity_timeout_ms_definition()]
  end

  @doc """
  Registers AI agent runtime policy definitions.
  """
  @spec ensure_registered() :: :ok | {:error, term()}
  def ensure_registered do
    Enum.reduce_while(definitions(), :ok, fn definition, :ok ->
      case AppConfigure.register_definitions([definition]) do
        :ok -> {:cont, :ok}
        {:error, {:duplicate_key, _key}} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Resolves effective agent runtime policy for a turn.

  `:max_completion_tokens` is a model capability ceiling. It only clamps an
  explicit `ai_agent.max_output_tokens`; it never creates one when the policy is
  unset.
  """
  @spec runtime_policy(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def runtime_policy(agent_uid, opts \\ []) when is_binary(agent_uid) do
    with :ok <- ensure_registered(),
         {:ok, max_output_tokens} <- resolve_max_output_tokens(agent_uid, opts),
         {:ok, inactivity_timeout_ms} <- resolve_inactivity_timeout_ms(agent_uid) do
      {:ok,
       %{
         "max_output_tokens" => max_output_tokens,
         "inactivity_timeout_ms" => inactivity_timeout_ms
       }}
    end
  end

  @doc """
  Returns the built-in default inactivity timeout in milliseconds.
  """
  @spec default_inactivity_timeout_ms() :: pos_integer()
  def default_inactivity_timeout_ms, do: @default_inactivity_timeout_ms

  defp resolve_max_output_tokens(agent_uid, opts) do
    max_completion_tokens = Keyword.get(opts, :max_completion_tokens)

    with {:ok, resolution} <-
           AppConfigure.resolve(max_output_tokens_definition(), agent_id: agent_uid) do
      {:ok, clamp_max_output_tokens(resolution.value, max_completion_tokens)}
    end
  end

  defp resolve_inactivity_timeout_ms(agent_uid) do
    with {:ok, resolution} <-
           AppConfigure.resolve(inactivity_timeout_ms_definition(), agent_id: agent_uid) do
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

  defp clamp_max_output_tokens(nil, _max_completion_tokens), do: nil

  defp clamp_max_output_tokens(value, max_completion_tokens)
       when is_integer(value) and is_integer(max_completion_tokens) and max_completion_tokens > 0 do
    min(value, max_completion_tokens)
  end

  defp clamp_max_output_tokens(value, _max_completion_tokens), do: value
end
