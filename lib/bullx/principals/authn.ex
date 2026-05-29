defmodule BullX.Principals.AuthN do
  @moduledoc false

  import Ecto.Query

  alias BullX.AuthZ
  alias BullX.Config.Principals, as: PrincipalsConfig
  alias BullX.Principals.Agent
  alias BullX.Principals.Code
  alias BullX.Principals.ExternalIdentity
  alias BullX.Principals.HumanUser
  alias BullX.Principals.Principal
  alias BullX.Principals.PrincipalLoginAuthCode
  alias BullX.Repo

  @bind_existing_human "bind_existing_human"
  @allow_create_human "allow_create_human"
  @human_fields %{"email" => :email, "phone" => :phone}
  @bootstrap_activation_code_key {__MODULE__, :bootstrap_activation_code}

  @spec get_principal(String.t()) :: {:ok, Principal.t()} | {:error, :not_found}
  def get_principal(uid) when is_binary(uid) do
    case Repo.get_by(Principal, uid: uid) do
      %Principal{} = principal -> {:ok, principal}
      nil -> {:error, :not_found}
    end
  end

  def get_principal(_uid), do: {:error, :not_found}

  @spec update_principal_status(Principal.t() | String.t(), :active | :disabled) ::
          {:ok, Principal.t()}
          | {:error, :not_found | :invalid_status | :last_active_human_admin}
          | {:error, Ecto.Changeset.t()}
  def update_principal_status(principal_or_uid, status) when status in [:active, :disabled] do
    transaction(fn ->
      with {:ok, principal} <- fetch_principal_for_update(principal_or_uid),
           :ok <- ensure_status_change_allowed(principal, status) do
        principal
        |> Ecto.Changeset.change(%{status: status})
        |> Repo.update()
      end
    end)
  end

  def update_principal_status(_principal_or_uid, _status), do: {:error, :invalid_status}

  @spec disable_principal(Principal.t() | String.t()) ::
          {:ok, Principal.t()}
          | {:error, :not_found | :last_active_human_admin}
          | {:error, Ecto.Changeset.t()}
  def disable_principal(principal_or_uid),
    do: update_principal_status(principal_or_uid, :disabled)

  @spec create_human(map()) ::
          {:ok, %{principal: Principal.t(), human_user: HumanUser.t()}}
          | {:error, Ecto.Changeset.t()}
  def create_human(attrs) when is_map(attrs) do
    normalized = normalize_human_create_attrs(attrs)
    transaction(fn -> insert_human_record(normalized) end)
  end

  @spec create_agent(map()) ::
          {:ok, %{principal: Principal.t(), agent: Agent.t()}} | {:error, Ecto.Changeset.t()}
  def create_agent(attrs) when is_map(attrs) do
    normalized = normalize_agent_create_attrs(attrs)
    transaction(fn -> insert_agent_record(normalized) end)
  end

  @spec update_agent(Principal.t() | String.t(), map()) ::
          {:ok, %{principal: Principal.t(), agent: Agent.t()}}
          | {:error, :not_found | :not_agent}
          | {:error, Ecto.Changeset.t()}
  def update_agent(principal_or_uid, attrs) when is_map(attrs) do
    normalized = normalize_agent_update_attrs(attrs)

    transaction(fn ->
      with {:ok, principal} <- fetch_principal_for_update(principal_or_uid),
           :ok <- ensure_agent_principal(principal),
           {:ok, principal} <- update_agent_principal(principal, normalized.principal),
           {:ok, agent} <- update_agent_record(principal, normalized.agent) do
        {:ok, %{principal: principal, agent: agent}}
      end
    end)
  end

  @spec list_active_agents() :: [%{principal: Principal.t(), agent: Agent.t()}]
  def list_active_agents do
    Agent
    |> join(:inner, [agent], principal in assoc(agent, :principal))
    |> where([_agent, principal], principal.status == :active and principal.type == :agent)
    |> order_by([_agent, principal], asc: principal.inserted_at)
    |> preload([_agent, principal], principal: principal)
    |> Repo.all()
    |> Enum.map(fn %Agent{principal: principal} = agent ->
      %{principal: principal, agent: agent}
    end)
  end

  @spec setup_required?() :: boolean()
  def setup_required?, do: not AuthZ.root_initialized?()

  @spec verify_bootstrap_activation_code_for_setup(String.t()) ::
          {:ok, String.t()} | {:error, :invalid_or_expired_code}
  def verify_bootstrap_activation_code_for_setup(plaintext) when is_binary(plaintext) do
    verify_current_bootstrap_code(plaintext)
  end

  @spec bootstrap_activation_code_valid_for_hash?(String.t() | nil) :: boolean()
  def bootstrap_activation_code_valid_for_hash?(code_hash) when is_binary(code_hash) do
    case current_bootstrap_code() do
      %{code_hash: ^code_hash} = code -> setup_required?() and valid_bootstrap_code?(code)
      _code -> false
    end
  end

  def bootstrap_activation_code_valid_for_hash?(_code_hash), do: false

  @spec create_or_refresh_bootstrap_activation_code() ::
          {:ok,
           %{
             code: String.t(),
             code_hash: String.t(),
             expires_at: DateTime.t(),
             action: :created | :refreshed
           }}
          | {:error, term()}
  def create_or_refresh_bootstrap_activation_code do
    case setup_required?() do
      true -> put_fresh_bootstrap_activation_code()
      false -> {:error, :bootstrap_not_required}
    end
  end

  @spec resolve_channel_actor(atom() | String.t(), String.t(), String.t()) ::
          {:ok, Principal.t()}
          | {:error, :not_bound | :identity_unverified | :principal_disabled}
  def resolve_channel_actor(adapter, channel_id, external_id) do
    with {:ok, input} <- normalize_channel_ref(adapter, channel_id, external_id) do
      case fetch_channel_binding_state(input) do
        {:ok, principal, _identity} -> {:ok, principal}
        :not_found -> {:error, :not_bound}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec match_or_create_human_from_channel(map()) ::
          {:ok, Principal.t(), ExternalIdentity.t()}
          | {:error, :identity_unverified}
          | {:error, :principal_disabled}
          | {:error, term()}
  def match_or_create_human_from_channel(input) when is_map(input) do
    with {:ok, normalized} <- normalize_channel_input(input) do
      transaction(fn ->
        case fetch_channel_binding_state(normalized) do
          {:ok, principal, identity} -> {:ok, principal, identity}
          {:error, reason} -> {:error, reason}
          :not_found -> match_unbound_channel(normalized)
        end
      end)
    end
  end

  @spec ensure_human_from_channel_actor(map()) ::
          {:ok, Principal.t(), ExternalIdentity.t()}
          | {:error, :not_human}
          | {:error, term()}
  def ensure_human_from_channel_actor(input) when is_map(input) do
    with {:ok, normalized} <- normalize_channel_input(input) do
      transaction(fn ->
        case fetch_channel_binding_for_im_fact(normalized) do
          {:ok, principal, identity} -> {:ok, principal, identity}
          {:error, reason} -> {:error, reason}
          :not_found -> ensure_unbound_channel_human(normalized)
        end
      end)
    end
  end

  @spec channel_identity_verified?(ExternalIdentity.t() | nil) :: boolean()
  def channel_identity_verified?(%ExternalIdentity{verified_at: %DateTime{}}), do: true
  def channel_identity_verified?(_identity), do: false

  @spec match_or_create_human_from_login_subject(map()) ::
          {:ok, Principal.t(), ExternalIdentity.t()}
          | {:error, :not_bound}
          | {:error, :principal_disabled}
          | {:error, :not_human}
          | {:error, term()}
  def match_or_create_human_from_login_subject(input) when is_map(input) do
    with {:ok, normalized} <- normalize_login_subject_input(input) do
      transaction(fn ->
        case fetch_login_subject_state(normalized) do
          {:ok, principal, identity} -> active_human_result(principal, identity)
          {:error, reason} -> {:error, reason}
          :not_found -> match_unbound_login_subject(normalized)
        end
      end)
    end
  end

  @spec root_init_with_bootstrap_code(String.t(), map()) ::
          {:ok, Principal.t(), ExternalIdentity.t()}
          | {:error, :invalid_or_expired_code}
          | {:error, :root_init_closed}
          | {:error, term()}
  def root_init_with_bootstrap_code(plaintext_code, input)
      when is_binary(plaintext_code) and is_map(input) do
    with :ok <- AuthZ.ensure_root_init_open(),
         {:ok, _code_hash} <- verify_current_bootstrap_code(plaintext_code),
         {:ok, normalized} <- normalize_channel_input(input),
         {:ok, principal, identity} <- ensure_verified_channel_human(normalized),
         :ok <- AuthZ.root_init_admin(principal) do
      {:ok, principal, identity}
    end
  end

  @spec issue_login_auth_code(atom() | String.t(), String.t(), String.t()) ::
          {:ok, String.t()}
          | {:error, :not_bound}
          | {:error, :identity_unverified}
          | {:error, :principal_disabled}
          | {:error, :not_human}
          | {:error, term()}
  def issue_login_auth_code(adapter, channel_id, external_id) do
    with {:ok, principal} <- resolve_channel_actor(adapter, channel_id, external_id),
         :ok <- ensure_human_principal(principal),
         plaintext <- Code.login_auth_code(),
         {:ok, code_hash} <- Code.hash(plaintext),
         attrs <- login_auth_code_attrs(code_hash, principal, adapter, channel_id, external_id),
         {:ok, _auth_code} <-
           %PrincipalLoginAuthCode{}
           |> PrincipalLoginAuthCode.changeset(attrs)
           |> Repo.insert() do
      {:ok, plaintext}
    end
  end

  @spec consume_login_auth_code(String.t()) ::
          {:ok, Principal.t()}
          | {:error, :invalid_or_expired_code}
          | {:error, :principal_disabled}
          | {:error, :not_human}
  def consume_login_auth_code(plaintext_code) when is_binary(plaintext_code) do
    transaction(fn ->
      plaintext_code
      |> find_valid_login_auth_code()
      |> consume_verified_login_auth_code()
    end)
  end

  defp insert_human_record(%{principal: principal_attrs, human_user: human_attrs}) do
    with {:ok, principal} <- insert_principal(principal_attrs),
         {:ok, human_user} <- insert_human_user(principal, human_attrs) do
      {:ok, %{principal: principal, human_user: human_user}}
    end
  end

  defp insert_agent_record(%{principal: principal_attrs, agent: agent_attrs}) do
    with {:ok, principal} <- insert_principal(principal_attrs),
         {:ok, agent} <- insert_agent(principal, agent_attrs) do
      {:ok, %{principal: principal, agent: agent}}
    end
  end

  defp insert_principal(attrs) do
    %Principal{}
    |> Principal.changeset(attrs)
    |> Repo.insert()
  end

  defp insert_human_user(%Principal{uid: principal_uid}, attrs) do
    attrs = Map.put(attrs, :principal_uid, principal_uid)

    %HumanUser{}
    |> HumanUser.changeset(attrs)
    |> Repo.insert()
  end

  defp insert_agent(%Principal{uid: agent_uid}, attrs) do
    attrs = Map.put(attrs, :uid, agent_uid)

    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert()
  end

  defp update_agent_principal(%Principal{} = principal, attrs) do
    principal
    |> Principal.changeset(Map.merge(attrs, %{type: :agent}))
    |> Repo.update()
  end

  defp update_agent_record(%Principal{uid: agent_uid}, attrs) do
    case Repo.get(Agent, agent_uid) do
      nil ->
        %Agent{}
        |> Agent.changeset(Map.put(attrs, :uid, agent_uid))
        |> Repo.insert()

      %Agent{} = agent ->
        agent
        |> Agent.changeset(attrs)
        |> Repo.update()
    end
  end

  defp fetch_principal_for_update(%Principal{uid: uid}), do: fetch_principal_for_update(uid)

  defp fetch_principal_for_update(uid) when is_binary(uid) do
    case Repo.one(
           from principal in Principal,
             where: principal.uid == ^uid,
             lock: "FOR UPDATE"
         ) do
      nil -> {:error, :not_found}
      principal -> {:ok, principal}
    end
  end

  defp fetch_principal_for_update(_principal), do: {:error, :not_found}

  defp ensure_status_change_allowed(_principal, :active), do: :ok

  defp ensure_status_change_allowed(%Principal{} = principal, :disabled) do
    AuthZ.ensure_can_disable_principal(principal)
  end

  defp ensure_agent_principal(%Principal{type: :agent}), do: :ok
  defp ensure_agent_principal(%Principal{}), do: {:error, :not_agent}

  defp match_unbound_channel(input) do
    case evaluate_match_rules(input) do
      {:bind, principal} -> bind_principal_to_channel(principal, input)
      :allow_create -> auto_create_channel_if_enabled(input)
      :no_match -> auto_create_unmatched_channel(input)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_unbound_channel_human(input) do
    case evaluate_im_fact_match_rules(input) do
      {:bind, principal} -> bind_principal_to_channel_for_im_fact(principal, input)
      _other -> create_human_and_channel_identity(input)
    end
  end

  defp ensure_verified_channel_human(input) do
    transaction(fn ->
      case fetch_channel_binding_for_im_fact(%{input | trusted_realm_by_default: true}) do
        {:ok, %Principal{status: :active} = principal, %ExternalIdentity{} = identity} ->
          with {:ok, principal} <- refresh_channel_human_profile(principal, input),
               {:ok, identity} <- verify_channel_identity(identity, input) do
            {:ok, principal, identity}
          end

        {:ok, %Principal{status: :disabled}, %ExternalIdentity{}} ->
          {:error, :principal_disabled}

        {:error, reason} ->
          {:error, reason}

        :not_found ->
          with {:ok, principal, identity} <-
                 ensure_unbound_channel_human(%{input | trusted_realm_by_default: true}) do
            {:ok, principal, identity}
          end
      end
    end)
  end

  defp match_unbound_login_subject(input) do
    case bind_login_subject_from_identity_facts(input) do
      {:ok, principal, identity} -> {:ok, principal, identity}
      {:error, reason} -> {:error, reason}
      :not_found -> match_unbound_login_subject_by_channel_or_rules(input)
    end
  end

  defp match_unbound_login_subject_by_channel_or_rules(input) do
    case bind_login_subject_from_channel_actor(input) do
      {:ok, principal, identity} -> {:ok, principal, identity}
      {:error, reason} -> {:error, reason}
      :not_found -> match_unbound_login_subject_by_rules(input)
    end
  end

  defp match_unbound_login_subject_by_rules(input) do
    case evaluate_match_rules(input) do
      {:bind, principal} -> bind_principal_to_login_subject(principal, input)
      :allow_create -> auto_create_login_subject_if_enabled(input)
      :no_match -> {:error, :not_bound}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bind_login_subject_from_identity_facts(input) do
    input
    |> login_subject_identity_facts()
    |> Enum.reduce_while(:not_found, fn identity_fact, :not_found ->
      case fetch_human_by_identity_fact(identity_fact) do
        nil -> {:cont, :not_found}
        %Principal{} = principal -> {:halt, bind_principal_to_login_subject(principal, input)}
      end
    end)
  end

  defp login_subject_identity_facts(input) do
    [
      {"uid", input.profile["uid"]},
      {"email", input.profile["email"]},
      {"phone", input.profile["phone"]}
    ]
    |> Enum.flat_map(&normalize_identity_fact/1)
    |> Enum.uniq()
  end

  defp normalize_identity_fact({field, value}) do
    case normalize_lookup_value(field, value) do
      {:ok, normalized} -> [{field, normalized}]
      :error -> []
    end
  end

  defp bind_login_subject_from_channel_actor(input) do
    with {:ok, channel_ref} <- login_subject_channel_ref(input),
         {:ok, principal, _channel_identity} <- fetch_channel_binding_state(channel_ref) do
      bind_principal_to_login_subject(principal, input)
    else
      :not_found -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  defp login_subject_channel_ref(input) do
    adapter = Map.get(input.metadata, "adapter")
    channel_id = Map.get(input.metadata, "channel_id") || Map.get(input.metadata, "source_id")

    case normalize_channel_ref(adapter, channel_id, input.external_id) do
      {:ok, channel_ref} -> {:ok, channel_ref}
      {:error, _reason} -> :not_found
    end
  end

  defp auto_create_channel_if_enabled(input) do
    case PrincipalsConfig.principals_authn_auto_create_humans!() do
      true -> create_human_and_channel_identity(input, verified_at: verification_timestamp(input))
      false -> {:error, :identity_unverified}
    end
  end

  defp auto_create_login_subject_if_enabled(input) do
    case PrincipalsConfig.principals_authn_auto_create_humans!() do
      true -> create_human_and_login_identity(input)
      false -> {:error, :not_bound}
    end
  end

  defp auto_create_unmatched_channel(input), do: auto_create_channel_if_enabled(input)

  defp evaluate_match_rules(input) do
    PrincipalsConfig.principals_authn_match_rules!()
    |> Enum.reduce_while(:no_match, fn rule, :no_match ->
      case evaluate_rule(rule, input) do
        :no_match -> {:cont, :no_match}
        result -> {:halt, result}
      end
    end)
  end

  defp evaluate_im_fact_match_rules(input) do
    PrincipalsConfig.principals_authn_match_rules!()
    |> Enum.reduce_while(:no_match, fn rule, :no_match ->
      case evaluate_im_fact_rule(rule, input) do
        :no_match -> {:cont, :no_match}
        result -> {:halt, result}
      end
    end)
  end

  defp evaluate_rule(%{"result" => @bind_existing_human} = rule, input) do
    with {:ok, value} <- get_source_value(input, rule["source_path"]),
         {:ok, field} <- fetch_human_field(rule["human_field"]),
         {:ok, normalized_value} <- normalize_lookup_value(rule["human_field"], value) do
      case fetch_human_by_field(field, normalized_value) do
        nil -> :no_match
        %HumanUser{principal: %Principal{status: :active} = principal} -> {:bind, principal}
        %HumanUser{principal: %Principal{status: :disabled}} -> {:error, :principal_disabled}
      end
    else
      _other -> :no_match
    end
  end

  defp evaluate_rule(%{"result" => @allow_create_human, "op" => "email_domain_in"} = rule, input) do
    with {:ok, value} <- get_source_value(input, rule["source_path"]),
         {:ok, email} <- normalize_lookup_value("email", value),
         [_local, domain] <- String.split(email, "@", parts: 2),
         true <- domain in rule["domains"] do
      :allow_create
    else
      _other -> :no_match
    end
  end

  defp evaluate_rule(%{"result" => @allow_create_human, "op" => "equals_any"} = rule, input) do
    with {:ok, value} <- get_source_value(input, rule["source_path"]),
         {:ok, normalized_value} <- normalize_lookup_value(nil, value),
         true <- normalized_value in rule["values"] do
      :allow_create
    else
      _other -> :no_match
    end
  end

  defp evaluate_rule(_rule, _input), do: :no_match

  defp evaluate_im_fact_rule(%{"result" => @bind_existing_human} = rule, input) do
    with {:ok, value} <- get_source_value(input, rule["source_path"]),
         {:ok, field} <- fetch_human_field(rule["human_field"]),
         {:ok, normalized_value} <- normalize_lookup_value(rule["human_field"], value) do
      case fetch_human_by_field(field, normalized_value) do
        nil -> :no_match
        %HumanUser{principal: %Principal{type: :human} = principal} -> {:bind, principal}
        %HumanUser{} -> :no_match
      end
    else
      _other -> :no_match
    end
  end

  defp evaluate_im_fact_rule(rule, input), do: evaluate_rule(rule, input)

  defp fetch_channel_binding_state(input) do
    case fetch_channel_binding(input) do
      nil ->
        :not_found

      %ExternalIdentity{
        verified_at: %DateTime{},
        principal: %Principal{status: :active} = principal
      } =
          identity ->
        {:ok, principal, identity}

      %ExternalIdentity{principal: %Principal{status: :active}} = identity ->
        maybe_verify_active_channel_binding(identity, input)

      %ExternalIdentity{principal: %Principal{status: :disabled}} ->
        {:error, :principal_disabled}
    end
  end

  defp fetch_channel_binding_for_im_fact(input) do
    case fetch_channel_binding(input) do
      nil ->
        :not_found

      %ExternalIdentity{principal: %Principal{type: :human} = principal} = identity ->
        {:ok, principal, maybe_verify_channel_identity_for_fact(identity, input)}

      %ExternalIdentity{principal: %Principal{}} ->
        {:error, :not_human}
    end
  end

  defp maybe_verify_active_channel_binding(
         %ExternalIdentity{principal: %Principal{status: :active} = principal} = identity,
         input
       ) do
    case input.trusted_realm_by_default do
      true ->
        with {:ok, identity} <- verify_channel_identity(identity, input) do
          {:ok, principal, identity}
        end

      false ->
        {:error, :identity_unverified}
    end
  end

  defp maybe_verify_channel_identity_for_fact(
         %ExternalIdentity{verified_at: nil} = identity,
         %{trusted_realm_by_default: true} = input
       ) do
    case verify_channel_identity(identity, input) do
      {:ok, identity} -> identity
      {:error, _reason} -> identity
    end
  end

  defp maybe_verify_channel_identity_for_fact(%ExternalIdentity{} = identity, _input),
    do: identity

  defp fetch_login_subject_state(input) do
    case fetch_login_subject(input) do
      nil ->
        :not_found

      %ExternalIdentity{principal: %Principal{status: :active} = principal} = identity ->
        {:ok, principal, identity}

      %ExternalIdentity{principal: %Principal{status: :disabled}} ->
        {:error, :principal_disabled}
    end
  end

  defp fetch_channel_binding(input) do
    Repo.one(
      from identity in ExternalIdentity,
        where:
          identity.kind == :channel_actor and identity.adapter == ^input.adapter and
            identity.channel_id == ^input.channel_id and
            identity.external_id == ^input.external_id,
        preload: [:principal]
    )
  end

  defp fetch_login_subject(input) do
    Repo.one(
      from identity in ExternalIdentity,
        where:
          identity.kind == :login_subject and identity.provider == ^input.provider and
            identity.external_id == ^input.external_id,
        preload: [:principal]
    )
  end

  defp fetch_human_by_identity_fact({"uid", uid}) do
    Repo.one(
      from principal in Principal,
        where: principal.uid == ^uid,
        select: principal
    )
  end

  defp fetch_human_by_identity_fact({field, value}) when field in ["email", "phone"] do
    case fetch_human_by_field(String.to_existing_atom(field), value) do
      nil -> nil
      %HumanUser{principal: principal} -> principal
    end
  end

  defp fetch_human_by_field(field, value) do
    Repo.one(
      from human in HumanUser,
        join: principal in assoc(human, :principal),
        where: field(human, ^field) == ^value,
        preload: [principal: principal]
    )
  end

  defp bind_principal_to_channel(%Principal{status: :active, type: :human} = principal, input) do
    attrs = channel_identity_attrs(principal, input, verification_timestamp(input))

    %ExternalIdentity{}
    |> ExternalIdentity.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, identity} -> {:ok, principal, identity}
      {:error, changeset} -> existing_channel_binding_after_conflict(changeset, input)
    end
  end

  defp bind_principal_to_channel(%Principal{status: :disabled}, _input),
    do: {:error, :principal_disabled}

  defp bind_principal_to_channel(%Principal{}, _input), do: {:error, :not_human}

  defp bind_principal_to_channel_for_im_fact(%Principal{type: :human} = principal, input) do
    attrs = channel_identity_attrs(principal, input, verification_timestamp(input))

    %ExternalIdentity{}
    |> ExternalIdentity.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, identity} -> {:ok, principal, identity}
      {:error, changeset} -> existing_channel_binding_for_im_fact_after_conflict(changeset, input)
    end
  end

  defp bind_principal_to_channel_for_im_fact(%Principal{}, _input), do: {:error, :not_human}

  defp bind_principal_to_login_subject(
         %Principal{status: :active, type: :human} = principal,
         input
       ) do
    attrs = login_subject_identity_attrs(principal, input)

    %ExternalIdentity{}
    |> ExternalIdentity.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, identity} -> {:ok, principal, identity}
      {:error, changeset} -> existing_login_subject_after_conflict(changeset, input)
    end
  end

  defp bind_principal_to_login_subject(%Principal{status: :disabled}, _input),
    do: {:error, :principal_disabled}

  defp bind_principal_to_login_subject(%Principal{}, _input), do: {:error, :not_human}

  defp create_human_and_channel_identity(input, opts \\ []) do
    verified_at = Keyword.get(opts, :verified_at, verification_timestamp(input))

    with {:ok, %{principal: principal}} <- insert_human_record(channel_human_attrs(input)),
         {:ok, identity} <-
           insert_new_channel_identity(principal, input, verified_at) do
      {:ok, principal, identity}
    end
  end

  defp create_human_and_login_identity(input) do
    with {:ok, %{principal: principal}} <- insert_human_record(login_subject_human_attrs(input)),
         {:ok, identity} <- insert_new_login_subject_identity(principal, input) do
      {:ok, principal, identity}
    end
  end

  defp insert_new_channel_identity(principal, input, verified_at) do
    %ExternalIdentity{}
    |> ExternalIdentity.changeset(channel_identity_attrs(principal, input, verified_at))
    |> Repo.insert()
  end

  defp insert_new_login_subject_identity(principal, input) do
    %ExternalIdentity{}
    |> ExternalIdentity.changeset(login_subject_identity_attrs(principal, input))
    |> Repo.insert()
  end

  defp existing_channel_binding_after_conflict(changeset, input) do
    case external_identity_unique_conflict?(
           changeset,
           "principal_external_identities_channel_actor_index"
         ) do
      true ->
        case fetch_channel_binding_state(input) do
          {:ok, principal, identity} -> {:ok, principal, identity}
          {:error, :identity_unverified} -> {:error, :identity_unverified}
          {:error, :principal_disabled} -> {:error, :principal_disabled}
          _other -> {:error, changeset}
        end

      false ->
        {:error, changeset}
    end
  end

  defp existing_channel_binding_for_im_fact_after_conflict(changeset, input) do
    case external_identity_unique_conflict?(
           changeset,
           "principal_external_identities_channel_actor_index"
         ) do
      true ->
        case fetch_channel_binding_for_im_fact(input) do
          {:ok, principal, identity} -> {:ok, principal, identity}
          _other -> {:error, changeset}
        end

      false ->
        {:error, changeset}
    end
  end

  defp existing_login_subject_after_conflict(changeset, input) do
    case external_identity_unique_conflict?(
           changeset,
           "principal_external_identities_login_subject_index"
         ) do
      true ->
        case fetch_login_subject_state(input) do
          {:ok, principal, identity} -> active_human_result(principal, identity)
          _other -> {:error, changeset}
        end

      false ->
        {:error, changeset}
    end
  end

  defp active_human_result(%Principal{status: :active, type: :human} = principal, identity),
    do: {:ok, principal, identity}

  defp active_human_result(%Principal{status: :active}, _identity), do: {:error, :not_human}

  defp external_identity_unique_conflict?(%Ecto.Changeset{} = changeset, constraint_name) do
    Enum.any?(changeset.errors, fn
      {_field, {_message, opts}} ->
        Keyword.get(opts, :constraint) == :unique and
          to_string(Keyword.get(opts, :constraint_name)) == constraint_name
    end)
  end

  defp put_fresh_bootstrap_activation_code do
    plaintext = Code.bootstrap_activation_code()
    previous = current_bootstrap_code()

    with {:ok, code_hash} <- Code.hash(plaintext) do
      code = %{
        code_hash: code_hash,
        expires_at: expires_at(PrincipalsConfig.principals_activation_code_ttl_seconds!())
      }

      :persistent_term.put(@bootstrap_activation_code_key, code)

      {:ok,
       %{
         code: plaintext,
         code_hash: code_hash,
         expires_at: code.expires_at,
         action: bootstrap_code_action(previous)
       }}
    end
  end

  defp verify_current_bootstrap_code(plaintext) do
    case current_bootstrap_code() do
      %{code_hash: code_hash} = code ->
        cond do
          not setup_required?() -> {:error, :invalid_or_expired_code}
          not valid_bootstrap_code?(code) -> {:error, :invalid_or_expired_code}
          Code.verified?(plaintext, code_hash) -> {:ok, code_hash}
          true -> {:error, :invalid_or_expired_code}
        end

      _code ->
        {:error, :invalid_or_expired_code}
    end
  end

  defp current_bootstrap_code do
    :persistent_term.get(@bootstrap_activation_code_key, nil)
  end

  defp valid_bootstrap_code?(%{expires_at: %DateTime{} = expires_at}) do
    DateTime.compare(expires_at, utc_now()) == :gt
  end

  defp valid_bootstrap_code?(_code), do: false

  defp bootstrap_code_action(nil), do: :created
  defp bootstrap_code_action(_code), do: :refreshed

  defp find_valid_login_auth_code(plaintext_code) do
    threshold =
      PrincipalsConfig.principals_login_auth_code_ttl_seconds!()
      |> then(&DateTime.add(utc_now(), -&1, :second))

    PrincipalLoginAuthCode
    |> where([code], code.inserted_at > ^threshold)
    |> order_by([code], asc: code.inserted_at)
    |> lock("FOR UPDATE")
    |> Repo.all()
    |> Enum.find(&Code.verified?(plaintext_code, &1.code_hash))
    |> case do
      nil -> {:error, :invalid_or_expired_code}
      auth_code -> {:ok, auth_code}
    end
  end

  defp consume_verified_login_auth_code({:error, reason}), do: {:error, reason}

  defp consume_verified_login_auth_code({:ok, auth_code}) do
    auth_code = Repo.preload(auth_code, :principal)

    case auth_code.principal do
      %Principal{status: :active, type: :human} = principal ->
        with {:ok, _deleted} <- Repo.delete(auth_code) do
          {:ok, principal}
        end

      %Principal{status: :active} ->
        {:error, :not_human}

      %Principal{status: :disabled} ->
        {:error, :principal_disabled}
    end
  end

  defp normalize_human_create_attrs(attrs) do
    principal_source = map_attr(attrs, :principal) || map_attr(attrs, :principal_attrs) || attrs
    human_source = map_attr(attrs, :human_user) || map_attr(attrs, :human_attrs) || attrs

    %{
      principal: %{
        uid: attr(principal_source, :uid),
        type: :human,
        status: attr(principal_source, :status) || :active,
        display_name: attr(principal_source, :display_name),
        avatar_url: attr(principal_source, :avatar_url)
      },
      human_user: %{
        email: attr(human_source, :email),
        phone: attr(human_source, :phone)
      }
    }
  end

  defp normalize_agent_create_attrs(attrs) do
    principal_source = map_attr(attrs, :principal) || map_attr(attrs, :principal_attrs) || attrs
    agent_source = map_attr(attrs, :agent) || map_attr(attrs, :agent_attrs) || attrs

    %{
      principal: %{
        uid: attr(principal_source, :uid),
        type: :agent,
        status: attr(principal_source, :status) || :active,
        display_name: attr(principal_source, :display_name),
        avatar_url: attr(principal_source, :avatar_url)
      },
      agent: %{
        type: attr(agent_source, :type) || :ai_agent,
        profile: attr(agent_source, :profile),
        created_by_principal_uid: attr(agent_source, :created_by_principal_uid)
      }
    }
  end

  defp normalize_agent_update_attrs(attrs) do
    principal_source = map_attr(attrs, :principal) || map_attr(attrs, :principal_attrs) || attrs
    agent_source = map_attr(attrs, :agent) || map_attr(attrs, :agent_attrs) || attrs

    %{
      principal: %{
        uid: attr(principal_source, :uid),
        type: :agent,
        status: attr(principal_source, :status) || :active,
        display_name: attr(principal_source, :display_name),
        avatar_url: attr(principal_source, :avatar_url)
      },
      agent: %{
        type: attr(agent_source, :type) || :ai_agent,
        profile: attr(agent_source, :profile),
        created_by_principal_uid: attr(agent_source, :created_by_principal_uid)
      }
    }
  end

  defp channel_human_attrs(input) do
    %{
      principal: %{
        uid: unique_uid(uid_candidate(input.profile)),
        type: :human,
        status: :active,
        display_name: display_name(input),
        avatar_url: input.profile["avatar_url"]
      },
      human_user: %{
        email: input.profile["email"],
        phone: input.profile["phone"]
      }
    }
  end

  defp login_subject_human_attrs(input) do
    %{
      principal: %{
        uid: unique_uid(uid_candidate(input.profile)),
        type: :human,
        status: :active,
        display_name: display_name(input),
        avatar_url: input.profile["avatar_url"]
      },
      human_user: %{
        email: input.profile["email"],
        phone: input.profile["phone"]
      }
    }
  end

  defp refresh_channel_human_profile(%Principal{} = principal, input) do
    principal = Repo.preload(principal, :human_user)

    with {:ok, principal} <- update_channel_principal_profile(principal, input),
         {:ok, _human_user} <- update_channel_human_user_profile(principal.human_user, input) do
      {:ok, principal}
    end
  end

  defp update_channel_principal_profile(%Principal{} = principal, input) do
    attrs =
      %{
        uid: unique_uid(uid_candidate(input.profile), principal.uid),
        display_name: preferred_display_name(input),
        avatar_url: input.profile["avatar_url"]
      }
      |> reject_nil_values()

    principal
    |> Principal.changeset(attrs)
    |> Repo.update()
  end

  defp update_channel_human_user_profile(%HumanUser{} = human_user, input) do
    attrs =
      %{
        email: input.profile["email"],
        phone: input.profile["phone"]
      }
      |> reject_nil_values()

    human_user
    |> HumanUser.changeset(attrs)
    |> Repo.update()
  end

  defp update_channel_human_user_profile(nil, _input), do: {:error, :not_human}

  defp verify_channel_identity(%ExternalIdentity{} = identity, input) do
    metadata = identity_metadata(input)

    identity
    |> ExternalIdentity.changeset(%{verified_at: utc_now(), metadata: metadata})
    |> Repo.update()
  end

  defp verification_timestamp(%{trusted_realm_by_default: true}), do: utc_now()
  defp verification_timestamp(_input), do: nil

  defp channel_identity_attrs(%Principal{uid: principal_uid}, input, verified_at) do
    %{
      principal_uid: principal_uid,
      kind: :channel_actor,
      adapter: input.adapter,
      channel_id: input.channel_id,
      external_id: input.external_id,
      verified_at: verified_at,
      metadata: identity_metadata(input)
    }
  end

  defp login_subject_identity_attrs(%Principal{uid: principal_uid}, input) do
    %{
      principal_uid: principal_uid,
      kind: :login_subject,
      provider: input.provider,
      external_id: input.external_id,
      metadata: identity_metadata(input)
    }
  end

  defp login_auth_code_attrs(
         code_hash,
         %Principal{uid: principal_uid},
         adapter,
         channel_id,
         external_id
       ) do
    %{
      code_hash: code_hash,
      principal_uid: principal_uid,
      metadata: %{
        "adapter" => to_string(adapter),
        "channel_id" => channel_id,
        "external_id" => external_id
      }
    }
  end

  defp identity_metadata(input) do
    %{
      "profile" => input.profile,
      "metadata" => input.metadata
    }
  end

  defp display_name(input) do
    preferred_display_name(input) || "Human"
  end

  defp preferred_display_name(input) do
    input.profile["display_name"] || input.profile["display"] || input.profile["username"] ||
      input.profile["email"]
  end

  defp uid_candidate(profile) do
    profile["username"] || email_local_part(profile["email"]) || profile["uid"] ||
      profile["display_name"] || profile["display"] || profile["phone"] || "human"
  end

  defp email_local_part(nil), do: nil

  defp email_local_part(email) when is_binary(email) do
    email
    |> String.split("@", parts: 2)
    |> List.first()
  end

  defp unique_uid(candidate, excluded_principal_uid \\ nil) do
    base = canonical_uid(candidate)

    case Repo.exists?(unique_uid_query(base, excluded_principal_uid)) do
      false -> base
      true -> base <> "-" <> String.slice(BullX.Ext.gen_base36_uuid(), 0, 8)
    end
  end

  defp unique_uid_query(base, nil) do
    from principal in Principal,
      where: principal.uid == ^base,
      select: 1
  end

  defp unique_uid_query(base, excluded_principal_uid) do
    from principal in Principal,
      where: principal.uid == ^base and principal.uid != ^excluded_principal_uid,
      select: 1
  end

  defp canonical_uid(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_.-]+/, "-")
    |> String.trim(".-")
    |> non_blank_uid()
  end

  defp non_blank_uid(""), do: "human"
  defp non_blank_uid(uid), do: uid

  defp normalize_channel_ref(adapter, channel_id, external_id) do
    with {:ok, adapter} <- normalize_identifier(adapter),
         {:ok, channel_id} <- normalize_identifier(channel_id),
         {:ok, external_id} <- normalize_identifier(external_id) do
      {:ok,
       %{
         adapter: adapter,
         channel_id: channel_id,
         external_id: external_id,
         trusted_realm_by_default: false
       }}
    end
  end

  defp normalize_channel_input(input) do
    with {:ok, input} <- stringify_map(input),
         {:ok, adapter} <- fetch_identifier(input, "adapter"),
         {:ok, channel_id} <- fetch_identifier(input, "channel_id"),
         {:ok, external_id} <- fetch_identifier(input, "external_id"),
         {:ok, profile} <- optional_map(input, "profile"),
         {:ok, metadata} <- optional_map(input, "metadata"),
         {:ok, trusted_realm_by_default} <-
           optional_boolean(input, "trusted_realm_by_default", false) do
      {:ok,
       %{
         adapter: adapter,
         channel_id: channel_id,
         external_id: external_id,
         profile: normalize_identity_map(profile),
         metadata: metadata,
         trusted_realm_by_default: trusted_realm_by_default
       }}
    end
  end

  defp normalize_login_subject_input(input) do
    with {:ok, input} <- stringify_map(input),
         {:ok, provider} <- fetch_identifier(input, "provider"),
         {:ok, external_id} <- fetch_identifier(input, "external_id"),
         {:ok, profile} <- optional_map(input, "profile"),
         {:ok, metadata} <- optional_map(input, "metadata") do
      {:ok,
       %{
         provider: provider,
         external_id: external_id,
         profile: normalize_identity_map(profile),
         metadata: metadata
       }}
    end
  end

  defp optional_map(map, key) do
    case Map.get(map, key, %{}) do
      value when is_map(value) -> {:ok, value}
      _value -> {:error, {:invalid_identity_input, key}}
    end
  end

  defp optional_boolean(map, key, default) do
    case Map.get(map, key, default) do
      value when is_boolean(value) -> {:ok, value}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _value -> {:error, {:invalid_identity_input, key}}
    end
  end

  defp fetch_identifier(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> normalize_identifier(value)
      :error -> {:error, {:missing_identity_input, key}}
    end
  end

  defp normalize_identifier(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> {:error, :blank_identifier}
      value -> {:ok, value}
    end
  end

  defp normalize_identifier(value) when value in [nil, true, false],
    do: {:error, :invalid_identifier}

  defp normalize_identifier(value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp normalize_identifier(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp normalize_identifier(_value), do: {:error, :invalid_identifier}

  defp normalize_identity_map(map) do
    map
    |> normalize_identity_field("email", &String.downcase/1)
    |> normalize_identity_field("phone", &Function.identity/1)
    |> normalize_identity_field("uid", &Function.identity/1)
    |> normalize_identity_field("username", &Function.identity/1)
    |> normalize_identity_field("display_name", &Function.identity/1)
    |> normalize_identity_field("display", &Function.identity/1)
    |> normalize_identity_field("avatar_url", &Function.identity/1)
  end

  defp normalize_identity_field(map, field, fun) do
    case Map.fetch(map, field) do
      {:ok, value} ->
        case normalize_lookup_value(field, value) do
          {:ok, normalized} -> Map.put(map, field, fun.(normalized))
          :error -> Map.delete(map, field)
        end

      :error ->
        map
    end
  end

  defp get_source_value(input, source_path) when is_binary(source_path) do
    source_path
    |> String.split(".")
    |> Enum.reduce_while(%{"profile" => input.profile, "metadata" => input.metadata}, fn key,
                                                                                         current ->
      case current do
        %{^key => value} -> {:cont, value}
        _other -> {:halt, :error}
      end
    end)
    |> present_source_value()
  end

  defp get_source_value(_input, _source_path), do: :error

  defp present_source_value(:error), do: :error

  defp present_source_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> :error
      value -> {:ok, value}
    end
  end

  defp present_source_value(nil), do: :error
  defp present_source_value(value), do: {:ok, value}

  defp fetch_human_field(field) do
    case Map.fetch(@human_fields, field) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp normalize_lookup_value("email", value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> non_blank_string()
  end

  defp normalize_lookup_value("uid", value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> non_blank_string()
  end

  defp normalize_lookup_value("phone", value) when is_binary(value) do
    value
    |> String.trim()
    |> non_blank_string()
    |> normalize_phone_lookup()
  end

  defp normalize_lookup_value(_field, value) when is_binary(value) do
    value
    |> String.trim()
    |> non_blank_string()
  end

  defp normalize_lookup_value(_field, value) when is_integer(value),
    do: {:ok, Integer.to_string(value)}

  defp normalize_lookup_value(_field, value) when is_atom(value), do: {:ok, Atom.to_string(value)}
  defp normalize_lookup_value(_field, _value), do: :error

  defp normalize_phone_lookup({:ok, phone}) do
    case BullX.Ext.phone_normalize_e164(phone) do
      e164 when is_binary(e164) -> {:ok, e164}
      {:error, _reason} -> :error
    end
  end

  defp normalize_phone_lookup(:error), do: :error

  defp non_blank_string(""), do: :error
  defp non_blank_string(value), do: {:ok, value}

  defp stringify_map(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, key} <- stringify_key(key),
           {:ok, value} <- stringify_value(value) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp stringify_key(key) when is_binary(key), do: {:ok, key}
  defp stringify_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp stringify_key(_key), do: {:error, :invalid_map_key}

  defp stringify_value(value) when is_map(value), do: stringify_map(value)
  defp stringify_value(value), do: {:ok, value}

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp attr(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp attr(_map, _key), do: nil

  defp map_attr(map, key) when is_map(map) do
    case attr(map, key) do
      value when is_map(value) -> value
      _value -> nil
    end
  end

  defp ensure_human_principal(%Principal{type: :human}), do: :ok
  defp ensure_human_principal(%Principal{}), do: {:error, :not_human}

  defp expires_at(ttl_seconds), do: DateTime.add(utc_now(), ttl_seconds, :second)

  defp utc_now do
    DateTime.utc_now()
    |> DateTime.truncate(:microsecond)
  end

  defp transaction(fun) when is_function(fun, 0) do
    case Repo.transaction(fn ->
           case fun.() do
             {:error, reason} -> Repo.rollback(reason)
             other -> other
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end
end
