defmodule Ankole.Principals do
  @moduledoc """
  Principal identity boundary for humans, agents, and external subject bindings.
  """

  alias Ecto.Adapters.SQL
  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ankole.Principals.Agent
  alias Ankole.Principals.ExternalIdentity
  alias Ankole.Principals.HumanUser
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  @principal_profile_fields [:display_name, :avatar_url]
  @human_profile_fields [:email, :mobile, :job_title]
  @agent_fields [:type, :role, :options, :created_by_principal_uid]
  @provider_format ~r/\A[a-z][a-z0-9_-]*\z/

  @type principal_result :: {:ok, Principal.t()} | {:error, term()}

  @doc """
  Normalizes a public Principal UID.
  """
  @spec normalize_uid(term()) :: {:ok, String.t()} | {:error, :invalid_uid}
  def normalize_uid(uid) when is_binary(uid) do
    case uid |> String.trim() |> String.downcase() do
      "" -> {:error, :invalid_uid}
      normalized -> {:ok, normalized}
    end
  end

  def normalize_uid(_uid), do: {:error, :invalid_uid}

  @doc """
  Looks up a Principal by UID.
  """
  @spec get_principal(String.t()) :: principal_result()
  def get_principal(uid) do
    with {:ok, normalized_uid} <- normalize_uid(uid) do
      case Repo.get(Principal, normalized_uid) do
        %Principal{} = principal -> {:ok, principal}
        nil -> {:error, :not_found}
      end
    end
  end

  @doc """
  Creates a human Principal and its human profile row in one transaction.
  """
  @spec create_human(map()) ::
          {:ok, %{principal: Principal.t(), human_user: HumanUser.t()}} | {:error, term()}
  def create_human(attrs) when is_map(attrs) do
    Repo.transact(fn repo ->
      with {:ok, principal} <- insert_principal(repo, human_principal_attrs(attrs)),
           {:ok, human_user} <-
             insert_human_user(repo, principal.uid, take_attrs(attrs, @human_profile_fields)) do
        {:ok, %{principal: principal, human_user: human_user}}
      end
    end)
  end

  @doc """
  Updates mutable human profile fields.
  """
  @spec update_human(String.t(), map()) ::
          {:ok, %{principal: Principal.t(), human_user: HumanUser.t()}} | {:error, term()}
  def update_human(uid, attrs) when is_map(attrs) do
    Repo.transact(fn repo ->
      with {:ok, principal} <- fetch_principal_for_update(repo, uid),
           :ok <- ensure_principal_type(principal, :human),
           {:ok, principal} <- update_principal_profile(repo, principal, attrs),
           {:ok, human_user} <-
             upsert_human_user(repo, principal.uid, take_attrs(attrs, @human_profile_fields)) do
        {:ok, %{principal: principal, human_user: human_user}}
      end
    end)
  end

  @doc """
  Creates an agent Principal and its agent subtype row in one transaction.
  """
  @spec create_agent(map()) ::
          {:ok, %{principal: Principal.t(), agent: Agent.t()}} | {:error, term()}
  def create_agent(attrs) when is_map(attrs) do
    Repo.transact(fn repo ->
      with {:ok, principal} <- insert_principal(repo, agent_principal_attrs(attrs)),
           {:ok, agent} <- insert_agent(repo, principal.uid, take_attrs(attrs, @agent_fields)) do
        {:ok, %{principal: principal, agent: agent}}
      end
    end)
  end

  @doc """
  Loads an agent and its backing Principal.
  """
  @spec get_agent(String.t()) ::
          {:ok, %{principal: Principal.t(), agent: Agent.t()}} | {:error, term()}
  def get_agent(uid) do
    with {:ok, normalized_uid} <- normalize_uid(uid) do
      case Repo.one(agent_with_principal_query(normalized_uid)) do
        %Agent{principal: %Principal{} = principal} = agent ->
          {:ok, %{principal: principal, agent: agent}}

        nil ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  Lists active agent Principals ordered by creation time.
  """
  @spec list_active_agents() :: [%{principal: Principal.t(), agent: Agent.t()}]
  def list_active_agents do
    Agent
    |> join(:inner, [agent], principal in assoc(agent, :principal))
    |> where([_agent, principal], principal.status == :active and principal.type == :agent)
    |> order_by([agent, _principal], asc: agent.inserted_at)
    |> preload([_agent, principal], principal: principal)
    |> Repo.all()
    |> Enum.map(fn %Agent{principal: principal} = agent ->
      %{principal: principal, agent: agent}
    end)
  end

  @doc """
  Updates mutable agent attributes.
  """
  @spec update_agent(String.t(), map()) ::
          {:ok, %{principal: Principal.t(), agent: Agent.t()}} | {:error, term()}
  def update_agent(uid, attrs) when is_map(attrs) do
    Repo.transact(fn repo ->
      with {:ok, principal} <- fetch_principal_for_update(repo, uid),
           :ok <- ensure_principal_type(principal, :agent),
           {:ok, principal} <- update_principal_profile(repo, principal, attrs),
           {:ok, agent} <- update_agent_row(repo, principal.uid, take_attrs(attrs, @agent_fields)) do
        {:ok, %{principal: principal, agent: agent}}
      end
    end)
  end

  @doc """
  Updates Principal lifecycle status.
  """
  @spec update_principal_status(String.t(), :active | :disabled) :: principal_result()
  def update_principal_status(uid, status) when status in [:active, :disabled] do
    Repo.transact(fn repo ->
      with {:ok, principal} <- fetch_principal_for_update(repo, uid) do
        principal
        |> Principal.status_changeset(%{status: status})
        |> repo.update()
      end
    end)
  end

  def update_principal_status(_uid, _status), do: {:error, :invalid_status}

  @doc """
  Soft-disables a Principal.
  """
  @spec disable_principal(String.t()) :: principal_result()
  def disable_principal(uid) do
    Repo.transact(fn repo ->
      with :ok <- Ankole.AuthZ.ensure_can_disable_principal(uid, repo),
           {:ok, principal} <- fetch_principal_for_update(repo, uid) do
        principal
        |> Principal.status_changeset(%{status: :disabled})
        |> repo.update()
      end
    end)
  end

  @doc """
  Inserts an external identity binding.
  """
  @spec create_external_identity(map()) :: {:ok, ExternalIdentity.t()} | {:error, term()}
  def create_external_identity(attrs) when is_map(attrs) do
    %ExternalIdentity{}
    |> ExternalIdentity.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Inserts or updates an external identity by its natural provider/channel key.
  """
  @spec upsert_external_identity(map()) :: {:ok, ExternalIdentity.t()} | {:error, term()}
  def upsert_external_identity(attrs) when is_map(attrs) do
    Repo.transact(fn repo -> upsert_external_identity(repo, attrs) end)
  end

  @doc """
  Upserts a human Principal from a provider-scoped subject.
  """
  @spec upsert_platform_subject_human(map()) ::
          {:ok,
           %{principal: Principal.t(), human_user: HumanUser.t(), identity: ExternalIdentity.t()}}
          | {:error, term()}
  def upsert_platform_subject_human(attrs) when is_map(attrs) do
    Repo.transact(fn repo ->
      with {:ok, provider} <- required_provider(attrs, :provider),
           {:ok, external_id} <- required_text(attrs, :external_id),
           {:ok, metadata} <- metadata_attrs(attrs),
           :ok <- lock_platform_subject(repo, provider, external_id),
           existing_identity <- fetch_platform_subject(repo, provider, external_id),
           {:ok, principal_uid} <-
             platform_subject_principal_uid(existing_identity, attrs, external_id),
           {:ok, principal} <- upsert_human_principal(repo, principal_uid, attrs),
           {:ok, human_user} <-
             upsert_human_user(repo, principal.uid, take_attrs(attrs, @human_profile_fields)),
           identity_attrs <-
             platform_subject_identity_attrs(
               principal,
               provider,
               external_id,
               metadata,
               existing_identity
             ),
           {:ok, identity} <- upsert_external_identity(repo, identity_attrs) do
        {:ok, %{principal: principal, human_user: human_user, identity: identity}}
      end
    end)
  end

  @doc """
  Resolves a provider-scoped subject to an active human Principal.
  """
  @spec resolve_platform_subject(String.t(), String.t()) :: principal_result()
  def resolve_platform_subject(provider, external_id) do
    with {:ok, provider} <- normalize_provider(provider),
         {:ok, external_id} <- normalize_required_text(external_id) do
      provider_subject_principal(provider, external_id)
      |> active_human_result(false)
    end
  end

  @doc """
  Resolves a verified channel actor to an active human Principal.
  """
  @spec resolve_channel_actor(String.t(), String.t(), String.t()) :: principal_result()
  def resolve_channel_actor(adapter, channel_id, external_id) do
    with {:ok, adapter} <- normalize_required_text(adapter),
         {:ok, channel_id} <- normalize_required_text(channel_id),
         {:ok, external_id} <- normalize_required_text(external_id) do
      channel_actor_principal(adapter, channel_id, external_id)
      |> active_human_result(true)
    end
  end

  @doc """
  Returns true when a channel actor binding has been verified.
  """
  @spec channel_identity_verified?(ExternalIdentity.t() | nil) :: boolean()
  def channel_identity_verified?(%ExternalIdentity{verified_at: %DateTime{}}), do: true
  def channel_identity_verified?(_identity), do: false

  defp insert_principal(repo, attrs) do
    %Principal{}
    |> Principal.changeset(attrs)
    |> repo.insert()
  end

  defp insert_human_user(repo, principal_uid, attrs) do
    attrs = Map.put(attrs, :principal_uid, principal_uid)

    %HumanUser{}
    |> HumanUser.changeset(attrs)
    |> repo.insert()
  end

  defp insert_agent(repo, principal_uid, attrs) do
    attrs = Map.put(attrs, :uid, principal_uid)

    %Agent{}
    |> Agent.changeset(attrs)
    |> repo.insert()
  end

  defp update_agent_row(repo, uid, attrs) do
    case repo.get(Agent, uid) do
      %Agent{} = agent ->
        agent
        |> Agent.changeset(attrs)
        |> repo.update()

      nil ->
        {:error, :not_agent}
    end
  end

  defp update_principal_profile(repo, principal, attrs) do
    profile_attrs = take_attrs(attrs, @principal_profile_fields)

    case map_size(profile_attrs) do
      0 ->
        {:ok, principal}

      _count ->
        principal
        |> Principal.profile_changeset(profile_attrs)
        |> repo.update()
    end
  end

  defp upsert_human_principal(repo, uid, attrs) do
    case fetch_principal_for_update(repo, uid) do
      {:ok, %Principal{type: :human} = principal} ->
        update_principal_profile(repo, principal, attrs)

      {:ok, %Principal{type: :agent}} ->
        {:error, :not_human}

      {:error, :not_found} ->
        insert_principal(
          repo,
          human_principal_attrs(Map.put(take_attrs(attrs, @principal_profile_fields), :uid, uid))
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upsert_human_user(repo, principal_uid, attrs) do
    case repo.get(HumanUser, principal_uid) do
      %HumanUser{} = human_user ->
        human_user
        |> HumanUser.changeset(attrs)
        |> repo.update()

      nil ->
        insert_human_user(repo, principal_uid, attrs)
    end
  end

  defp upsert_external_identity(repo, attrs) do
    changeset = ExternalIdentity.changeset(%ExternalIdentity{}, attrs)

    with {:ok, normalized} <- Changeset.apply_action(changeset, :validate) do
      repo.insert(changeset,
        conflict_target: external_identity_conflict_target(normalized),
        on_conflict: {:replace, external_identity_conflict_fields()},
        returning: true
      )
    end
  end

  defp external_identity_conflict_target(%ExternalIdentity{kind: :channel_actor}) do
    {:unsafe_fragment, "(adapter, channel_id, external_id) WHERE kind = 'channel_actor'"}
  end

  defp external_identity_conflict_target(%ExternalIdentity{}) do
    {:unsafe_fragment, "(kind, provider, external_id) WHERE kind <> 'channel_actor'"}
  end

  defp external_identity_conflict_fields do
    [
      :principal_uid,
      :provider,
      :adapter,
      :channel_id,
      :external_id,
      :verified_at,
      :metadata,
      :updated_at
    ]
  end

  defp fetch_principal_for_update(repo, uid) do
    with {:ok, normalized_uid} <- normalize_uid(uid) do
      case repo.one(
             from principal in Principal,
               where: principal.uid == ^normalized_uid,
               lock: "FOR UPDATE"
           ) do
        %Principal{} = principal -> {:ok, principal}
        nil -> {:error, :not_found}
      end
    end
  end

  defp ensure_principal_type(%Principal{type: type}, type), do: :ok
  defp ensure_principal_type(%Principal{type: :human}, :agent), do: {:error, :not_agent}
  defp ensure_principal_type(%Principal{type: :agent}, :human), do: {:error, :not_human}

  defp human_principal_attrs(attrs) do
    attrs
    |> take_attrs([:uid | @principal_profile_fields])
    |> Map.merge(%{type: :human, status: :active})
  end

  defp agent_principal_attrs(attrs) do
    attrs
    |> take_attrs([:uid | @principal_profile_fields])
    |> Map.merge(%{type: :agent, status: :active})
  end

  defp agent_with_principal_query(uid) do
    Agent
    |> where([agent], agent.uid == ^uid)
    |> join(:inner, [agent], principal in assoc(agent, :principal))
    |> preload([_agent, principal], principal: principal)
  end

  defp fetch_platform_subject(repo, provider, external_id) do
    repo.one(
      from identity in ExternalIdentity,
        where:
          identity.kind == :platform_subject and identity.provider == ^provider and
            identity.external_id == ^external_id
    )
  end

  defp lock_platform_subject(repo, provider, external_id) do
    lock_key = "principal_external_identity:platform_subject:#{provider}:#{external_id}"

    case SQL.query(repo, "SELECT pg_advisory_xact_lock(hashtext($1::text))", [lock_key]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp platform_subject_principal_uid(
         %ExternalIdentity{principal_uid: principal_uid},
         _attrs,
         _external_id
       ) do
    {:ok, principal_uid}
  end

  defp platform_subject_principal_uid(nil, attrs, external_id) do
    case fetch_attr(attrs, :uid) do
      {:ok, uid} -> normalize_uid(uid)
      :error -> normalize_uid(external_id)
    end
  end

  defp platform_subject_identity_attrs(
         principal,
         provider,
         external_id,
         metadata,
         existing_identity
       ) do
    existing_metadata =
      case existing_identity do
        %ExternalIdentity{metadata: metadata} when is_map(metadata) -> metadata
        _identity -> %{}
      end

    %{
      principal_uid: principal.uid,
      kind: :platform_subject,
      provider: provider,
      external_id: external_id,
      verified_at: DateTime.utc_now(:microsecond),
      metadata:
        existing_metadata
        |> Map.merge(metadata)
        |> Map.put("provider", provider)
        |> Map.put("external_id", external_id)
    }
  end

  defp provider_subject_principal(provider, external_id) do
    Repo.one(
      from identity in ExternalIdentity,
        join: principal in assoc(identity, :principal),
        where:
          identity.kind == :platform_subject and identity.provider == ^provider and
            identity.external_id == ^external_id,
        select: %{identity: identity, principal: principal}
    )
  end

  defp channel_actor_principal(adapter, channel_id, external_id) do
    Repo.one(
      from identity in ExternalIdentity,
        join: principal in assoc(identity, :principal),
        where:
          identity.kind == :channel_actor and identity.adapter == ^adapter and
            identity.channel_id == ^channel_id and identity.external_id == ^external_id,
        select: %{identity: identity, principal: principal}
    )
  end

  defp active_human_result(nil, _require_verified?), do: {:error, :not_found}

  defp active_human_result(%{principal: %Principal{status: :disabled}}, _require_verified?) do
    {:error, :principal_disabled}
  end

  defp active_human_result(%{principal: %Principal{type: :agent}}, _require_verified?) do
    {:error, :not_human}
  end

  defp active_human_result(%{identity: identity, principal: principal}, true) do
    case channel_identity_verified?(identity) do
      true -> {:ok, principal}
      false -> {:error, :identity_unverified}
    end
  end

  defp active_human_result(
         %{principal: %Principal{type: :human, status: :active} = principal},
         false
       ) do
    {:ok, principal}
  end

  defp required_provider(attrs, key) do
    with {:ok, value} <- required_text(attrs, key) do
      normalize_provider(value)
    end
  end

  defp required_text(attrs, key) do
    case fetch_attr(attrs, key) do
      {:ok, value} -> normalize_required_text(value)
      :error -> {:error, {:missing, key}}
    end
  end

  defp normalize_provider(value) do
    with {:ok, text} <- normalize_required_text(value) do
      case Regex.match?(@provider_format, text) do
        true -> {:ok, text}
        false -> {:error, :invalid_provider}
      end
    end
  end

  defp normalize_required_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :invalid_text}
      trimmed -> {:ok, trimmed}
    end
  end

  defp normalize_required_text(_value), do: {:error, :invalid_text}

  defp metadata_attrs(attrs) do
    case fetch_attr(attrs, :metadata) do
      {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
      {:ok, _metadata} -> {:error, :invalid_metadata}
      :error -> {:ok, %{}}
    end
  end

  defp take_attrs(attrs, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case fetch_attr(attrs, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end
end
