defmodule Ankole.AIAgent.Library.SkillEnablementProviders do
  @moduledoc """
  Resolves plugin declarations for builtin Skill execution profiles and applies
  their effective-enablement projection.

  Skill bundles declare profile membership in their own metadata. Active
  plugins contribute the provider implementation for a profile. A builtin Skill
  whose provider is absent remains disabled, so disabling or removing a plugin
  cannot expose a stale persisted enablement flag.
  """

  alias Ankole.AIAgent.Library.Schemas.AgentSkill
  alias Ankole.AIAgent.Library.SkillEnablementProvider.Context
  alias Ankole.Plugins.Registry
  alias Ankole.Repo

  @contract_id "ai_agent.library.skill_enablement_provider"

  defmodule Definition do
    @moduledoc """
    Normalized provider declaration consumed by the Agent Library.
    """

    @enforce_keys [:id, :module]
    defstruct [:id, :plugin_id, :module]

    @type t :: %__MODULE__{
            id: String.t(),
            plugin_id: String.t() | nil,
            module: module()
          }
  end

  @doc """
  Lists active Skill enablement providers as normalized Library definitions.
  """
  @spec list(GenServer.server()) ::
          {:ok, [Definition.t()]}
          | {:error, :skill_enablement_provider_registry_unavailable | term()}
  def list(server \\ Registry) do
    with {:ok, declarations} <- declarations(server) do
      collect_results(Enum.map(declarations, &resolve_declaration/1))
    end
  end

  @doc """
  Filters one Agent's Skill rows by their effective enablement.

  Persisted flags remain authoritative for ordinary and installed Skills.
  Provider-backed builtin Skills use the provider mode without rewriting those
  flags.
  """
  @spec filter_enabled(String.t(), [AgentSkill.t()], keyword()) ::
          {:ok, [AgentSkill.t()]} | {:error, term()}
  def filter_enabled(agent_uid, skills, opts \\ [])

  def filter_enabled(agent_uid, skills, opts)
      when is_binary(agent_uid) and is_list(skills) and is_list(opts) do
    profiles =
      skills
      |> Enum.map(&execution_profile/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    with {:ok, modes} <- resolve_profile_modes(agent_uid, profiles, opts) do
      {:ok, Enum.filter(skills, &effectively_enabled?(&1, modes))}
    end
  end

  def filter_enabled(_agent_uid, _skills, _opts),
    do: {:error, :invalid_skill_enablement_request}

  @doc """
  Returns whether one Skill row is effectively enabled.
  """
  @spec enabled?(String.t(), AgentSkill.t(), keyword()) ::
          {:ok, boolean()} | {:error, term()}
  def enabled?(agent_uid, %AgentSkill{} = skill, opts \\ []) do
    with {:ok, enabled} <- filter_enabled(agent_uid, [skill], opts) do
      {:ok, enabled != []}
    end
  end

  @doc false
  @spec validate_declaration(map()) :: :ok | {:error, term()}
  def validate_declaration(declaration) when is_map(declaration) do
    case resolve_declaration(declaration) do
      {:ok, %Definition{}} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def validate_declaration(declaration),
    do: {:error, {:invalid_skill_enablement_provider_declaration, declaration}}

  defp resolve_profile_modes(_agent_uid, [], _opts), do: {:ok, %{}}

  defp resolve_profile_modes(agent_uid, profiles, opts) do
    registry = Keyword.get(opts, :plugin_registry, Registry)
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, definitions} <- list(registry) do
      definitions_by_id = Map.new(definitions, &{&1.id, &1})
      context = %Context{agent_uid: agent_uid, repo: repo}

      Enum.reduce_while(profiles, {:ok, %{}}, fn profile, {:ok, modes} ->
        case Map.fetch(definitions_by_id, profile) do
          :error ->
            {:cont, {:ok, modes}}

          {:ok, definition} ->
            case resolve_mode(definition, context) do
              {:ok, mode} -> {:cont, {:ok, Map.put(modes, profile, mode)}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
        end
      end)
    end
  end

  defp resolve_mode(%Definition{id: id, module: module}, %Context{} = context) do
    case module.resolve(context) do
      {:ok, :manual} ->
        {:ok, :manual}

      {:ok, {:projected, enabled?}} when is_boolean(enabled?) ->
        {:ok, {:projected, enabled?}}

      {:error, reason} ->
        {:error, {:skill_enablement_provider_failed, id, reason}}

      result ->
        {:error, {:invalid_skill_enablement_provider_result, id, result}}
    end
  end

  defp effectively_enabled?(%AgentSkill{} = skill, modes) do
    case execution_profile(skill) do
      nil ->
        skill.enabled

      profile ->
        case Map.get(modes, profile) do
          :manual -> skill.enabled
          {:projected, enabled?} -> enabled?
          nil -> false
        end
    end
  end

  defp execution_profile(%AgentSkill{
         source_kind: "builtin",
         metadata: %{"execution_profile" => profile}
       })
       when is_binary(profile) and profile != "",
       do: profile

  defp execution_profile(%AgentSkill{}), do: nil

  defp declarations(server) do
    try do
      {:ok, Registry.adapter_declarations(@contract_id, server)}
    catch
      :exit, _reason -> {:error, :skill_enablement_provider_registry_unavailable}
    end
  end

  defp resolve_declaration(declaration) do
    with id when is_binary(id) and id != "" <- value(declaration, :id),
         module when is_atom(module) and not is_nil(module) <- value(declaration, :module),
         {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :resolve, 1) do
      {:ok,
       %Definition{
         id: id,
         plugin_id: value(declaration, :plugin_id),
         module: module
       }}
    else
      _invalid -> {:error, {:invalid_skill_enablement_provider_declaration, declaration}}
    end
  end

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp collect_results(results) do
    results
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _reason} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end
end
