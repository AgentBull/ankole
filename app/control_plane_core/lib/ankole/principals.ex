defmodule Ankole.Principals do
  @moduledoc """
  Principal identity boundary for humans, agents, and external subject bindings.

  This module is the Principals domain. A write that locks a Principal or
  touches several rows is a generic action of `Ankole.Principals.Principal`
  that owns its transaction. The `_in_tx` functions give the same steps to
  another domain's action.
  """
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  require Ash.Query

  alias Ankole.IdentityProviders.LocalPassword
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Logging
  alias Ankole.PrincipalKey
  alias Ankole.Principals.AccessEvent
  alias Ankole.Principals.AccessRestriction
  alias Ankole.Principals.Agent
  alias Ankole.Principals.ExternalIdentity
  alias Ankole.Principals.HumanUser
  alias Ankole.Principals.LocalCredential
  alias Ankole.Principals.MappingRequest
  alias Ankole.Principals.Principal
  alias Ankole.AIAgent.Library
  alias Ankole.Repo
  alias Ankole.AgentWorkers

  resources do
    resource Principal do
      define(:get_principal_record, action: :read, get_by: [:uid], not_found_error?: false)
      define(:list_principals, action: :read)

      define(:get_principal_across_tenants,
        action: :read_across_tenants,
        get_by: [:uid],
        not_found_error?: false
      )
    end

    resource Agent do
      define(:get_agent_record, action: :read, get_by: [:uid], not_found_error?: false)
      define(:options_agent, action: :options_in_tx)
    end

    resource HumanUser do
      define(:get_human_user, action: :read, get_by: [:principal_uid], not_found_error?: false)
      define(:list_human_users, action: :read)
    end

    resource ExternalIdentity do
      define(:get_external_identity, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_external_identities, action: :read)
    end

    resource LocalCredential do
      define(:get_local_credential,
        action: :read,
        get_by: [:principal_uid],
        not_found_error?: false
      )
    end

    resource AccessRestriction do
      define(:list_access_restrictions, action: :read)
    end

    resource AccessEvent do
      define(:list_access_events, action: :read)
    end

    resource MappingRequest do
      define(:get_mapping_request, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_mapping_requests, action: :read)
    end
  end

  json_api do
    authorize?(false)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      base_route "/agents", Agent do
        index(:console_list, name: "list_agents", derive_sort?: false)
        get(:read, route: "/:uid", name: "get_agent")
        route(:post, "/", :console_create, name: "create_agent")
        route(:patch, "/:uid", :console_update, name: "update_agent")
        route(:delete, "/:uid", :console_delete, name: "delete_agent")
        route(:post, "/:uid/enable", :console_enable, name: "enable_agent")
      end
    end
  end

  @principal_profile_fields [:display_name, :avatar_url]
  @human_profile_fields [:email, :mobile, :job_title]
  @agent_fields [
    :handle,
    :type,
    :role,
    :options,
    :owner_principal_uid,
    :group_memory_disclosure_mode,
    :created_by
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
      case Principal |> Ash.Query.filter(uid == ^normalized_uid) |> Ankole.Ash.read_one!() do
        %Principal{} = principal -> {:ok, principal}
        nil -> {:error, :not_found}
      end
    end
  end

  @doc "Resolves a globally unique identity to its tenant at an authenticated entry point."
  @spec resolve_tenant(String.t()) :: {:ok, String.t()} | {:error, term()}
  def resolve_tenant(uid) do
    with {:ok, uid} <- normalize_uid(uid) do
      case Repo.across_tenants(fn -> get_principal_across_tenants(uid) end) do
        {:ok, %Principal{tenant_id: tenant_id}} -> {:ok, tenant_id}
        {:ok, nil} -> {:error, :not_found}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Lists active Principals ordered by UID.
  """
  @spec list_active_principals() :: [Principal.t()]
  def list_active_principals do
    Principal
    |> Ash.Query.filter(status == :active)
    |> Ash.Query.sort(uid: :asc)
    |> Ankole.Ash.read!()
  end

  @doc "Gives the system Principal of the selected tenant."
  @spec system_principal() :: principal_result()
  def system_principal do
    case Principal |> Ash.Query.filter(type == :system) |> Ankole.Ash.read_one!() do
      %Principal{} = principal -> {:ok, principal}
      nil -> {:error, :system_principal_missing}
    end
  end

  @doc false
  def ensure_system_principal_in_tx(repo) do
    case system_principal() do
      {:ok, principal} ->
        {:ok, principal}

      {:error, :system_principal_missing} ->
        insert_principal(repo, %{
          uid: NativeKernel.gen_uuid_v7(),
          type: :system,
          display_name: "System"
        })
    end
  end

  @doc """
  Creates a human Principal and its human profile row in one transaction.
  """
  @spec create_human(map()) ::
          {:ok, %{principal: Principal.t(), human_user: HumanUser.t()}} | {:error, term()}
  def create_human(attrs) when is_map(attrs),
    do: Ankole.Ash.run_action(Principal, :create_human, %{attrs: attrs})

  @doc false
  def create_human_in_tx(repo, attrs) do
    with {:ok, principal} <- insert_principal(repo, human_principal_attrs(attrs)),
         {:ok, human_user} <-
           insert_human_user(repo, principal.uid, take_attrs(attrs, @human_profile_fields)) do
      {:ok, %{principal: principal, human_user: human_user}}
    end
  end

  @doc """
  Updates mutable human profile fields.
  """
  @spec update_human(String.t(), map()) ::
          {:ok, %{principal: Principal.t(), human_user: HumanUser.t()}} | {:error, term()}
  def update_human(uid, attrs) when is_map(attrs),
    do: Ankole.Ash.run_action(Principal, :update_human, %{uid: uid, attrs: attrs})

  @doc false
  def update_human_in_tx(repo, uid, attrs) do
    with {:ok, principal} <- lock_principal_in_tx(repo, uid),
         :ok <- ensure_principal_type(principal, :human),
         {:ok, principal} <- update_principal_profile(repo, principal, attrs),
         {:ok, human_user} <-
           upsert_human_user(repo, principal.uid, take_attrs(attrs, @human_profile_fields)) do
      {:ok, %{principal: principal, human_user: human_user}}
    end
  end

  @doc """
  Creates an agent Principal, its agent subtype, and its Worker startup
  request in one transaction. Reconciliation starts the Worker after commit.
  """
  @spec create_agent(map()) ::
          {:ok, %{principal: Principal.t(), agent: Agent.t()}} | {:error, term()}
  def create_agent(attrs) when is_map(attrs) do
    with {:ok, _handle} <- required_text(attrs, :handle) do
      attrs = attrs |> Map.delete("uid") |> Map.put(:uid, NativeKernel.gen_uuid_v7())
      Ankole.Ash.run_action(Principal, :create_agent, %{attrs: attrs})
    end
  end

  @doc false
  def create_agent_in_tx(repo, attrs) do
    agent_attrs = take_attrs(attrs, @agent_fields)
    provider_id = Ankole.Attrs.get(attrs, :worker_provider_id)

    with {:ok, provider_id} <- Ankole.AgentWorkers.Providers.select_in_tx(repo, provider_id),
         :ok <- validate_agent_owner(agent_attrs),
         :ok <- reject_token_quota_at_creation(agent_attrs),
         {:ok, principal} <- insert_principal(repo, agent_principal_attrs(attrs)),
         {:ok, agent} <- insert_agent(repo, principal.uid, agent_attrs),
         :ok <- Library.seed_agent_library_in_tx(repo, principal.uid),
         :ok <- AgentWorkers.insert_in_tx(repo, principal.uid, provider_id) do
      {:ok, %{principal: principal, agent: agent}}
    end
  end

  @doc """
  Loads an agent and its backing Principal.
  """
  @spec get_agent(String.t()) ::
          {:ok, %{principal: Principal.t(), agent: Agent.t()}} | {:error, term()}
  def get_agent(uid) do
    with {:ok, normalized_uid} <- normalize_uid(uid) do
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

  @doc """
  Updates mutable agent attributes.
  """
  @spec update_agent(String.t(), map()) ::
          {:ok, %{principal: Principal.t(), agent: Agent.t()}} | {:error, term()}
  def update_agent(uid, attrs) when is_map(attrs),
    do: Ankole.Ash.run_action(Principal, :update_agent, %{uid: uid, attrs: attrs})

  @doc false
  def update_agent_in_tx(repo, uid, attrs) do
    agent_attrs = take_attrs(attrs, @agent_fields)

    with {:ok, principal} <- lock_principal_in_tx(repo, uid),
         :ok <- ensure_principal_type(principal, :agent),
         :ok <- validate_agent_owner(agent_attrs),
         {:ok, principal} <- update_principal_profile(repo, principal, attrs),
         {:ok, agent} <- update_agent_row(principal.uid, agent_attrs) do
      {:ok, %{principal: principal, agent: agent}}
    end
  end

  # The AuthZ check takes the admin group lock, and the installation-wide lock
  # order puts that lock before the principal row lock. Every path that
  # disables a principal must go through here so the order cannot invert.

  @doc """
  Re-enables a disabled agent Principal.
  """
  @spec enable_agent(String.t()) :: principal_result()
  def enable_agent(uid) do
    case Ankole.Ash.run_action(Principal, :enable_agent, %{uid: uid}) do
      {:ok, {%Principal{} = principal, _conversation_ids}} -> {:ok, principal}
      error -> error
    end
  end

  @doc false
  def enable_agent_in_tx(repo, uid) do
    with {:ok, principal} <- lock_principal_in_tx(repo, uid),
         :ok <- ensure_principal_type(principal, :agent),
         conversation_ids <- Ankole.Conversations.ids_for_agent_in_tx(repo, principal.uid),
         {:ok, principal} <- Ankole.Ash.update(principal, :enable_in_tx, %{}) do
      {:ok, {principal, conversation_ids}}
    end
  end

  @doc """
  Disables an active agent, or deletes an agent that is already disabled.

  Deletion removes the Principal row; the foreign keys cascade the agent's
  sessions, events, and other owned rows.
  """
  @spec delete_agent(String.t()) :: principal_result()
  def delete_agent(uid) do
    case Ankole.Ash.run_action(Principal, :delete_agent, %{uid: uid}) do
      {:ok, {%Principal{} = principal, _conversation_ids}} -> {:ok, principal}
      error -> error
    end
  end

  @doc false
  def delete_agent_in_tx(repo, uid) do
    with :ok <- Ankole.AuthZ.ensure_can_disable_principal(uid, repo),
         {:ok, principal} <- lock_principal_in_tx(repo, uid),
         :ok <- ensure_principal_type(principal, :agent),
         conversation_ids <- Ankole.Conversations.ids_for_agent_in_tx(repo, principal.uid),
         {:ok, principal} <- change_agent_status_in_tx(repo, principal) do
      {:ok, {principal, conversation_ids}}
    end
  end

  defp change_agent_status_in_tx(repo, principal) do
    case principal.status do
      :active ->
        Ankole.Ash.update(principal, :disable_in_tx, %{})

      :disabled ->
        :ok = Ankole.Conversations.delete_for_agent_in_tx(repo, principal.uid)

        :ok = AgentWorkers.mark_deleting_in_tx(repo, principal.uid)

        :ok =
          Ankole.Signals.Bindings.delete_agent_config_rows_in_tx(repo, principal.uid)

        :ok =
          Ankole.AgentWorkers.WorkerEnv.delete_agent_rows_in_tx(
            repo,
            principal.uid
          )

        Ankole.Ash.destroy(principal, :delete_in_tx)
    end
  end

  @doc false
  def publish_agent_changes({%Principal{} = principal, conversation_ids}) do
    Repo.with_tenant(principal.tenant_id, fn ->
      Enum.each(conversation_ids, &Ankole.Conversations.Events.publish_status/1)
    end)
  end

  @doc false
  def publish_agent_deletion({%Principal{} = principal, _conversation_ids} = change) do
    publish_agent_changes(change)
    :ok = AgentWorkers.reconcile(principal.uid)
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
    initial_password = LocalCredential.generate_initial_password()

    with {:ok, _email} <- required_text(attrs, :email),
         {:ok, password_hash} <- LocalPassword.hash_password(initial_password),
         {:ok, created} <-
           Ankole.Ash.run_action(Principal, :create_local_user, %{
             attrs: attrs,
             password_hash: password_hash,
             must_change_password: must_change_password
           }) do
      {:ok, Map.put(created, :initial_password, initial_password)}
    end
  end

  @doc false
  def create_local_user_in_tx(repo, attrs, password_hash, must_change_password) do
    with {:ok, %{principal: principal} = created} <- create_human_in_tx(repo, attrs),
         {:ok, _credential} <-
           put_local_credential_in_tx(repo, principal.uid, password_hash, must_change_password) do
      {:ok, created}
    end
  end

  @doc """
  Loads the Principal, human profile, and local credential for one normalized
  email address.
  """
  @spec fetch_local_login(String.t()) :: {:ok, map()} | {:error, :not_found}
  def fetch_local_login(email) do
    case HumanUser
         |> Ash.Query.filter(email == ^email)
         |> Ash.Query.load(principal: [:local_credential])
         |> Ankole.Ash.read_one!() do
      %HumanUser{principal: %Principal{} = principal} = human_user ->
        {:ok,
         %{principal: principal, human_user: human_user, credential: principal.local_credential}}

      _missing ->
        {:error, :not_found}
    end
  end

  @doc """
  Stores a local password hash for a Human that has an email address.

  `Ankole.IdentityProviders.LocalPassword` hashes the password before this call.
  """
  @spec put_local_credential(String.t(), String.t(), boolean()) ::
          {:ok, LocalCredential.t()} | {:error, term()}
  def put_local_credential(uid, password_hash, must_change_password) do
    Ankole.Ash.run_action(LocalCredential, :put_password, %{
      uid: uid,
      password_hash: password_hash,
      must_change_password: must_change_password
    })
  end

  @doc false
  def put_local_password_in_tx(repo, uid, password_hash, must_change_password) do
    with :ok <- ensure_local_login_human(uid),
         do: put_local_credential_in_tx(repo, uid, password_hash, must_change_password)
  end

  @doc false
  def put_local_credential_in_tx(_repo, uid, password_hash, must_change_password) do
    attrs = %{password_hash: password_hash, must_change_password: must_change_password}

    case LocalCredential |> Ash.Query.filter(principal_uid == ^uid) |> Ankole.Ash.read_one!() do
      %LocalCredential{} = credential ->
        Ankole.Ash.update(credential, :set_password_in_tx, attrs)

      nil ->
        Ankole.Ash.create(LocalCredential, :create_in_tx, Map.put(attrs, :principal_uid, uid))
    end
  end

  @doc """
  Replaces a password that the Human must change.

  The write locks the credential and requires the verified credential version
  and the must-change flag to still match.
  """
  @spec complete_forced_password_change(String.t(), String.t(), non_neg_integer()) ::
          {:ok, LocalCredential.t()} | {:error, term()}
  def complete_forced_password_change(uid, password_hash, credential_version) do
    Ankole.Ash.run_action(LocalCredential, :complete_forced_password_change, %{
      uid: uid,
      password_hash: password_hash,
      credential_version: credential_version
    })
  end

  @doc false
  def complete_forced_password_change_in_tx(_repo, uid, password_hash, credential_version) do
    with %LocalCredential{must_change_password: true} = credential <-
           LocalCredential
           |> Ash.Query.filter(principal_uid == ^uid)
           |> Ash.Query.lock(:for_update)
           |> Ankole.Ash.read_one!(),
         true <- LocalCredential.version(credential) == credential_version do
      Ankole.Ash.update(credential, :set_password_in_tx, %{
        password_hash: password_hash,
        must_change_password: false
      })
    else
      _no_matching_change -> {:error, :password_change_not_required}
    end
  end

  defp ensure_local_login_human(uid) do
    case HumanUser |> Ash.Query.filter(principal_uid == ^uid) |> Ankole.Ash.read_one!() do
      %HumanUser{email: email} when is_binary(email) ->
        :ok

      %HumanUser{} ->
        {:error, :email_missing}

      nil ->
        case get_principal(uid) do
          {:ok, %Principal{}} -> {:error, :not_human}
          {:error, _missing} -> {:error, :not_found}
        end
    end
  end

  @doc """
  Lists Principal accounts. Disabled Principals are excluded unless requested.
  """
  @spec list_principal_accounts(keyword()) :: [map()]
  def list_principal_accounts(opts \\ []) do
    query =
      if Keyword.get(opts, :include_disabled, false),
        do: principal_account_query(),
        else: Ash.Query.filter(principal_account_query(), status == :active)

    query
    |> Ankole.Ash.read!()
    |> Enum.map(&principal_account/1)
  end

  @doc """
  Loads one Principal with its account facts for the operator console.
  """
  @spec get_principal_account(String.t()) :: {:ok, map()} | {:error, term()}
  def get_principal_account(uid) do
    with {:ok, normalized_uid} <- normalize_uid(uid) do
      principal_account_query()
      |> Ash.Query.filter(uid == ^normalized_uid)
      |> Ankole.Ash.read_one!()
      |> case do
        nil -> {:error, :not_found}
        principal -> {:ok, principal_account(principal)}
      end
    end
  end

  @doc false
  @spec bind_external_identity(module(), map()) ::
          {:ok, ExternalIdentity.t()} | {:error, term()}
  def bind_external_identity(_repo, attrs) when is_map(attrs) do
    changeset = Ankole.Ash.for_create(ExternalIdentity, :bind_in_tx, attrs)

    with {:ok, normalized} <- Ash.Changeset.apply_attributes(changeset) do
      case fetch_platform_subject(normalized.provider, normalized.external_id) do
        %ExternalIdentity{principal_uid: principal_uid} = identity
        when principal_uid == normalized.principal_uid ->
          {:ok, identity}

        %ExternalIdentity{} ->
          {:error, :platform_subject_already_bound}

        nil ->
          Ankole.Ash.create(ExternalIdentity, :bind_in_tx, attrs)
      end
    end
  end

  @doc """
  Upserts a human Principal from a provider-scoped subject.

  A first-seen subject that carries an email or mobile number already held by
  an existing human Principal binds to that Principal instead of creating a
  new one, so subjects from different providers converge on one human. Any
  other first-seen subject gets a new UUIDv7 UID. An email or
  mobile value owned by a different Principal than the one the subject
  resolves to is dropped from the profile update with a warning; subjects
  are never re-pointed automatically.

  When `external_ids` supplies aliases, an existing binding for any candidate
  wins and every candidate binds to the selected Principal in one transaction.
  A candidate already bound to another Principal fails the complete write.

  An observation keeps the Principal's existing display name; only
  `authoritative_profile: true` (directory sync) may replace it.
  """
  @spec upsert_platform_subject_human(map()) ::
          {:ok,
           %{principal: Principal.t(), human_user: HumanUser.t(), identity: ExternalIdentity.t()}}
          | {:error, term()}
  def upsert_platform_subject_human(attrs) when is_map(attrs),
    do: Ankole.Ash.run_action(Principal, :upsert_platform_subject_human, %{attrs: attrs})

  @doc false
  def upsert_platform_subject_human_in_tx(repo, attrs) do
    email = normalized_email_attr(attrs)
    mobile = normalized_mobile_attr(attrs)

    with {:ok, provider} <- required_provider(attrs, :provider),
         {:ok, external_id} <- required_text(attrs, :external_id),
         {:ok, external_ids} <- candidate_external_ids(attrs),
         {:ok, metadata} <- metadata_attrs(attrs),
         :ok <- lock_platform_subjects(repo, provider, external_ids),
         :ok <-
           Ankole.IdentityProviders.DirectoryAccess.guard_subject(repo, provider, external_ids),
         :ok <- maybe_lock_human_contact(repo, "principal_human_email", email),
         :ok <- maybe_lock_human_contact(repo, "principal_human_mobile", mobile),
         existing_identity <- fetch_platform_subject_by_ids(provider, external_ids),
         {:ok, selection} <-
           platform_subject_principal_uid(existing_identity, attrs, external_id, email, mobile),
         {:ok, principal} <- upsert_human_principal(repo, selection, attrs),
         profile_attrs <-
           drop_conflicting_contacts(
             provider,
             principal.uid,
             take_attrs(attrs, @human_profile_fields)
           ),
         {:ok, human_user} <- upsert_human_user(repo, principal.uid, profile_attrs),
         {:ok, identities} <-
           upsert_platform_subject_identities(principal, provider, external_ids, metadata),
         :ok <- delete_pending_mapping_requests(provider, external_ids) do
      identity = hd(identities)
      {:ok, %{principal: principal, human_user: human_user, identity: identity}}
    end
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
  ladder: an existing binding for this provider wins, then the owner of the
  email, then the owner of the mobile number. It never creates or re-points
  anything; a miss returns `{:error, :not_found}` so the caller decides what an
  unmatched subject means.
  """
  @spec match_platform_subject_human(map()) :: principal_result()
  def match_platform_subject_human(attrs) when is_map(attrs) do
    with {:ok, provider} <- required_provider(attrs, :provider),
         {:ok, external_ids} <- candidate_external_ids(attrs) do
      email = normalized_email_attr(attrs)
      mobile = normalized_mobile_attr(attrs)

      case provider_subject_principal_by_ids(provider, external_ids) do
        nil ->
          (contact_owner_principal(:email, email) || contact_owner_principal(:mobile, mobile))
          |> active_human_result()

        provider_match ->
          active_human_result(provider_match)
      end
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
      case fetch_platform_subject(provider, external_id) do
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
           Ankole.Ash.create(Principal, :create_in_tx, attrs),
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

  defp insert_human_user(_repo, principal_uid, attrs) do
    attrs = Map.put(attrs, :principal_uid, principal_uid)

    Ankole.Ash.create(HumanUser, :create_in_tx, attrs)
  end

  defp insert_agent(_repo, principal_uid, attrs) do
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
        case get_principal(owner_uid) do
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
    case lock_agent_in_tx(Repo, uid) do
      %Agent{} = agent ->
        with {:ok, attrs} <- keep_owned_agent_options(agent, attrs) do
          Ankole.Ash.update(agent, :profile_in_tx, attrs)
        end

      nil ->
        {:error, :not_agent}
    end
  end

  defp update_principal_profile(_repo, principal, attrs) do
    profile_attrs = take_attrs(attrs, @principal_profile_fields)

    case map_size(profile_attrs) do
      0 ->
        {:ok, principal}

      _count ->
        Ankole.Ash.update(principal, :profile_in_tx, profile_attrs)
    end
  end

  defp upsert_human_principal(repo, {:new, uid}, attrs) do
    insert_principal(repo, human_principal_attrs(attrs, uid))
  end

  defp upsert_human_principal(repo, {:selected, uid}, attrs) do
    case lock_principal_in_tx(repo, uid) do
      {:ok, %Principal{type: :human} = principal} ->
        update_principal_profile(repo, principal, observed_profile_attrs(principal, attrs))

      {:ok, %Principal{}} ->
        {:error, :not_human}

      {:error, :not_found} ->
        {:error, :principal_not_found}

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
    case HumanUser
         |> Ash.Query.filter(principal_uid == ^principal_uid)
         |> Ankole.Ash.read_one!() do
      %HumanUser{} = human_user ->
        Ankole.Ash.update(human_user, :profile_in_tx, attrs)

      nil ->
        insert_human_user(repo, principal_uid, attrs)
    end
  end

  defp principal_account_query do
    Principal
    |> Ash.Query.load([:human_user, :agent, :local_credential, :has_external_identity])
    |> Ash.Query.sort(uid: :asc)
  end

  defp principal_account(%Principal{} = principal) do
    local_credential_status =
      case principal.local_credential do
        nil -> nil
        %LocalCredential{must_change_password: true} -> :must_change
        %LocalCredential{must_change_password: false} -> :active
      end

    %{
      principal: principal,
      email: principal.human_user && principal.human_user.email,
      handle: principal.agent && principal.agent.handle,
      has_external_identity: principal.has_external_identity,
      local_credential_status: local_credential_status
    }
  end

  defp upsert_external_identity(attrs) do
    changeset = Ankole.Ash.for_create(ExternalIdentity, :bind_in_tx, attrs)

    with {:ok, normalized} <- Ash.Changeset.apply_attributes(changeset) do
      case fetch_platform_subject(normalized.provider, normalized.external_id) do
        %ExternalIdentity{principal_uid: principal_uid} = identity
        when principal_uid == normalized.principal_uid ->
          Ankole.Ash.update(identity, :observe_in_tx, %{metadata: normalized.metadata})

        %ExternalIdentity{} ->
          {:error, :platform_subject_already_bound}

        nil ->
          Ankole.Ash.create(ExternalIdentity, :bind_in_tx, attrs)
      end
    end
  end

  @doc """
  Locks one Principal row in the caller's transaction.

  The mode is `:update` (the default), `:share`, or `:key_share`. The Principal
  lock has the first rank of the work lock order.
  """
  @spec lock_principal_in_tx(module(), term(), :update | :share | :key_share) ::
          principal_result()
  def lock_principal_in_tx(_repo, uid, mode \\ :update) do
    with {:ok, normalized_uid} <- normalize_uid(uid) do
      case Principal
           |> Ash.Query.filter(uid == ^normalized_uid)
           |> Ash.Query.lock(row_lock(mode))
           |> Ankole.Ash.read_one!(lock_identity: {"principals", normalized_uid}) do
        %Principal{} = principal -> {:ok, principal}
        nil -> {:error, :not_found}
      end
    end
  end

  @doc """
  Locks an active Human and its profile row for share in the caller's
  transaction.

  The lock keeps the status and the access version stable until the commit.
  """
  @spec lock_active_human_in_tx(module(), term()) ::
          {:ok, %{principal: Principal.t(), human_user: HumanUser.t()}} | {:error, term()}
  def lock_active_human_in_tx(repo, uid) do
    with {:ok, %Principal{type: :human, status: :active} = principal} <-
           lock_principal_in_tx(repo, uid, :share),
         %HumanUser{} = human_user <-
           HumanUser
           |> Ash.Query.filter(principal_uid == ^principal.uid)
           |> Ash.Query.lock("FOR SHARE")
           |> Ankole.Ash.read_one!() do
      {:ok, %{principal: principal, human_user: human_user}}
    else
      {:ok, %Principal{}} -> {:error, :human_access_revoked}
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp row_lock(:update), do: :for_update
  defp row_lock(:share), do: "FOR SHARE"
  defp row_lock(:key_share), do: "FOR KEY SHARE"

  @doc """
  Lists the bindings of one provider subject in every tenant, in Principal UID
  order.

  A site sign-in uses this read to find the tenants where the subject has a
  Principal.
  """
  @spec list_platform_subject_bindings(String.t(), String.t()) :: [ExternalIdentity.t()]
  def list_platform_subject_bindings(provider, external_id) do
    ExternalIdentity
    |> Ash.Query.for_read(:read_across_tenants)
    |> Ash.Query.filter(provider == ^provider and external_id == ^external_id)
    |> Ash.Query.sort(principal_uid: :asc)
    |> Ankole.Ash.read_across_tenants!()
  end

  @doc """
  Locks one Agent row for update in the caller's transaction, or gives `nil`.

  The owned-option services (model profiles and token quota) take only this
  lock. A Principal lock, when present, comes first.
  """
  @spec lock_agent_in_tx(module(), String.t()) :: Agent.t() | nil
  def lock_agent_in_tx(_repo, uid) do
    Agent
    |> Ash.Query.filter(uid == ^uid)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
  end

  @doc """
  Locks Principal rows in UID order in the caller's transaction.

  The result contains the rows that exist, in UID order.
  """
  @spec lock_principals_in_tx(module(), [String.t()]) :: {:ok, [Principal.t()]}
  def lock_principals_in_tx(_repo, uids) when is_list(uids) do
    uids = uids |> Enum.uniq() |> Enum.sort()

    principals =
      Principal
      |> Ash.Query.filter(uid in ^uids)
      |> Ash.Query.sort(uid: :asc)
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read!(lock_identity: {"principals", uids})

    {:ok, principals}
  end

  defp ensure_principal_type(%Principal{type: type}, type), do: :ok
  defp ensure_principal_type(%Principal{type: :human}, :agent), do: {:error, :not_agent}
  defp ensure_principal_type(%Principal{type: :agent}, :human), do: {:error, :not_human}

  defp human_principal_attrs(attrs, uid \\ NativeKernel.gen_uuid_v7()) do
    attrs
    |> take_attrs(@principal_profile_fields)
    |> Map.merge(%{uid: uid, type: :human})
  end

  defp agent_principal_attrs(attrs) do
    attrs
    |> take_attrs([:uid | @principal_profile_fields])
    |> Map.merge(%{type: :agent})
  end

  defp fetch_platform_subject(provider, external_id) do
    ExternalIdentity
    |> Ash.Query.filter(provider == ^provider and external_id == ^external_id)
    |> Ankole.Ash.read_one!()
  end

  defp fetch_platform_subject_by_ids(provider, external_ids) do
    Enum.find_value(external_ids, &fetch_platform_subject(provider, &1))
  end

  @doc false
  @spec lock_platform_subject(module(), String.t(), String.t()) :: :ok | {:error, term()}
  def lock_platform_subject(repo, provider, external_id)
      when is_binary(provider) and is_binary(external_id) do
    advisory_xact_lock(
      repo,
      "principal_external_identity:platform_subject:#{Repo.tenant_id!()}:#{provider}:#{external_id}"
    )
  end

  defp lock_platform_subjects(repo, provider, external_ids) do
    external_ids
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn external_id, :ok ->
      case lock_platform_subject(repo, provider, external_id) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc false
  @spec delete_pending_mapping_request(module(), String.t(), String.t()) :: :ok
  def delete_pending_mapping_request(_repo, provider, external_id)
      when is_binary(provider) and is_binary(external_id) do
    delete_pending_mapping_requests(provider, [external_id])
  end

  defp delete_pending_mapping_requests(provider, external_ids) do
    MappingRequest
    |> Ash.Query.filter(provider == ^provider and external_id in ^external_ids)
    |> Ankole.Ash.destroy_where(:delete_in_tx)
    |> case do
      {:ok, _requests} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp maybe_lock_human_contact(_repo, _prefix, nil), do: :ok

  defp maybe_lock_human_contact(repo, prefix, value) do
    advisory_xact_lock(repo, "#{prefix}:#{Repo.tenant_id!()}:#{value}")
  end

  defp advisory_xact_lock(repo, lock_key) do
    case Ankole.AdvisoryLock.lock(repo, lock_key) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Provider bindings, contact matches, and explicit reviewer selections only
  # select existing humans. A new external subject gets an opaque UUID.
  defp platform_subject_principal_uid(
         %ExternalIdentity{principal_uid: principal_uid},
         _attrs,
         _external_id,
         _email,
         _mobile
       ) do
    {:ok, {:selected, principal_uid}}
  end

  defp platform_subject_principal_uid(nil, attrs, external_id, email, mobile) do
    case contact_owner_uid(:email, email) || contact_owner_uid(:mobile, mobile) do
      nil ->
        case fetch_attr(attrs, :uid) do
          {:ok, uid} ->
            with {:ok, uid} <- normalize_uid(uid), do: {:ok, {:selected, uid}}

          :error ->
            {:ok, {:new, NativeKernel.gen_uuid_v7()}}
        end

      owner_uid ->
        Logging.info(
          "principals.platform_subject.contact_join",
          "Platform subject joined an existing principal by email or mobile",
          %{principal_uid: owner_uid, external_id: external_id}
        )

        {:ok, {:selected, owner_uid}}
    end
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
    case HumanUser
         |> Ash.Query.do_filter([{field, value}])
         |> Ash.Query.load(:principal)
         |> Ankole.Ash.read_one!() do
      %HumanUser{principal: principal} -> %{principal: principal}
      nil -> nil
    end
  end

  # Unique-owned contact fields are dropped rather than failed on: a unique
  # violation would abort the whole transaction, and the conflicting field is
  # the other provider's problem to reconcile, not this subject's.
  defp drop_conflicting_contacts(provider, principal_uid, profile_attrs) do
    profile_attrs
    |> drop_conflicting_contact(provider, principal_uid, :email, &normalize_email/1)
    |> drop_conflicting_contact(provider, principal_uid, :mobile, &normalized_contact_mobile/1)
  end

  defp drop_conflicting_contact(profile_attrs, provider, principal_uid, field, normalize) do
    with {:ok, value} <- Map.fetch(profile_attrs, field),
         normalized when is_binary(normalized) <- normalize.(value),
         owner_uid when is_binary(owner_uid) <- contact_owner_uid(field, normalized) do
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

  defp contact_owner_uid(_field, nil), do: nil

  defp contact_owner_uid(field, value) do
    case HumanUser |> Ash.Query.do_filter([{field, value}]) |> Ankole.Ash.read_one!() do
      %HumanUser{principal_uid: principal_uid} -> principal_uid
      nil -> nil
    end
  end

  # Uses the HumanUser phone codec; a value the kernel cannot
  # normalize is left for the resource to reject.
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

  defp upsert_platform_subject_identities(principal, provider, external_ids, metadata) do
    external_ids
    |> Enum.reduce_while({:ok, []}, fn external_id, {:ok, identities} ->
      attrs =
        platform_subject_identity_attrs(
          principal,
          provider,
          external_id,
          metadata,
          fetch_platform_subject(provider, external_id)
        )

      case upsert_external_identity(attrs) do
        {:ok, identity} -> {:cont, {:ok, [identity | identities]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, identities} -> {:ok, Enum.reverse(identities)}
      {:error, _reason} = error -> error
    end
  end

  defp provider_subject_principal(provider, external_id) do
    case ExternalIdentity
         |> Ash.Query.filter(provider == ^provider and external_id == ^external_id)
         |> Ash.Query.load(:principal)
         |> Ankole.Ash.read_one!() do
      %ExternalIdentity{principal: principal} = identity ->
        %{identity: identity, principal: principal}

      nil ->
        nil
    end
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

  defp normalize_required_text(value), do: Ankole.Attrs.required_text(value, :invalid_text)

  defp metadata_attrs(attrs) do
    case fetch_attr(attrs, :metadata) do
      {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
      {:ok, _metadata} -> {:error, :invalid_metadata}
      :error -> {:ok, %{}}
    end
  end

  # These `options["ai_agent"]` keys belong to the model profile and token quota
  # services and their own routes. A whole-options write keeps their stored
  # values, so a client that never read them cannot remove a configured profile
  # or quota.
  @owned_ai_agent_keys ~w(models provider_hosted token_quota)

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
