defmodule Ankole.Sessions.Context do
  @moduledoc """
  Resolves the current Agent and conversation facts from their domain owners.

  The driver and Codex Job admission use the same documents, capability
  catalog, and conversation origin. A Job uses its parent conversation.
  Transcript history stays in AIGateway.
  """

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.Providers
  alias Ankole.Sessions.AgentConfig
  alias Ankole.AIGateway.Schemas.Conversation
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.RuntimeProjection
  alias Ankole.Sessions.Prompt
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Principals.Agent, as: PrincipalAgent
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.Sessions.ModelHistory
  alias Ankole.Conversations.ExternalTarget
  alias Ankole.SystemConfig

  @spec resolve(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def resolve(agent_uid, session_id) do
    with {:ok, conversation} <- resolve_conversation(agent_uid, session_id),
         {:ok, agent} <- agent_profile(agent_uid),
         {:ok, documents} <- Library.list_agent_documents(agent_uid),
         {:ok, %{"skills" => skills, "agent_plugins" => agent_plugins}} <-
           Library.runtime_catalog_for_agent(agent_uid) do
      {:ok,
       %{
         agent: agent,
         conversation: conversation_info(conversation),
         documents: documents,
         skills: skills,
         agent_plugins: agent_plugins
       }}
    end
  end

  @doc "Selects the Job's Skills from its claimed execution projection."
  def job(context, %Job{} = job) do
    with %{} = projection <- job.runtime_projection do
      skills =
        RuntimeProjection.selected_skills(projection, context.skills, context.agent_plugins)

      {:ok,
       %{context | skills: skills}
       |> Map.put(:skills_prompt, Prompt.skills_catalog(skills, :background_job))}
    else
      {:error, _} = error -> error
      _invalid -> {:error, :background_agent_job_runtime_projection_invalid}
    end
  end

  defp resolve_conversation(agent_uid, session_id) do
    case BackgroundAgentJobs.parse_job_session_id(session_id) do
      {:ok, job_id} -> resolve_job_conversation(agent_uid, job_id)
      :error -> resolve_root_conversation(agent_uid, session_id)
    end
  end

  defp resolve_job_conversation(agent_uid, job_id) do
    with %Job{} = job <- Repo.get_by(Job, id: job_id, agent_uid: agent_uid),
         conversation_id when is_binary(conversation_id) <-
           Map.get(job.metadata || %{}, "owner_conversation_id"),
         %Conversation{} = conversation <-
           Repo.get_by(Conversation, id: conversation_id, subject_uid: agent_uid) do
      {:ok, conversation}
    else
      _missing -> {:error, :owner_conversation_not_found}
    end
  end

  defp resolve_root_conversation(agent_uid, session_id) do
    case ModelHistory.active_conversation(agent_uid, session_id) do
      %Conversation{} = conversation -> {:ok, conversation}
      nil -> {:error, :conversation_not_found}
    end
  end

  defp conversation_info(conversation) do
    %{
      id: conversation.id,
      key: conversation.conversation_key,
      started_at: datetime(conversation.inserted_at) || "",
      timezone: installation_timezone(),
      origin_channel: ExternalTarget.origin(conversation)
    }
  end

  defp agent_profile(agent_uid) do
    case Repo.get(Principal, agent_uid) do
      %Principal{} = principal ->
        agent = Repo.get(PrincipalAgent, principal.uid)

        {:ok,
         %{
           display_name: principal.display_name || principal.uid,
           role: agent_role(agent)
         }}

      nil ->
        {:error, :agent_profile_not_found}
    end
  end

  defp agent_role(%PrincipalAgent{role: role}) when is_binary(role), do: role
  defp agent_role(_agent), do: ""

  defp installation_timezone do
    case SystemConfig.timezone() do
      {:ok, timezone} -> timezone
      {:error, _reason} -> SystemConfig.default_timezone()
    end
  end

  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp datetime(_value), do: nil

  @spec runtime(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def runtime(session_key, opts \\ []) when is_map(session_key) do
    with {:ok, turn_basis} <- turn_basis(session_key.agent_uid, opts),
         {:ok, custom_model_profiles} <-
           ModelProfiles.list_custom_model_profiles(session_key.agent_uid) do
      model_ref = turn_basis.model_ref

      {:ok,
       %{
         model_ref: model_ref,
         request_context:
           request_context(
             turn_basis.runtime_policy,
             Keyword.get(opts, :request_context, %{})
             |> Map.put("custom_model_profiles", custom_model_profiles)
           )
       }
       |> Ankole.Attrs.maybe_put(:hosted_tools, turn_basis.hosted_tools)}
    end
  end

  defp turn_basis(agent_uid, opts) do
    case Keyword.fetch(opts, :turn_start_overrides) do
      {:ok, {:ok, overrides}} -> frozen_turn_basis(overrides)
      {:ok, {:error, _reason} = error} -> error
      {:ok, other} -> {:error, {:invalid_turn_start_overrides, other}}
      :error -> resolved_turn_basis(agent_uid, opts)
    end
  end

  defp resolved_turn_basis(agent_uid, opts) do
    with {:ok, model_ref} <-
           turn_model_ref(agent_uid, Keyword.get(opts, :profile, "primary")),
         {:ok, runtime_policy} <-
           AgentConfig.runtime_policy(agent_uid,
             max_completion_tokens: model_ref["max_completion_tokens"]
           ),
         {:ok, hosted_capabilities} <- ModelProfiles.provider_hosted_capabilities(agent_uid) do
      {:ok,
       %{
         model_ref: model_ref,
         runtime_policy:
           Map.put(runtime_policy, "provider_hosted", %{
             "web_search" => ModelProfiles.provider_hosted?(hosted_capabilities, "web_search"),
             "image_generate" =>
               ModelProfiles.provider_hosted?(hosted_capabilities, "image_generate")
           }),
         hosted_tools: hosted_tools(agent_uid, model_ref, hosted_capabilities)
       }}
    end
  end

  defp frozen_turn_basis(
         %{
           model_ref: %{} = model_ref,
           request_context: %{"ai_agent" => %{} = runtime_policy}
         } = overrides
       ) do
    {:ok,
     %{
       model_ref: model_ref,
       runtime_policy: runtime_policy,
       hosted_tools: Map.get(overrides, :hosted_tools)
     }}
  end

  defp frozen_turn_basis(_overrides), do: {:error, :invalid_turn_start_overrides}

  defp request_context(runtime_policy, extra_context) when is_map(extra_context) do
    Map.put(extra_context, "ai_agent", runtime_policy)
  end

  defp request_context(runtime_policy, _extra_context) do
    request_context(runtime_policy, %{})
  end

  defp turn_model_ref(agent_uid, profile) do
    case ModelProfiles.resolve_runtime_model_ref(agent_uid, profile) do
      {:ok, model_ref} -> {:ok, model_ref}
      {:error, reason} -> {:error, {:model_profile_unavailable, profile, reason}}
    end
  end

  # A capability the Agent leaves to its Provider is declared to the Provider and
  # has no Ankole tool this turn. A Provider that cannot run it means the Agent
  # simply has no such capability: falling back to a configured profile would
  # silently change who executes the work and what the result looks like.
  defp hosted_tools(agent_uid, model_ref, hosted_capabilities) do
    case image_generation_hosted_tools(agent_uid, model_ref, hosted_capabilities) ++
           web_search_hosted_tools(model_ref, hosted_capabilities) ++ brain_hosted_tools() do
      [] -> nil
      tools -> tools
    end
  end

  # Memory is an installation capability that AIGateway executes on every
  # provider, so its declaration follows `brain.enabled` alone. The driver
  # decides the operation subset and the injection per Turn kind.
  defp brain_hosted_tools do
    if Ankole.Brain.Config.enabled?(), do: [%{"type" => "brain"}], else: []
  end

  defp image_generation_hosted_tools(agent_uid, model_ref, hosted_capabilities) do
    if ModelProfiles.provider_hosted?(hosted_capabilities, "image_generate") do
      if Providers.supports_native_image_generation?(model_ref),
        do: [%{"type" => "image_generation"}],
        else: []
    else
      case ModelProfiles.resolve_runtime_profile(agent_uid, "image_generate") do
        {:ok, _runtime_profile} -> [%{"type" => "image_generation"}]
        {:error, _reason} -> []
      end
    end
  end

  # Unlike image generation, an Ankole-executed web search is a control-plane tool
  # rather than a gateway-composed hosted tool, so the Agent's own choice needs
  # no declaration here.
  defp web_search_hosted_tools(model_ref, hosted_capabilities) do
    if ModelProfiles.provider_hosted?(hosted_capabilities, "web_search") and
         Providers.supports_native_web_search?(model_ref) do
      [%{"type" => "web_search"}]
    else
      []
    end
  end
end
