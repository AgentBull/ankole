defmodule Ankole.Principals do
  @moduledoc """
  Principal identity boundary for humans, agents, and external subject bindings.
  """

  alias Ecto.Adapters.SQL
  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Logging
  alias Ankole.PrincipalKey
  alias Ankole.Principals.Agent
  alias Ankole.Principals.ExternalIdentity
  alias Ankole.Principals.HumanUser
  alias Ankole.Principals.LocalCredential
  alias Ankole.Principals.LocalCredentials
  alias Ankole.Principals.MappingRequest
  alias Ankole.Principals.Principal
  alias Ankole.AIAgent.Library
  alias Ankole.AgentHomePaths
  alias Ankole.Repo
  alias Ankole.RuntimeEvents

  @principal_profile_fields [:display_name, :avatar_url]
  @human_profile_fields [:email, :mobile, :job_title]
  @agent_fields [
    :type,
    :role,
    :options,
    :owner_principal_uid,
    :group_memory_disclosure_mode,
    :created_by_principal_uid
  ]
  @provider_format ~r/\A[a-z][a-z0-9_-]*\z/

  @type principal_result :: {:ok, Principal.t()} | {:error, term()}

  @doc """
  Normalizes a public Principal UID.
  """
  @spec normalize_uid(term()) :: {:ok, String.t()} | {:error, :invalid_uid}
  def normalize_uid(uid), do: PrincipalKey.normalize(uid)

  @doc """
  Normalizes an email for identity comparison: trimmed, lowercased, and `nil`
  for a blank or non-binary value. Every email that keys a lookup or a stored
  profile goes through this one form.
  """
  @spec normalize_email(term()) :: String.t() | nil
  def normalize_email(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize_email(_value), do: nil

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
  Lists active Principals ordered by UID.
  """
  @spec list_active_principals() :: [Principal.t()]
  def list_active_principals do
    Principal
    |> where([principal], principal.status == :active)
    |> order_by([principal], asc: principal.uid)
    |> Repo.all()
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
    with {:ok, uid} <- fetch_attr(attrs, :uid),
         {:ok, uid} <- normalize_uid(uid),
         :ok <- AgentHomePaths.validate_agent_uid(uid) do
      attrs = attrs |> Map.delete("uid") |> Map.put(:uid, uid)

      Repo.transact(fn repo ->
        agent_attrs = take_attrs(attrs, @agent_fields)

        with :ok <- validate_agent_owner(repo, agent_attrs),
             {:ok, principal} <- insert_principal(repo, agent_principal_attrs(attrs)),
             {:ok, agent} <- insert_agent(repo, principal.uid, agent_attrs),
             :ok <- Library.seed_agent_library_in_tx(repo, principal.uid),
             :ok <- RuntimeEvents.notify_agent_home_projection(repo, principal.uid) do
          {:ok, %{principal: principal, agent: agent}}
        end
      end)
    end
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
  def list_active_agents, do: list_agents(status: :active)

  @doc """
  Lists agent Principals ordered by creation time.

  `status: :active` keeps only active agents; the default returns disabled
  agents too, so the Console can show and delete them.
  """
  @spec list_agents(keyword()) :: [%{principal: Principal.t(), agent: Agent.t()}]
  def list_agents(opts \\ []) do
    Agent
    |> join(:inner, [agent], principal in assoc(agent, :principal))
    |> where([_agent, principal], principal.type == :agent)
    |> filter_agent_status(Keyword.get(opts, :status))
    |> order_by([agent, _principal], asc: agent.inserted_at)
    |> preload([_agent, principal], principal: principal)
    |> Repo.all()
    |> Enum.map(fn %Agent{principal: principal} = agent ->
      %{principal: principal, agent: agent}
    end)
  end

  defp filter_agent_status(query, :active),
    do: where(query, [_agent, principal], principal.status == :active)

  defp filter_agent_status(query, nil), do: query

  @doc """
  Updates mutable agent attributes.
  """
  @spec update_agent(String.t(), map()) ::
          {:ok, %{principal: Principal.t(), agent: Agent.t()}} | {:error, term()}
  def update_agent(uid, attrs) when is_map(attrs) do
    Repo.transact(fn repo ->
      agent_attrs = take_attrs(attrs, @agent_fields)

      with {:ok, principal} <- fetch_principal_for_update(repo, uid),
           :ok <- ensure_principal_type(principal, :agent),
           :ok <- validate_agent_owner(repo, agent_attrs),
           {:ok, principal} <- update_principal_profile(repo, principal, attrs),
           {:ok, agent} <- update_agent_row(repo, principal.uid, agent_attrs) do
        {:ok, %{principal: principal, agent: agent}}
      end
    end)
  end

  @doc """
  Soft-disables a Principal.
  """
  @spec disable_principal(String.t()) :: principal_result()
  def disable_principal(uid) do
    Repo.transact(fn repo -> disable_in_tx(repo, uid) end)
  end

  # The AuthZ check takes the admin group lock, and the installation-wide lock
  # order puts that lock before the principal row lock. Every path that
  # disables a principal must go through here so the order cannot invert.
  defp disable_in_tx(repo, uid) do
    with :ok <- Ankole.AuthZ.ensure_can_disable_principal(uid, repo),
         {:ok, principal} <- fetch_principal_for_update(repo, uid) do
      principal
      |> Principal.status_changeset(%{status: :disabled})
      |> repo.update()
    end
  end

  @doc """
  Re-enables a disabled agent Principal.
  """
  @spec enable_agent(String.t()) :: principal_result()
  def enable_agent(uid) do
    Repo.transact(fn repo ->
      with {:ok, principal} <- fetch_principal_for_update(repo, uid),
           :ok <- ensure_principal_type(principal, :agent) do
        principal
        |> Principal.status_changeset(%{status: :active})
        |> repo.update()
      end
    end)
  end

  @doc """
  Disables an active agent, or deletes an agent that is already disabled.

  Deletion removes the Principal row; the foreign keys cascade the agent's
  sessions, events, and other owned rows.
  """
  @spec delete_agent(String.t()) :: principal_result()
  def delete_agent(uid) do
    Repo.transact(fn repo ->
      with :ok <- Ankole.AuthZ.ensure_can_disable_principal(uid, repo),
           {:ok, principal} <- fetch_principal_for_update(repo, uid),
           :ok <- ensure_principal_type(principal, :agent) do
        case principal.status do
          :active ->
            # Keep this branch equal to disable_in_tx: the AuthZ gate above
            # runs first for the same lock order, and a side effect added to
            # one disable path belongs in both.
            principal
            |> Principal.status_changeset(%{status: :disabled})
            |> repo.update()

          :disabled ->
            repo.delete(principal)
        end
      end
    end)
  end

  @doc """
  Creates a human Principal with a generated local initial password.

  The email attribute is required because it is the local sign-in key.
  """
  @spec create_local_user(map(), boolean()) ::
          {:ok,
           %{principal: Principal.t(), human_user: HumanUser.t(), initial_password: String.t()}}
          | {:error, term()}
  def create_local_user(attrs, must_change_password)
      when is_map(attrs) and is_boolean(must_change_password) do
    with {:ok, _email} <- required_text(attrs, :email) do
      initial_password = LocalCredential.generate_initial_password()

      Repo.transact(fn repo ->
        with {:ok, principal} <- insert_principal(repo, human_principal_attrs(attrs)),
             {:ok, human_user} <-
               insert_human_user(repo, principal.uid, take_attrs(attrs, @human_profile_fields)),
             {:ok, _credential} <-
               LocalCredentials.put_in_tx(
                 repo,
                 principal.uid,
                 initial_password,
                 must_change_password
               ) do
          {:ok,
           %{principal: principal, human_user: human_user, initial_password: initial_password}}
        end
      end)
    end
  end

  @doc """
  Lists active Principals with their account facts for the operator console.
  """
  @spec list_active_principal_accounts() :: [map()]
  def list_active_principal_accounts do
    principal_account_query()
    |> where([principal: principal], principal.status == :active)
    |> Repo.all()
    |> Enum.map(&finish_principal_account/1)
  end

  @doc """
  Loads one Principal with its account facts for the operator console.
  """
  @spec get_principal_account(String.t()) :: {:ok, map()} | {:error, term()}
  def get_principal_account(uid) do
    with {:ok, normalized_uid} <- normalize_uid(uid) do
      principal_account_query()
      |> where([principal: principal], principal.uid == ^normalized_uid)
      |> Repo.one()
      |> case do
        nil -> {:error, :not_found}
        account -> {:ok, finish_principal_account(account)}
      end
    end
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

  A first-seen subject that carries an email or mobile number already held by
  an existing human Principal binds to that Principal instead of creating a
  new one, so subjects from different providers converge on one human. An
  email or mobile value owned by a different Principal than the one the
  subject resolves to is dropped from the profile update with a warning;
  subjects are never re-pointed automatically.

  An observation keeps the Principal's existing display name; only
  `authoritative_profile: true` (directory sync) may replace it.
  """
  @spec upsert_platform_subject_human(map()) ::
          {:ok,
           %{principal: Principal.t(), human_user: HumanUser.t(), identity: ExternalIdentity.t()}}
          | {:error, term()}
  def upsert_platform_subject_human(attrs) when is_map(attrs) do
    Repo.transact(fn repo ->
      email = normalized_email_attr(attrs)
      mobile = normalized_mobile_attr(attrs)

      with {:ok, provider} <- required_provider(attrs, :provider),
           {:ok, external_id} <- required_text(attrs, :external_id),
           {:ok, metadata} <- metadata_attrs(attrs),
           :ok <- lock_platform_subject(repo, provider, external_id),
           :ok <- maybe_lock_human_contact(repo, "principal_human_email", email),
           :ok <- maybe_lock_human_contact(repo, "principal_human_mobile", mobile),
           existing_identity <- fetch_platform_subject(repo, provider, external_id),
           {:ok, principal_uid} <-
             platform_subject_principal_uid(
               repo,
               existing_identity,
               attrs,
               provider,
               external_id,
               email,
               mobile
             ),
           {:ok, principal} <- upsert_human_principal(repo, principal_uid, attrs),
           profile_attrs <-
             drop_conflicting_contacts(
               repo,
               provider,
               principal.uid,
               take_attrs(attrs, @human_profile_fields)
             ),
           {:ok, human_user} <- upsert_human_user(repo, principal.uid, profile_attrs),
           identity_attrs <-
             platform_subject_identity_attrs(
               principal,
               provider,
               external_id,
               metadata,
               existing_identity
             ),
           {:ok, identity} <- upsert_external_identity(repo, identity_attrs),
           :ok <- delete_pending_mapping_request(repo, provider, external_id) do
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
      |> active_human_result()
    end
  end

  @doc """
  Matches provider-scoped subject candidates to an existing human Principal.

  This is the read side of `upsert_platform_subject_human/1` with the same
  ladder: an existing identity binding for any candidate id wins, then the
  owner of the email, then the owner of the mobile number. It never creates
  or re-points anything; a miss returns `{:error, :not_found}` so the caller
  decides what an unmatched subject means.
  """
  @spec match_platform_subject_human(map()) :: principal_result()
  def match_platform_subject_human(attrs) when is_map(attrs) do
    with {:ok, provider} <- required_provider(attrs, :provider),
         {:ok, external_ids} <- candidate_external_ids(attrs) do
      email = normalized_email_attr(attrs)
      mobile = normalized_mobile_attr(attrs)

      match =
        provider_subject_principal_by_ids(provider, external_ids) ||
          contact_owner_principal(:email, email) ||
          contact_owner_principal(:mobile, mobile)

      active_human_result(match)
    end
  end

  @doc """
  Resolves a provider-scoped platform subject to its Principal uid.

  This does not require the Principal to be active; it is used for cleanup paths
  that need to remove stale external memberships even after a user is disabled.
  """
  @spec resolve_platform_subject_uid(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def resolve_platform_subject_uid(provider, external_id) do
    with {:ok, provider} <- normalize_provider(provider),
         {:ok, external_id} <- normalize_required_text(external_id) do
      case fetch_platform_subject(Repo, provider, external_id) do
        %ExternalIdentity{principal_uid: principal_uid} -> {:ok, principal_uid}
        nil -> {:error, :not_found}
      end
    end
  end

  # Every human and agent Principal owns one canonical Brain Object
  # (people/<uid> or agents/<uid>); the creation transaction keeps that
  # invariant so holder attribution and recall never miss a subject page.
  defp insert_principal(repo, attrs) do
    with {:ok, principal} <-
           %Principal{}
           |> Principal.changeset(attrs)
           |> repo.insert(),
         :ok <- ensure_canonical_brain_object(repo, principal) do
      {:ok, principal}
    end
  end

  defp ensure_canonical_brain_object(repo, %Principal{type: type} = principal)
       when type in [:human, :agent] do
    Ankole.Brain.Objects.ensure_canonical_object_in_tx(
      repo,
      principal.uid,
      type,
      principal.display_name
    )
  end

  defp ensure_canonical_brain_object(_repo, %Principal{}), do: :ok

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

  # The Brain owner read exemption chains through this field: an Agent or
  # system Principal as owner would extend private-scope reachability in a
  # way no contract describes, so the owner must be a human. Blank values
  # fall through to the changeset's required validation.
  defp validate_agent_owner(repo, attrs) do
    case Map.get(attrs, :owner_principal_uid) do
      owner_uid when is_binary(owner_uid) and owner_uid != "" ->
        case repo.one(from p in Principal, where: p.uid == ^owner_uid, select: p.type) do
          :human -> :ok
          nil -> {:error, :agent_owner_not_found}
          _other_type -> {:error, :agent_owner_must_be_human}
        end

      _absent_or_blank ->
        :ok
    end
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
        update_principal_profile(repo, principal, observed_profile_attrs(principal, attrs))

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

  # A message or roster observation must not rename a person who already has a
  # display name; only an authoritative source (directory sync) may replace it.
  # Attrs can carry atom or string keys, so both spellings must be dropped.
  defp observed_profile_attrs(%Principal{display_name: current}, attrs) do
    cond do
      fetch_attr(attrs, :authoritative_profile) == {:ok, true} ->
        attrs

      is_binary(current) and String.trim(current) != "" ->
        attrs |> Map.delete(:display_name) |> Map.delete("display_name")

      true ->
        attrs
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

  defp principal_account_query do
    from principal in Principal,
      as: :principal,
      left_join: human_user in assoc(principal, :human_user),
      left_join: credential in LocalCredential,
      on: credential.principal_uid == principal.uid,
      order_by: [asc: principal.uid],
      select: %{
        principal: principal,
        email: human_user.email,
        has_external_identity:
          exists(
            from identity in ExternalIdentity,
              where: identity.principal_uid == parent_as(:principal).uid,
              select: 1
          ),
        local_credential_must_change: credential.must_change_password
      }
  end

  defp finish_principal_account(account) do
    {must_change, account} = Map.pop(account, :local_credential_must_change)

    local_credential_status =
      case must_change do
        nil -> nil
        true -> :must_change
        false -> :active
      end

    Map.put(account, :local_credential_status, local_credential_status)
  end

  defp upsert_external_identity(repo, attrs) do
    changeset = ExternalIdentity.changeset(%ExternalIdentity{}, attrs)

    with {:ok, _normalized} <- Changeset.apply_action(changeset, :validate) do
      repo.insert(changeset,
        conflict_target: [:provider, :external_id],
        on_conflict: {:replace, [:principal_uid, :metadata, :updated_at]},
        returning: true
      )
    end
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
        where: identity.provider == ^provider and identity.external_id == ^external_id
    )
  end

  @doc false
  @spec lock_platform_subject(module(), String.t(), String.t()) :: :ok | {:error, term()}
  def lock_platform_subject(repo, provider, external_id)
      when is_binary(provider) and is_binary(external_id) do
    advisory_xact_lock(
      repo,
      "principal_external_identity:platform_subject:#{provider}:#{external_id}"
    )
  end

  @doc false
  @spec delete_pending_mapping_request(module(), String.t(), String.t()) :: :ok
  def delete_pending_mapping_request(repo, provider, external_id)
      when is_binary(provider) and is_binary(external_id) do
    repo.delete_all(
      from request in MappingRequest,
        where: request.provider == ^provider and request.external_id == ^external_id
    )

    :ok
  end

  # The contact join runs on subject creation, so concurrent first-sightings of
  # the same email or mobile must serialize or both would create a principal.
  defp maybe_lock_human_contact(_repo, _prefix, nil), do: :ok

  defp maybe_lock_human_contact(repo, prefix, value) do
    advisory_xact_lock(repo, "#{prefix}:#{value}")
  end

  defp advisory_xact_lock(repo, lock_key) do
    case SQL.query(repo, "SELECT pg_advisory_xact_lock(hashtext($1::text))", [lock_key]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp platform_subject_principal_uid(
         _repo,
         %ExternalIdentity{principal_uid: principal_uid},
         _attrs,
         _provider,
         _external_id,
         _email,
         _mobile
       ) do
    {:ok, principal_uid}
  end

  defp platform_subject_principal_uid(repo, nil, attrs, provider, external_id, email, mobile) do
    case human_contact_owner_uid(repo, :email, email) ||
           human_contact_owner_uid(repo, :mobile, mobile) do
      nil ->
        case fetch_attr(attrs, :uid) do
          {:ok, uid} -> normalize_uid(uid)
          # The derived uid carries the provider scope so equal external ids
          # from different providers never collide on one Principal.
          :error -> normalize_uid(provider <> ":" <> external_id)
        end

      owner_uid ->
        Logging.info(
          "principals.platform_subject.contact_join",
          "Platform subject joined an existing principal by email or mobile",
          %{principal_uid: owner_uid, external_id: external_id}
        )

        {:ok, owner_uid}
    end
  end

  defp human_contact_owner_uid(_repo, _field, nil), do: nil

  defp human_contact_owner_uid(repo, field, value) do
    contact_owner_uid(repo, field, value)
  end

  defp normalized_email_attr(attrs) do
    case fetch_attr(attrs, :email) do
      {:ok, value} -> normalize_email(value)
      :error -> nil
    end
  end

  defp normalized_mobile_attr(attrs) do
    case fetch_attr(attrs, :mobile) do
      {:ok, value} -> normalized_contact_mobile(value)
      :error -> nil
    end
  end

  defp candidate_external_ids(attrs) do
    listed =
      case fetch_attr(attrs, :external_ids) do
        {:ok, ids} when is_list(ids) -> ids
        _other -> []
      end

    single =
      case fetch_attr(attrs, :external_id) do
        {:ok, id} -> [id]
        :error -> []
      end

    normalized =
      (single ++ listed)
      |> Enum.flat_map(fn value ->
        case normalize_required_text(value) do
          {:ok, id} -> [id]
          {:error, _reason} -> []
        end
      end)
      |> Enum.uniq()

    case normalized do
      [] -> {:error, {:missing, :external_id}}
      ids -> {:ok, ids}
    end
  end

  defp provider_subject_principal_by_ids(provider, external_ids) do
    Enum.find_value(external_ids, fn external_id ->
      provider_subject_principal(provider, external_id)
    end)
  end

  defp contact_owner_principal(_field, nil), do: nil

  defp contact_owner_principal(field, value) do
    Repo.one(
      from human_user in HumanUser,
        join: principal in Principal,
        on: principal.uid == human_user.principal_uid,
        where: field(human_user, ^field) == ^value,
        select: %{principal: principal}
    )
  end

  # Unique-owned contact fields are dropped rather than failed on: a unique
  # violation would abort the whole transaction, and the conflicting field is
  # the other provider's problem to reconcile, not this subject's.
  defp drop_conflicting_contacts(repo, provider, principal_uid, profile_attrs) do
    profile_attrs
    |> drop_conflicting_contact(
      repo,
      provider,
      principal_uid,
      :email,
      &normalize_email/1
    )
    |> drop_conflicting_contact(
      repo,
      provider,
      principal_uid,
      :mobile,
      &normalized_contact_mobile/1
    )
  end

  defp drop_conflicting_contact(profile_attrs, repo, provider, principal_uid, field, normalize) do
    with {:ok, value} <- Map.fetch(profile_attrs, field),
         normalized when is_binary(normalized) <- normalize.(value),
         owner_uid when is_binary(owner_uid) <- contact_owner_uid(repo, field, normalized) do
      if owner_uid == principal_uid do
        profile_attrs
      else
        Logging.warning(
          "principals.platform_subject.contact_conflict",
          "Platform subject contact field dropped: value belongs to another principal",
          %{
            field: field,
            provider: provider,
            principal_uid: principal_uid,
            owner_principal_uid: owner_uid
          }
        )

        Map.delete(profile_attrs, field)
      end
    else
      _absent_or_unowned -> profile_attrs
    end
  end

  defp contact_owner_uid(repo, field, value) do
    repo.one(
      from human_user in HumanUser,
        where: field(human_user, ^field) == ^value,
        select: human_user.principal_uid
    )
  end

  # Mirrors the HumanUser changeset normalization; a value the kernel cannot
  # normalize is left for the changeset to reject as today.
  defp normalized_contact_mobile(value) when is_binary(value) do
    case NativeKernel.phone_normalize_e164(value) do
      normalized when is_binary(normalized) -> normalized
      {:error, _reason} -> nil
    end
  end

  defp normalized_contact_mobile(_value), do: nil

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
      provider: provider,
      external_id: external_id,
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
        where: identity.provider == ^provider and identity.external_id == ^external_id,
        select: %{identity: identity, principal: principal}
    )
  end

  defp active_human_result(nil), do: {:error, :not_found}

  defp active_human_result(%{principal: %Principal{status: :disabled}}) do
    {:error, :principal_disabled}
  end

  defp active_human_result(%{principal: %Principal{type: :agent}}) do
    {:error, :not_human}
  end

  defp active_human_result(%{principal: %Principal{type: :human, status: :active} = principal}) do
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
