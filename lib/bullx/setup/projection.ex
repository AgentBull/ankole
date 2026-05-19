defmodule BullX.Setup.Projection do
  @moduledoc false

  import Ecto.Query

  alias BullX.AuthZ
  alias BullX.AuthZ.{PrincipalGroup, PrincipalGroupMembership}
  alias BullX.Principals.{ActivationCode, Principal}
  alias BullX.Repo
  alias BullX.Setup
  alias BullX.Setup.{AIAgents, ChannelSources, EventRouting, LLMProviders, Plugins}

  @bootstrap_metadata_key "bootstrap"
  @setup_steps [:plugins, :llm_providers, :channel_sources, :ai_agents, :event_routing]
  @step_paths %{
    plugins: "/setup/plugins",
    llm_providers: "/setup/llm/providers",
    channel_sources: "/setup/channel-sources",
    ai_agents: "/setup/ai-agents",
    event_routing: "/setup/event-routing-rules",
    activate_admin: "/setup/activate-admin"
  }

  @spec state_for_session(map()) ::
          {:missing_session | :pending | :activation_pending | :completed, map()}
  def state_for_session(session) when is_map(session) do
    case activation_code_for_session(session) do
      {:ok, %ActivationCode{used_at: nil} = code} ->
        {:pending, pending_projection(session, code)}

      {:ok, %ActivationCode{} = code} ->
        activation_projection(session, code)

      {:error, _reason} ->
        {:missing_session, %{redirect_to: "/setup/sessions/new"}}
    end
  end

  @spec step_path(atom()) :: String.t()
  def step_path(step), do: Map.fetch!(@step_paths, step)

  @spec reachable_step?(map(), atom()) :: boolean()
  def reachable_step?(%{earliest_incomplete_step: earliest}, step) do
    step_index(step) <= step_index(earliest)
  end

  def reachable_step?(_projection, _step), do: false

  @spec activation_status_for_session(map()) ::
          :not_activated | :handoff_pending | :complete | :invalid
  def activation_status_for_session(session) do
    case activation_code_for_hash(session[:bootstrap_activation_code_hash]) do
      {:ok, %ActivationCode{used_at: nil}} -> :not_activated
      {:ok, %ActivationCode{} = code} -> handoff_status(code)
      {:error, _reason} -> :invalid
    end
  end

  defp activation_code_for_session(%{bootstrap_activation_code_hash: code_hash}) do
    with {:ok, code} <- activation_code_for_hash(code_hash),
         true <- bootstrap_code?(code),
         true <- session_code_usable?(code) do
      {:ok, code}
    else
      _other -> {:error, :invalid_session}
    end
  end

  defp activation_code_for_session(_session), do: {:error, :invalid_session}

  defp activation_code_for_hash(code_hash) when is_binary(code_hash) and code_hash != "" do
    case Repo.get_by(ActivationCode, code_hash: code_hash) do
      %ActivationCode{} = code -> {:ok, code}
      nil -> {:error, :not_found}
    end
  end

  defp activation_code_for_hash(_code_hash), do: {:error, :missing_hash}

  defp session_code_usable?(%ActivationCode{used_at: %DateTime{}}), do: true

  defp session_code_usable?(%ActivationCode{revoked_at: nil, expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now(:microsecond)) == :gt
  end

  defp session_code_usable?(%ActivationCode{}), do: false

  defp bootstrap_code?(%ActivationCode{metadata: metadata}) when is_map(metadata) do
    metadata[@bootstrap_metadata_key] == true
  end

  defp bootstrap_code?(%ActivationCode{}), do: false

  defp pending_projection(session, %ActivationCode{} = code) do
    steps = step_statuses(session)
    earliest = earliest_incomplete_step(steps)
    requested = Setup.normalize_step(session[:setup_step])
    current = current_step(requested, earliest)

    %{
      activation_code_id: code.id,
      status: :pending,
      current_step: current,
      current_path: step_path(current),
      earliest_incomplete_step: earliest,
      steps: steps,
      plugins: Plugins.status(),
      llm_providers: LLMProviders.status(),
      channel_sources: ChannelSources.status(),
      ai_agents: AIAgents.status(session),
      event_routing: EventRouting.status(session)
    }
  end

  defp activation_projection(session, %ActivationCode{} = code) do
    projection =
      session
      |> pending_projection(code)
      |> Map.merge(%{
        status: :activation_pending,
        current_step: :activate_admin,
        current_path: step_path(:activate_admin),
        earliest_incomplete_step: :activate_admin
      })

    case handoff_status(code) do
      :complete -> {:completed, Map.put(projection, :status, :completed)}
      :handoff_pending -> {:activation_pending, projection}
      :not_activated -> {:activation_pending, projection}
      :invalid -> {:missing_session, %{redirect_to: "/setup/sessions/new"}}
    end
  end

  defp handoff_status(%ActivationCode{used_by_principal_id: nil}), do: :not_activated

  defp handoff_status(%ActivationCode{used_by_principal_id: principal_id}) do
    with %Principal{status: :active, type: :human} = principal <-
           Repo.get(Principal, principal_id),
         %PrincipalGroup{} = admin <- Repo.get_by(PrincipalGroup, name: "admin", built_in: true),
         true <- admin_member?(principal, admin),
         {:ok, groups} <- AuthZ.list_principal_groups(principal),
         true <- Enum.any?(groups, &(&1.name == "all_humans" and &1.built_in)) do
      :complete
    else
      %Principal{} -> :handoff_pending
      false -> :handoff_pending
      nil -> :handoff_pending
      {:error, _reason} -> :handoff_pending
    end
  end

  defp admin_member?(%Principal{id: principal_id}, %PrincipalGroup{id: group_id}) do
    Repo.exists?(
      from membership in PrincipalGroupMembership,
        where: membership.principal_id == ^principal_id and membership.group_id == ^group_id,
        select: 1
    )
  end

  defp step_statuses(session) do
    %{
      plugins: Plugins.status(),
      llm_providers: LLMProviders.status(),
      channel_sources: ChannelSources.status(),
      ai_agents: AIAgents.status(session),
      event_routing: EventRouting.status(session)
    }
  end

  defp earliest_incomplete_step(steps) do
    Enum.find(@setup_steps, :activate_admin, fn step ->
      not get_in(steps, [step, :complete?])
    end)
  end

  defp current_step(nil, earliest), do: earliest

  defp current_step(requested, earliest) do
    case step_index(requested) <= step_index(earliest) do
      true -> requested
      false -> earliest
    end
  end

  defp step_index(step), do: Enum.find_index(Setup.steps(), &(&1 == step)) || 999
end
