defmodule Ankole.AIAgent.Library.AgentPlugins.Config do
  @moduledoc """
  Installation-wide defaults for Agent Plugins and Skills.

  Agent-specific choices are sparse PostgreSQL overrides owned by the Agent
  Library. These two AppConfigure objects only define what an Agent inherits.
  """

  alias Ankole.AIAgent.Library.AgentPlugins.Contract
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema

  @agent_plugin_defaults_key "ai_agent.library.agent_plugin_defaults"
  @skill_defaults_key "ai_agent.library.skill_defaults"

  @spec definitions() :: [Definition.t()]
  def definitions do
    [agent_plugin_defaults_definition(), skill_defaults_definition()]
  end

  @spec ensure_registered() :: :ok | {:error, term()}
  def ensure_registered do
    Enum.reduce_while(definitions(), :ok, fn definition, :ok ->
      case AppConfigure.register_definitions([definition]) do
        :ok -> {:cont, :ok}
        {:error, {:duplicate_key, key}} when key == definition.key -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec defaults() :: {:ok, %{agent_plugins: map(), skills: map()}} | {:error, term()}
  def defaults do
    with :ok <- ensure_registered(),
         {:ok, agent_plugins} <- AppConfigure.get(agent_plugin_defaults_definition()),
         {:ok, skills} <- AppConfigure.get(skill_defaults_definition()) do
      {:ok, %{agent_plugins: agent_plugins, skills: skills}}
    end
  end

  @spec put_agent_plugin_default(String.t(), boolean()) :: {:ok, map()} | {:error, term()}
  def put_agent_plugin_default(agent_plugin_id, enabled) when is_boolean(enabled) do
    update_default(agent_plugin_defaults_definition(), agent_plugin_id, enabled)
  end

  def put_agent_plugin_default(_agent_plugin_id, _enabled),
    do: {:error, :invalid_agent_plugin_default}

  @spec put_skill_default(String.t(), boolean()) :: {:ok, map()} | {:error, term()}
  def put_skill_default(skill_id, enabled) when is_boolean(enabled) do
    update_default(skill_defaults_definition(), skill_id, enabled)
  end

  def put_skill_default(_skill_id, _enabled), do: {:error, :invalid_skill_default}

  defp update_default(definition, id, enabled) do
    with :ok <- ensure_registered() do
      AppConfigure.update_global(definition, fn values ->
        {:ok, Map.put(values, id, enabled)}
      end)
    end
  end

  defp agent_plugin_defaults_definition do
    AppConfigure.define(
      key: @agent_plugin_defaults_key,
      encrypted: false,
      scope: :global,
      schema: boolean_map_schema(&valid_agent_plugin_id?/1),
      default_value: %{"lark" => false},
      description: "Default enablement inherited by Agents for each Agent Plugin."
    )
  end

  defp skill_defaults_definition do
    AppConfigure.define(
      key: @skill_defaults_key,
      encrypted: false,
      scope: :global,
      schema: boolean_map_schema(&valid_skill_id?/1),
      default_value: %{},
      description:
        "Default enablement inherited by Agents for standalone and Agent Plugin Skills."
    )
  end

  defp boolean_map_schema(valid_id?) do
    Schema.new(fn
      values when is_map(values) ->
        if Enum.all?(values, fn {id, enabled} ->
             is_binary(id) and valid_id?.(id) and is_boolean(enabled)
           end) do
          {:ok, values}
        else
          {:error, :invalid_boolean_map}
        end

      _value ->
        {:error, :not_object}
    end)
  end

  defp valid_agent_plugin_id?(id), do: Contract.validate_identifier(id) == :ok

  defp valid_skill_id?(id) do
    case String.split(id, ":", parts: 2) do
      [skill_name] ->
        Contract.validate_identifier(skill_name) == :ok

      [agent_plugin_id, skill_name] ->
        Contract.validate_identifier(agent_plugin_id) == :ok and
          Contract.validate_identifier(skill_name) == :ok
    end
  end
end
