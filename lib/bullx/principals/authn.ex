defmodule BullX.Principals.AuthN do
  @moduledoc false

  import Ecto.Query

  alias BullX.AuthZ
  alias BullX.Config.Principals, as: PrincipalsConfig
  alias BullX.Principals.ActivationCode
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
  @bootstrap_metadata_key "bootstrap"
  @setup_gate_verified_at_key "setup_gate_verified_at"
  @bootstrap_activation_code_lock_namespace 92_409
  @bootstrap_activation_code_lock_id 8

  @spec get_principal(Ecto.UUID.t()) :: {:ok, Principal.t()} | {:error, :not_found}
  def get_principal(id) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %Principal{} = principal <- Repo.get(Principal, uuid) do
      {:ok, principal}
    else
      _other -> {:error, :not_found}
    end
  end

  def get_principal(_id), do: {:error, :not_found}

  @spec update_principal_status(Principal.t() | Ecto.UUID.t(), :active | :disabled) ::
          {:ok, Principal.t()}
          | {:error, :not_found | :invalid_status | :last_active_human_admin}
          | {:error, Ecto.Changeset.t()}
  def update_principal_status(principal_or_id, status) when status in [:active, :disabled] do
    transaction(fn ->
      with {:ok, principal} <- fetch_principal_for_update(principal_or_id),
           :ok <- ensure_status_change_allowed(principal, status) do
        principal
        |> Ecto.Changeset.change(%{status: status})
        |> Repo.update()
      end
    end)
  end

  def update_principal_status(_principal_or_id, _status), do: {:error, :invalid_status}

  @spec disable_principal(Principal.t() | Ecto.UUID.t()) ::
          {:ok, Principal.t()}
          | {:error, :not_found | :last_active_human_admin}
          | {:error, Ecto.Changeset.t()}
  def disable_principal(principal_or_id), do: update_principal_status(principal_or_id, :disabled)

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

  @spec setup_required?() :: boolean()
  def setup_required? do
    not Repo.exists?(from principal in Principal, where: principal.type == :human, select: 1)
  end

  @spec bootstrap_activation_code_consumed?() :: boolean()
  def bootstrap_activation_code_consumed? do
    Repo.exists?(
      from code in ActivationCode,
        where:
          not is_nil(code.used_at) and
            fragment("? ->> ?", code.metadata, ^@bootstrap_metadata_key) == "true",
        select: 1
    )
  end

  @spec bootstrap_activation_code_pending?() :: boolean()
  def bootstrap_activation_code_pending? do
    now = utc_now()

    Repo.exists?(
      from code in ActivationCode,
        where:
          is_nil(code.used_at) and is_nil(code.revoked_at) and code.expires_at > ^now and
            fragment("? ->> ?", code.metadata, ^@bootstrap_metadata_key) == "true",
        select: 1
    )
  end

  @spec verify_bootstrap_activation_code(String.t()) ::
          {:ok, String.t()} | {:error, :invalid_or_expired_code}
  def verify_bootstrap_activation_code(plaintext) when is_binary(plaintext) do
    now = utc_now()

    # We can't index by the plaintext (it's never stored) so we load every live
    # bootstrap hash and walk them. `Code.verified?/2` uses a constant-time
    # compare, so this linear scan does not leak per-hash timing — the only
    # observable thing is total candidate count, which is bounded and benign.
    hashes =
      Repo.all(
        from code in ActivationCode,
          where:
            is_nil(code.used_at) and is_nil(code.revoked_at) and code.expires_at > ^now and
              fragment("? ->> ?", code.metadata, ^@bootstrap_metadata_key) == "true",
          order_by: [asc: code.inserted_at],
          select: code.code_hash
      )

    case Enum.find(hashes, &Code.verified?(plaintext, &1)) do
      nil -> {:error, :invalid_or_expired_code}
      hash -> {:ok, hash}
    end
  end

  @spec verify_bootstrap_activation_code_for_setup(String.t()) ::
          {:ok, String.t()} | {:error, :invalid_or_expired_code | Ecto.Changeset.t()}
  def verify_bootstrap_activation_code_for_setup(plaintext) when is_binary(plaintext) do
    transaction(fn ->
      now = utc_now()

      case find_valid_bootstrap_activation_code_for_update(plaintext, now) do
        nil -> {:error, :invalid_or_expired_code}
        %ActivationCode{} = code -> mark_setup_gate_verified(code, now)
      end
    end)
  end

  @spec bootstrap_activation_code_valid_for_hash?(String.t() | nil) :: boolean()
  def bootstrap_activation_code_valid_for_hash?(code_hash) when is_binary(code_hash) do
    now = utc_now()

    Repo.exists?(
      from code in ActivationCode,
        where:
          code.code_hash == ^code_hash and is_nil(code.used_at) and is_nil(code.revoked_at) and
            code.expires_at > ^now and
            fragment("? ->> ?", code.metadata, ^@bootstrap_metadata_key) == "true",
        select: 1
    )
  end

  def bootstrap_activation_code_valid_for_hash?(_code_hash), do: false

  @spec create_or_refresh_bootstrap_activation_code() ::
          {:ok,
           %{
             code: String.t() | nil,
             activation_code: ActivationCode.t(),
             action: :created | :refreshed | :existing
           }}
          | {:error, term()}
  def create_or_refresh_bootstrap_activation_code do
    transaction(fn ->
      :ok = lock_bootstrap_activation_code!()

      cond do
        not setup_required?() -> {:error, :bootstrap_not_required}
        bootstrap_activation_code_consumed?() -> {:error, :bootstrap_already_consumed}
        true -> create_or_refresh_bootstrap_activation_code_in_transaction()
      end
    end)
  end

  @spec resolve_channel_actor(atom() | String.t(), String.t(), String.t()) ::
          {:ok, Principal.t()} | {:error, :not_bound} | {:error, :principal_disabled}
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
          | {:error, :activation_required}
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

  @spec create_activation_code(Principal.t() | nil, map()) ::
          {:ok, %{code: String.t(), activation_code: ActivationCode.t()}}
          | {:error, Ecto.Changeset.t()}
          | {:error, term()}
  def create_activation_code(created_by_principal, metadata \\ %{}) do
    plaintext = Code.activation_code()

    with {:ok, code_hash} <- Code.hash(plaintext) do
      attrs = %{
        code_hash: code_hash,
        expires_at: expires_at(PrincipalsConfig.principals_activation_code_ttl_seconds!()),
        created_by_principal_id: principal_id(created_by_principal),
        metadata: normalize_metadata(metadata)
      }

      %ActivationCode{}
      |> ActivationCode.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, activation_code} -> {:ok, %{code: plaintext, activation_code: activation_code}}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  @spec consume_activation_code(String.t(), map()) ::
          {:ok, Principal.t(), ExternalIdentity.t()}
          | {:error, :invalid_or_expired_code}
          | {:error, :already_bound}
          | {:error, term()}
  def consume_activation_code(plaintext_code, input)
      when is_binary(plaintext_code) and is_map(input) do
    with {:ok, normalized} <- normalize_channel_input(input) do
      transaction(fn -> consume_activation_code_in_transaction(plaintext_code, normalized) end)
      |> maybe_grant_bootstrap_admin_after_commit()
    end
  end

  @spec issue_login_auth_code(atom() | String.t(), String.t(), String.t()) ::
          {:ok, String.t()}
          | {:error, :not_bound}
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

  defp insert_human_user(%Principal{id: principal_id}, attrs) do
    attrs = Map.put(attrs, :principal_id, principal_id)

    %HumanUser{}
    |> HumanUser.changeset(attrs)
    |> Repo.insert()
  end

  defp insert_agent(%Principal{id: principal_id}, attrs) do
    attrs = Map.put(attrs, :principal_id, principal_id)

    %Agent{}
    |> Agent.changeset(attrs)
    |> Repo.insert()
  end

  defp fetch_principal_for_update(%Principal{id: id}), do: fetch_principal_for_update(id)

  defp fetch_principal_for_update(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.one(
               from principal in Principal,
                 where: principal.id == ^uuid,
                 lock: "FOR UPDATE"
             ) do
          nil -> {:error, :not_found}
          principal -> {:ok, principal}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp fetch_principal_for_update(_principal), do: {:error, :not_found}

  defp ensure_status_change_allowed(_principal, :active), do: :ok

  defp ensure_status_change_allowed(%Principal{} = principal, :disabled) do
    AuthZ.ensure_can_disable_principal(principal)
  end

  defp match_unbound_channel(input) do
    case evaluate_match_rules(input) do
      {:bind, principal} -> bind_principal_to_channel(principal, input)
      :allow_create -> auto_create_channel_if_enabled(input)
      :no_match -> auto_create_unmatched_channel(input)
      {:error, reason} -> {:error, reason}
    end
  end

  defp match_unbound_login_subject(input) do
    case evaluate_match_rules(input) do
      {:bind, principal} -> bind_principal_to_login_subject(principal, input)
      :allow_create -> auto_create_login_subject_if_enabled(input)
      :no_match -> {:error, :not_bound}
      {:error, reason} -> {:error, reason}
    end
  end

  defp auto_create_channel_if_enabled(input) do
    case PrincipalsConfig.principals_authn_auto_create_humans!() do
      true -> create_human_and_channel_identity(input)
      false -> {:error, :activation_required}
    end
  end

  defp auto_create_login_subject_if_enabled(input) do
    case PrincipalsConfig.principals_authn_auto_create_humans!() do
      true -> create_human_and_login_identity(input)
      false -> {:error, :not_bound}
    end
  end

  defp auto_create_unmatched_channel(input) do
    case {PrincipalsConfig.principals_authn_auto_create_humans!(),
          PrincipalsConfig.principals_authn_require_activation_code!()} do
      {true, false} -> create_human_and_channel_identity(input)
      _other -> {:error, :activation_required}
    end
  end

  defp consume_activation_code_in_transaction(plaintext_code, input) do
    case fetch_channel_binding(input) do
      nil -> consume_activation_code_for_unbound_actor(plaintext_code, input)
      %ExternalIdentity{} -> {:error, :already_bound}
    end
  end

  defp consume_activation_code_for_unbound_actor(plaintext_code, input) do
    case evaluate_match_rules(input) do
      {:bind, principal} ->
        bind_principal_to_channel(principal, input)

      {:error, reason} ->
        {:error, reason}

      _no_binding ->
        with {:ok, activation_code} <- find_valid_activation_code(plaintext_code),
             {:ok, principal, identity} <- create_human_and_channel_identity(input),
             :ok <- mark_activation_code_used(activation_code, principal, input) do
          activation_code_consume_result(activation_code, principal, identity)
        end
    end
  end

  defp activation_code_consume_result(%ActivationCode{} = activation_code, principal, identity) do
    case bootstrap_activation_code?(activation_code) do
      true -> {:ok, principal, identity, :bootstrap_admin}
      false -> {:ok, principal, identity}
    end
  end

  defp maybe_grant_bootstrap_admin_after_commit({:ok, principal, identity, :bootstrap_admin}) do
    case AuthZ.grant_bootstrap_admin(principal) do
      :ok -> {:ok, principal, identity}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_grant_bootstrap_admin_after_commit(result), do: result

  defp bootstrap_activation_code?(%ActivationCode{metadata: metadata}) do
    metadata = normalize_metadata(metadata)
    metadata[@bootstrap_metadata_key] == true
  end

  defp evaluate_match_rules(input) do
    PrincipalsConfig.principals_authn_match_rules!()
    |> Enum.reduce_while(:no_match, fn rule, :no_match ->
      case evaluate_rule(rule, input) do
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

  defp fetch_channel_binding_state(input) do
    case fetch_channel_binding(input) do
      nil ->
        :not_found

      %ExternalIdentity{principal: %Principal{status: :active} = principal} = identity ->
        {:ok, principal, identity}

      %ExternalIdentity{principal: %Principal{status: :disabled}} ->
        {:error, :principal_disabled}
    end
  end

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

  defp fetch_human_by_field(field, value) do
    Repo.one(
      from human in HumanUser,
        join: principal in assoc(human, :principal),
        where: field(human, ^field) == ^value,
        preload: [principal: principal]
    )
  end

  defp bind_principal_to_channel(%Principal{status: :active, type: :human} = principal, input) do
    attrs = channel_identity_attrs(principal, input)

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

  defp create_human_and_channel_identity(input) do
    with {:ok, %{principal: principal}} <- insert_human_record(channel_human_attrs(input)),
         {:ok, identity} <- insert_new_channel_identity(principal, input) do
      {:ok, principal, identity}
    end
  end

  defp create_human_and_login_identity(input) do
    with {:ok, %{principal: principal}} <- insert_human_record(login_subject_human_attrs(input)),
         {:ok, identity} <- insert_new_login_subject_identity(principal, input) do
      {:ok, principal, identity}
    end
  end

  defp insert_new_channel_identity(principal, input) do
    %ExternalIdentity{}
    |> ExternalIdentity.changeset(channel_identity_attrs(principal, input))
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

  defp find_valid_activation_code(plaintext_code) do
    now = utc_now()

    ActivationCode
    |> valid_activation_codes_query(now)
    |> lock("FOR UPDATE")
    |> Repo.all()
    |> Enum.find(&Code.verified?(plaintext_code, &1.code_hash))
    |> case do
      nil -> {:error, :invalid_or_expired_code}
      activation_code -> {:ok, activation_code}
    end
  end

  defp valid_activation_codes_query(query, now) do
    from code in query,
      where: is_nil(code.revoked_at) and is_nil(code.used_at) and code.expires_at > ^now,
      order_by: [asc: code.inserted_at]
  end

  defp mark_activation_code_used(
         %ActivationCode{} = activation_code,
         %Principal{} = principal,
         input
       ) do
    now = utc_now()
    metadata = activation_code_metadata(activation_code.metadata, input, now)

    {count, _rows} =
      Repo.update_all(
        from(code in ActivationCode,
          where:
            code.id == ^activation_code.id and is_nil(code.revoked_at) and is_nil(code.used_at) and
              code.expires_at > ^now
        ),
        set: [
          used_at: now,
          used_by_principal_id: principal.id,
          used_by_adapter: input.adapter,
          used_by_channel_id: input.channel_id,
          used_by_external_id: input.external_id,
          metadata: metadata,
          updated_at: now
        ]
      )

    case count do
      1 -> :ok
      0 -> {:error, :invalid_or_expired_code}
    end
  end

  defp activation_code_metadata(metadata, input, now) do
    metadata
    |> normalize_metadata()
    |> Map.put("consumed", %{
      "adapter" => input.adapter,
      "channel_id" => input.channel_id,
      "external_id" => input.external_id,
      "at" => DateTime.to_iso8601(now)
    })
  end

  defp fetch_unused_bootstrap_activation_code do
    Repo.one(
      from code in ActivationCode,
        where:
          is_nil(code.used_at) and is_nil(code.revoked_at) and
            fragment("? ->> ?", code.metadata, ^@bootstrap_metadata_key) == "true",
        order_by: [asc: code.inserted_at],
        limit: 1,
        lock: "FOR UPDATE"
    )
  end

  defp lock_bootstrap_activation_code! do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock($1::integer, $2::integer)",
      [@bootstrap_activation_code_lock_namespace, @bootstrap_activation_code_lock_id]
    )

    :ok
  end

  defp create_or_refresh_bootstrap_activation_code_in_transaction do
    case fetch_unused_bootstrap_activation_code() do
      nil ->
        create_bootstrap_activation_code()

      %ActivationCode{} = existing ->
        case setup_in_progress_unexpired?(existing, utc_now()) do
          true -> {:ok, %{code: nil, activation_code: existing, action: :existing}}
          false -> refresh_bootstrap_activation_code(existing)
        end
    end
  end

  defp create_bootstrap_activation_code do
    plaintext = Code.activation_code()

    with {:ok, code_hash} <- Code.hash(plaintext) do
      attrs = %{
        code_hash: code_hash,
        expires_at: expires_at(PrincipalsConfig.principals_activation_code_ttl_seconds!()),
        created_by_principal_id: nil,
        metadata: %{@bootstrap_metadata_key => true}
      }

      %ActivationCode{}
      |> ActivationCode.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, activation_code} ->
          {:ok, %{code: plaintext, activation_code: activation_code, action: :created}}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  defp refresh_bootstrap_activation_code(%ActivationCode{} = existing) do
    plaintext = Code.activation_code()
    now = utc_now()

    with {:ok, code_hash} <- Code.hash(plaintext) do
      attrs = %{
        code_hash: code_hash,
        expires_at: expires_at(PrincipalsConfig.principals_activation_code_ttl_seconds!()),
        metadata: refreshed_bootstrap_metadata(existing.metadata, now)
      }

      existing
      |> ActivationCode.changeset(attrs)
      |> Repo.update()
      |> case do
        {:ok, activation_code} ->
          {:ok, %{code: plaintext, activation_code: activation_code, action: :refreshed}}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  defp refreshed_bootstrap_metadata(metadata, now) do
    metadata
    |> normalize_metadata()
    |> Map.put(@bootstrap_metadata_key, true)
    |> Map.delete(@setup_gate_verified_at_key)
    |> Map.put("refreshed_at", DateTime.to_iso8601(now))
  end

  defp find_valid_bootstrap_activation_code_for_update(plaintext, now) do
    now
    |> valid_bootstrap_activation_codes_for_update()
    |> Enum.find(&Code.verified?(plaintext, &1.code_hash))
  end

  defp valid_bootstrap_activation_codes_for_update(now) do
    Repo.all(
      from code in ActivationCode,
        where:
          is_nil(code.used_at) and is_nil(code.revoked_at) and code.expires_at > ^now and
            fragment("? ->> ?", code.metadata, ^@bootstrap_metadata_key) == "true",
        order_by: [asc: code.inserted_at],
        lock: "FOR UPDATE"
    )
  end

  defp mark_setup_gate_verified(%ActivationCode{} = code, now) do
    metadata =
      code.metadata
      |> normalize_metadata()
      |> Map.put(@bootstrap_metadata_key, true)
      |> Map.put(@setup_gate_verified_at_key, DateTime.to_iso8601(now))

    code
    |> ActivationCode.changeset(%{metadata: metadata})
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated.code_hash}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp setup_in_progress_unexpired?(%ActivationCode{} = code, now) do
    metadata = normalize_metadata(code.metadata)

    Map.has_key?(metadata, @setup_gate_verified_at_key) and
      DateTime.compare(code.expires_at, now) == :gt
  end

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
        bio: attr(principal_source, :bio),
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
        bio: attr(principal_source, :bio),
        avatar_url: attr(principal_source, :avatar_url)
      },
      agent: %{
        profile: attr(agent_source, :profile),
        created_by_principal_id: attr(agent_source, :created_by_principal_id)
      }
    }
  end

  defp channel_human_attrs(input) do
    %{
      principal: %{
        uid: unique_uid(uid_candidate(input.profile, input.external_id)),
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
        uid: unique_uid(uid_candidate(input.profile, input.external_id)),
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

  defp channel_identity_attrs(%Principal{id: principal_id}, input) do
    %{
      principal_id: principal_id,
      kind: :channel_actor,
      adapter: input.adapter,
      channel_id: input.channel_id,
      external_id: input.external_id,
      metadata: identity_metadata(input)
    }
  end

  defp login_subject_identity_attrs(%Principal{id: principal_id}, input) do
    %{
      principal_id: principal_id,
      kind: :login_subject,
      provider: input.provider,
      external_id: input.external_id,
      metadata: identity_metadata(input)
    }
  end

  defp login_auth_code_attrs(
         code_hash,
         %Principal{id: principal_id},
         adapter,
         channel_id,
         external_id
       ) do
    %{
      code_hash: code_hash,
      principal_id: principal_id,
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
    input.profile["display_name"] || input.profile["display"] || input.profile["email"] ||
      input.external_id
  end

  defp uid_candidate(profile, external_id) do
    profile["uid"] || profile["username"] || email_local_part(profile["email"]) ||
      profile["phone"] ||
      external_id
  end

  defp email_local_part(nil), do: nil

  defp email_local_part(email) when is_binary(email) do
    email
    |> String.split("@", parts: 2)
    |> List.first()
  end

  defp unique_uid(candidate) do
    base = canonical_uid(candidate)

    case Repo.exists?(from principal in Principal, where: principal.uid == ^base, select: 1) do
      false -> base
      true -> base <> "-" <> String.slice(BullX.Ext.gen_base36_uuid(), 0, 8)
    end
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
      {:ok, %{adapter: adapter, channel_id: channel_id, external_id: external_id}}
    end
  end

  defp normalize_channel_input(input) do
    with {:ok, input} <- stringify_map(input),
         {:ok, adapter} <- fetch_identifier(input, "adapter"),
         {:ok, channel_id} <- fetch_identifier(input, "channel_id"),
         {:ok, external_id} <- fetch_identifier(input, "external_id"),
         {:ok, profile} <- optional_map(input, "profile"),
         {:ok, metadata} <- optional_map(input, "metadata") do
      {:ok,
       %{
         adapter: adapter,
         channel_id: channel_id,
         external_id: external_id,
         profile: normalize_identity_map(profile),
         metadata: metadata
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

  defp normalize_metadata(metadata) when is_map(metadata) do
    case stringify_map(metadata) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> %{}
    end
  end

  defp normalize_metadata(_metadata), do: %{}

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

  defp principal_id(nil), do: nil
  defp principal_id(%Principal{id: id}), do: id

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
