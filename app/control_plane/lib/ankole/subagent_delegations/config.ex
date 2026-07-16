defmodule Ankole.SubagentDelegations.Config do
  @moduledoc """
  AppConfigure-owned Deep Research execution and managed-workspace policy.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema

  @key "agent_computer.deep_research"
  @defaults %{
    "wallclock_budget" => 2 * 60 * 60 * 1_000,
    "submission_grace" => 10 * 60 * 1_000,
    "retention_days" => 30
  }
  @keys Map.keys(@defaults)

  @spec definition() :: Definition.t()
  def definition do
    AppConfigure.define(
      key: @key,
      scope: :scoped,
      encrypted: false,
      schema: Schema.new(&validate/1),
      default_value: @defaults,
      description: "Deep Research wallclock and managed-workspace retention policy."
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

  @spec retention_days_for_agent(String.t()) :: {:ok, pos_integer()} | {:error, term()}
  def retention_days_for_agent(agent_uid) when is_binary(agent_uid) do
    with :ok <- ensure_registered(),
         {:ok, value} <- AppConfigure.get(definition(), agent_id: agent_uid) do
      {:ok, Map.fetch!(value, "retention_days")}
    end
  end

  defp validate(value) when is_map(value) do
    with [] <- Map.keys(value) -- @keys,
         [] <- @keys -- Map.keys(value),
         :ok <- integer_between(value, "wallclock_budget", 60_000, 24 * 60 * 60 * 1_000),
         :ok <- integer_between(value, "submission_grace", 0, 60 * 60 * 1_000),
         :ok <- integer_between(value, "retention_days", 1, 3_650) do
      {:ok, value}
    else
      unknown when is_list(unknown) -> {:error, {:invalid_deep_research_keys, unknown}}
      {:error, _reason} = error -> error
    end
  end

  defp validate(_value), do: {:error, :invalid_deep_research_config}

  defp integer_between(value, key, minimum, maximum) do
    case Map.get(value, key) do
      number when is_integer(number) and number >= minimum and number <= maximum -> :ok
      _value -> {:error, {:invalid_deep_research_value, key, %{min: minimum, max: maximum}}}
    end
  end
end
