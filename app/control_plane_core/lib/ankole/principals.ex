defmodule Ankole.Principals do
  @moduledoc """
  Principal identity boundary for humans, agents, and external subject bindings.
  """
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  require Ash.Query

  alias Ankole.PrincipalKey

  alias Ankole.Principals.{
    AccessEvent,
    AccessRestriction,
    Agent,
    Agents,
    ExternalIdentity,
    Humans,
    HumanUser,
    LocalCredential,
    MappingRequest,
    PlatformSubjects,
    Principal
  }

  alias Ankole.Repo

  json_api do
    authorize?(false)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      base_route "/work-access-reviews", Ankole.Principals.Access do
        route(:get, "/", :unresolved_work, name: "list_work_access_reviews")
        route(:post, "/", :classify_work, name: "classify_work_access")
      end

      base_route "/principals", Ankole.Principals.Access do
        route(:get, "/:uid/access", :show, name: "get_human_access")
        route(:post, "/:uid/access-disables", :disable, name: "disable_human_access")
        route(:post, "/:uid/access-restorations", :restore, name: "restore_human_access")

        route(:post, "/:uid/access-restrictions/:restriction_id/clear", :clear_restriction,
          name: "clear_human_access_restriction"
        )

        route(:post, "/:uid/work-cleanup-retries", :retry_cleanup,
          name: "retry_human_work_cleanup"
        )

        route(:post, "/:uid/local-password-resets", :reset_local_password,
          name: "reset_local_password"
        )
      end

      base_route "/principals", Principal do
        index(:console_list, name: "list_principals", derive_sort?: false)
        get(:read, route: "/:uid", name: "get_principal")

        post(:create_local_user,
          name: "create_local_user",
          metadata: &__MODULE__.initial_password_meta/3
        )

        patch(:update_human, route: "/:uid", name: "update_human")
      end

      base_route "/identity-mapping-requests", MappingRequest do
        index(:console_list, name: "list_identity_mapping_requests", derive_sort?: false)
        delete(:delete_in_tx, name: "delete_identity_mapping_request", read_action: :by_id)
        route(:post, "/:id/bind", :bind_request, name: "bind_identity_mapping_request")
      end

      base_route "/identity-mappings", MappingRequest do
        route(:post, "/", :bind_subject, name: "create_identity_mapping")
      end

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

  resources do
    resource(Ankole.Principals.Access)

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

    resource(HumanUser)

    resource ExternalIdentity do
      define(:list_external_identities, action: :read)
    end

    resource(LocalCredential)
    resource(AccessRestriction)
    resource(AccessEvent)
    resource(MappingRequest)
  end

  @type principal_result :: {:ok, Principal.t()} | {:error, term()}

  @spec normalize_uid(term()) :: {:ok, String.t()} | {:error, :invalid_uid}
  def normalize_uid(uid), do: PrincipalKey.normalize(uid)

  @spec normalize_email(term()) :: String.t() | nil
  def normalize_email(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize_email(_value), do: nil

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

  @doc "Lists the bindings of one provider subject in every tenant, in Principal UID order."
  @spec list_platform_subject_bindings(String.t(), String.t()) :: [ExternalIdentity.t()]
  def list_platform_subject_bindings(provider, external_id) do
    ExternalIdentity
    |> Ash.Query.for_read(:read_across_tenants)
    |> Ash.Query.filter(provider == ^provider and external_id == ^external_id)
    |> Ash.Query.sort(principal_uid: :asc)
    |> Ankole.Ash.read_across_tenants!()
  end

  @doc false
  def initial_password_meta(_input, %Principal{} = principal, _request),
    do: %{initial_password: principal.__metadata__.initial_password}

  @doc false
  def describe_refusal(:local_identity_provider_disabled),
    do: {:conflict, "Local account sign-in is not enabled.", []}

  def describe_refusal(:platform_subject_already_bound),
    do: {:conflict, "This provider account is already bound to another user.", []}

  def describe_refusal(_reason), do: nil

  defdelegate get_principal(uid), to: Humans
  defdelegate list_active_principals(), to: Humans
  defdelegate system_principal(), to: Humans
  defdelegate ensure_system_principal_in_tx(), to: Humans
  defdelegate create_human(attrs), to: Humans
  defdelegate create_human_in_tx(attrs), to: Humans
  defdelegate update_human(uid, attrs), to: Humans
  defdelegate update_human_in_tx(changes), to: Humans
  defdelegate create_local_user(attrs, must_change_password), to: Humans
  defdelegate create_local_user_in_tx(args), to: Humans
  defdelegate fetch_local_login(email), to: Humans
  defdelegate put_local_credential(uid, password_hash, must_change_password), to: Humans
  defdelegate put_local_password_in_tx(uid, password_hash, must_change_password), to: Humans
  defdelegate put_local_credential_in_tx(uid, password_hash, must_change_password), to: Humans
  defdelegate complete_forced_password_change(uid, password_hash, credential_version), to: Humans

  defdelegate complete_forced_password_change_in_tx(uid, password_hash, credential_version),
    to: Humans

  defdelegate lock_principal_in_tx(uid, mode \\ :update), to: Humans
  defdelegate lock_active_human_in_tx(uid), to: Humans
  defdelegate lock_principals_in_tx(uids), to: Humans

  defdelegate create_agent(attrs), to: Agents
  defdelegate create_agent_in_tx(attrs), to: Agents
  defdelegate get_agent(uid), to: Agents
  defdelegate list_active_agents(), to: Agents
  defdelegate list_agents(opts \\ []), to: Agents
  defdelegate update_agent(uid, attrs), to: Agents
  defdelegate update_agent_in_tx(uid, attrs), to: Agents
  defdelegate enable_agent(uid), to: Agents
  defdelegate enable_agent_in_tx(uid), to: Agents
  defdelegate delete_agent(uid), to: Agents
  defdelegate delete_agent_in_tx(uid), to: Agents
  defdelegate publish_agent_changes(change), to: Agents
  defdelegate publish_agent_deletion(change), to: Agents
  defdelegate lock_agent_in_tx(uid), to: Agents

  defdelegate bind_external_identity(attrs), to: PlatformSubjects
  defdelegate upsert_platform_subject_human(attrs), to: PlatformSubjects
  defdelegate upsert_platform_subject_human_in_tx(attrs), to: PlatformSubjects
  defdelegate resolve_platform_subject(provider, external_id), to: PlatformSubjects
  defdelegate match_platform_subject_human(attrs), to: PlatformSubjects
  defdelegate resolve_platform_subject_uid(provider, external_id), to: PlatformSubjects
  defdelegate lock_platform_subject(provider, external_id), to: PlatformSubjects
  defdelegate delete_pending_mapping_request(provider, external_id), to: PlatformSubjects
end
