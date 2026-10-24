defmodule Ankole.Principals.Agents do
  @moduledoc false

  require Ash.Query

  alias Ankole.AgentWorkers
  alias Ankole.AIAgent.Library
  alias Ankole.Principals
  alias Ankole.Principals.{Agent, Humans, Principal}
  alias Ankole.Repo

  @agent_fields [
    :handle,
    :type,
    :role,
    :options,
    :owner_principal_uid,
    :group_memory_disclosure_mode,
    :created_by
  ]

  @owned_ai_agent_keys ~w(models provider_hosted token_quota)

  def create_agent(attrs) when is_map(attrs) do
    with {:ok, _handle} <- Humans.required_text(attrs, :handle) do
      attrs = attrs |> Map.delete("uid") |> Map.put(:uid, Ash.UUIDv7.generate())
      Repo.transact_top_level(fn -> create_agent_in_tx(attrs) end)
    end
  end

  def create_agent_in_tx(attrs) do
    agent_attrs = Humans.take_attrs(attrs, @agent_fields)
    provider_id = Ankole.Attrs.get(attrs, :worker_provider_id)

    with {:ok, provider_id} <- Ankole.AgentWorkers.Providers.select_in_tx(provider_id),
         :ok <- validate_agent_owner(agent_attrs),
         :ok <- reject_token_quota_at_creation(agent_attrs),
         {:ok, principal} <- Humans.insert_principal(agent_principal_attrs(attrs)),
         {:ok, agent} <- insert_agent(principal.uid, agent_attrs),
         :ok <- Library.seed_agent_library_in_tx(principal.uid),
         :ok <- AgentWorkers.insert_in_tx(principal.uid, provider_id) do
      {:ok, %{principal: principal, agent: agent}}
    end
  end

  def get_agent(uid) do
    with {:ok, normalized_uid} <- Principals.normalize_uid(uid) do
      case Agent
           |> Ash.Query.filter(uid == ^normalized_uid)
           |> Ash.Query.load(:principal)
           |> Ankole.Ash.read_one!() do
        %Agent{principal: %Principal{} = principal} = agent ->
          {:ok, %{principal: principal, agent: agent}}

        _missing ->
          {:error, :not_found}
      end
    end
  end

  def list_active_agents, do: list_agents(status: :active)

  def list_agents(opts \\ []) do
    Agent
    |> Ash.Query.filter(principal.type == :agent)
    |> filter_agent_status(Keyword.get(opts, :status))
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.Query.load(:principal)
    |> Ankole.Ash.read!()
    |> Enum.map(fn %Agent{principal: principal} = agent ->
      %{principal: principal, agent: agent}
    end)
  end

  defp filter_agent_status(query, :active),
    do: Ash.Query.filter(query, principal.status == :active)

  defp filter_agent_status(query, nil), do: query

  def update_agent(uid, attrs) when is_map(attrs) do
    Repo.transact_top_level(fn -> update_agent_in_tx(uid, attrs) end)
  end

  def update_agent_in_tx(uid, attrs) do
    agent_attrs = Humans.take_attrs(attrs, @agent_fields)

    with {:ok, principal} <- Humans.lock_principal_in_tx(uid),
         :ok <- Humans.ensure_principal_type(principal, :agent),
         :ok <- validate_agent_owner(agent_attrs),
         {:ok, principal} <- Humans.update_principal_profile(principal, attrs),
         {:ok, agent} <- update_agent_row(principal.uid, agent_attrs) do
      {:ok, %{principal: principal, agent: agent}}
    end
  end

  # The AuthZ check takes the admin group lock, and the installation-wide lock
  # order puts that lock before the principal row lock. Every path that
  # disables a principal must go through here so the order cannot invert.
  def enable_agent(uid) do
    case Repo.transact_top_level(
           fn -> enable_agent_in_tx(uid) end,
           after_commit: &publish_agent_changes/1
         ) do
      {:ok, {%Principal{} = principal, _conversation_ids}} -> {:ok, principal}
      error -> error
    end
  end

  def enable_agent_in_tx(uid) do
    with {:ok, principal} <- Humans.lock_principal_in_tx(uid),
         :ok <- Humans.ensure_principal_type(principal, :agent),
         conversation_ids <- Ankole.Conversations.ids_for_agent_in_tx(principal.uid),
         {:ok, principal} <- Ankole.Ash.update(principal, :enable_in_tx, %{}) do
      {:ok, {principal, conversation_ids}}
    end
  end

  def delete_agent(uid) do
    case Repo.transact_top_level(
           fn -> delete_agent_in_tx(uid) end,
           after_commit: &publish_agent_deletion/1
         ) do
      {:ok, {%Principal{} = principal, _conversation_ids}} -> {:ok, principal}
      error -> error
    end
  end

  def delete_agent_in_tx(uid) do
    with :ok <- Ankole.AuthZ.ensure_can_disable_principal(uid),
         {:ok, principal} <- Humans.lock_principal_in_tx(uid),
         :ok <- Humans.ensure_principal_type(principal, :agent),
         conversation_ids <- Ankole.Conversations.ids_for_agent_in_tx(principal.uid),
         {:ok, principal} <- change_agent_status_in_tx(principal) do
      {:ok, {principal, conversation_ids}}
    end
  end

  defp change_agent_status_in_tx(principal) do
    case principal.status do
      :active ->
        Ankole.Ash.update(principal, :disable_in_tx, %{})

      :disabled ->
        :ok = Ankole.Conversations.delete_for_agent_in_tx(principal.uid)
        :ok = AgentWorkers.mark_deleting_in_tx(principal.uid)
        :ok = Ankole.Signals.Bindings.delete_agent_config_rows_in_tx(principal.uid)
        :ok = Ankole.AgentWorkers.WorkerEnv.delete_agent_rows_in_tx(principal.uid)
        Ankole.Ash.destroy(principal, :delete_in_tx)
    end
  end

  def publish_agent_changes({%{tenant_id: tenant_id}, conversation_ids}) do
    Repo.with_tenant(tenant_id, fn ->
      Enum.each(conversation_ids, &Ankole.Conversations.Events.publish_status/1)
    end)
  end

  def publish_agent_deletion({%{uid: uid}, _conversation_ids} = change) do
    publish_agent_changes(change)
    :ok = AgentWorkers.reconcile(uid)
  end

  def lock_agent_in_tx(uid) do
    Agent
    |> Ash.Query.filter(uid == ^uid)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
  end

  defp insert_agent(principal_uid, attrs) do
    attrs = Map.put(attrs, :uid, principal_uid)

    Ankole.Ash.create(Agent, :create_in_tx, attrs)
  end

  # The Brain owner read exemption chains through this field: an Agent or
  # system Principal as owner would extend private-scope reachability in a
  # way no contract describes, so the owner must be a human. Blank values
  # fall through to the resource's required validation.
  defp validate_agent_owner(attrs) do
    case Map.get(attrs, :owner_principal_uid) do
      owner_uid when is_binary(owner_uid) and owner_uid != "" ->
        case Humans.get_principal(owner_uid) do
          {:ok, %Principal{type: :human}} -> :ok
          {:ok, %Principal{}} -> {:error, :agent_owner_must_be_human}
          {:error, _missing} -> {:error, :agent_owner_not_found}
        end

      _absent_or_blank ->
        :ok
    end
  end

  # The Agent row is locked before the merge, so a token quota or model profile
  # written while this update waits is merged in, not overwritten. The
  # Principal row lock above comes first; the owned-option services take only
  # the Agent row lock, so the two orders cannot deadlock.
  defp update_agent_row(uid, attrs) do
    case lock_agent_in_tx(uid) do
      %Agent{} = agent ->
        with {:ok, attrs} <- keep_owned_agent_options(agent, attrs) do
          Ankole.Ash.update(agent, :profile_in_tx, attrs)
        end

      nil ->
        {:error, :not_agent}
    end
  end

  defp agent_principal_attrs(attrs) do
    attrs
    |> Humans.take_attrs([:uid | Humans.principal_profile_fields()])
    |> Map.merge(%{type: :agent})
  end

  defp keep_owned_agent_options(%Agent{options: stored}, %{options: options} = attrs)
       when is_map(options) do
    incoming = ai_agent_options(options)
    owned = stored |> ai_agent_options() |> Map.take(@owned_ai_agent_keys)

    if Enum.any?(@owned_ai_agent_keys, &Map.has_key?(incoming, &1)) do
      {:error, :ai_agent_options_not_writable}
    else
      ai_agent = Map.merge(incoming, owned)

      options =
        if map_size(ai_agent) == 0,
          do: Map.delete(options, "ai_agent"),
          else: Map.put(options, "ai_agent", ai_agent)

      {:ok, %{attrs | options: options}}
    end
  end

  defp keep_owned_agent_options(_agent, attrs), do: {:ok, attrs}

  # A quota is set through its own route after creation, so its validation has
  # one owner and a new Agent never starts with a shape the quota cannot read.
  defp reject_token_quota_at_creation(%{options: options}) when is_map(options) do
    if Map.has_key?(ai_agent_options(options), "token_quota"),
      do: {:error, :token_quota_not_writable_at_creation},
      else: :ok
  end

  defp reject_token_quota_at_creation(_attrs), do: :ok

  defp ai_agent_options(%{"ai_agent" => ai_agent}) when is_map(ai_agent), do: ai_agent
  defp ai_agent_options(_options), do: %{}
end
