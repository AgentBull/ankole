defmodule Ankole.SignalsGateway.Bindings do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL
  alias Ankole.Repo
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.AppConfig
  alias Ankole.Plugins.ConfigSecrets
  alias Ankole.Principals
  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.Adapters
  alias Ankole.SignalsGateway.Adapters.Definition
  alias Ankole.SignalsGateway.OutboxEntry
  alias Ankole.SignalsGateway.Outbox
  alias Ankole.SignalsGateway.Binding
  alias Ankole.SignalsGateway.GroupMessageModes
  alias Ankole.SignalsGateway.SubjectNamespace
  alias Ankole.SignalsGateway.UnmatchedSenderPolicies
  alias Ankole.SignalsGateway.Utils

  @application_binding_config_errors %{
    "line" => :line_binding_config_unavailable,
    "lark" => :lark_binding_config_unavailable,
    "email" => :email_binding_config_unavailable,
    "whatsapp" => :whatsapp_binding_config_unavailable
  }

  @spec upsert_binding(map()) :: {:ok, Binding.t()} | {:error, term()}
  def upsert_binding(attrs) when is_map(attrs) do
    upsert_binding(Repo, attrs)
  end

  defp upsert_binding(repo, attrs) do
    %Binding{}
    |> Binding.changeset(attrs)
    |> repo.insert(
      on_conflict: {:replace_all_except, [:inserted_at]},
      conflict_target: [:agent_uid, :name],
      returning: true
    )
  end

  @doc false
  def delete_agent_config_rows_in_tx(repo, uid) do
    binding = Ankole.SignalsGateway.Binding
    refs = repo.all(from row in binding, where: row.agent_uid == ^uid, select: row.config_ref)

    Enum.each(refs, fn
      "app-config://" <> key = reference ->
        if not Repo.across_tenants(fn ->
             repo.exists?(
               from row in binding, where: row.config_ref == ^reference and row.agent_uid != ^uid
             )
           end) do
          repo.delete_all(
            from config in AppConfig, where: config.scope == "global" and config.key == ^key
          )
        end

      _ ->
        :ok
    end)

    :ok
  end

  @spec list_adapters() :: {:ok, [map()]} | {:error, term()}
  def list_adapters do
    with {:ok, definitions} <- Adapters.list(),
         {:ok, catalog} <- collect_ok(definitions, &adapter_catalog/1) do
      {:ok, Enum.sort_by(catalog, & &1.adapter_id)}
    end
  end

  @spec put_binding(String.t(), String.t(), String.t(), map()) ::
          {:ok, %{binding: Binding.t(), config_key: String.t()}} | {:error, term()}
  def put_binding(agent_uid, adapter_id, binding_name, attrs)
      when is_binary(adapter_id) and is_binary(binding_name) and is_map(attrs) do
    with {:ok, binding_name} <- normalize_binding_name(binding_name),
         {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
         {:ok, definition} <- Adapters.fetch(adapter_id),
         {:ok, config} <- binding_config(attrs),
         {:ok, normalized_config} <- validate_binding_config(definition, config, true),
         {:ok, application} <-
           resolve_platform_application(definition.config_module, normalized_config, :binding),
         {:ok, mode} <- group_message_mode(attrs, GroupMessageModes.default_mode()),
         :ok <- validate_supported_group_message_mode(definition, mode),
         {:ok, policy} <- GroupMessageModes.policy(mode),
         {:ok, unmatched_sender_policy} <-
           unmatched_sender_policy(attrs, UnmatchedSenderPolicies.default_value()),
         {:ok, config_key} <- binding_config_key(definition, principal.uid, binding_name),
         {:ok, binding} <-
           persist_binding_assignment(
             definition,
             principal.uid,
             binding_name,
             normalized_config,
             application,
             config_key,
             policy,
             unmatched_sender_policy
           ),
         :ok <- maybe_handle_binding_saved(definition, binding, normalized_config),
         :ok <- Outbox.wake_blocked_for_binding(principal.uid, binding_name),
         :ok <- Actors.wake_blocked_reply_previews(principal.uid, binding_name) do
      {:ok, %{binding: binding, config_key: config_key}}
    else
      {:error, :not_found} -> {:error, :agent_not_found}
      {:error, _reason} = error -> error
    end
  end

  def put_binding(_agent_uid, _adapter_id, _binding_name, _attrs),
    do: {:error, :invalid_signal_binding}

  @spec update_binding(String.t(), String.t(), String.t(), map()) ::
          {:ok, %{binding: Binding.t(), config_key: String.t()}} | {:error, term()}
  def update_binding(source_agent_uid, target_agent_uid, binding_name, attrs)
      when is_binary(source_agent_uid) and is_binary(target_agent_uid) and
             is_binary(binding_name) and is_map(attrs) do
    with {:ok, binding_name} <- normalize_binding_name(binding_name),
         {:ok, %{principal: source_principal}} <- Principals.get_agent(source_agent_uid),
         {:ok, %{principal: target_principal}} <- Principals.get_agent(target_agent_uid),
         %Binding{} = source_binding <-
           Repo.get_by(Binding, agent_uid: source_principal.uid, name: binding_name),
         {:ok, definition} <- Adapters.fetch(source_binding.adapter),
         {:ok, current_config} <- stored_binding_config(source_binding),
         {:ok, config_patch} <- binding_config(attrs),
         {:ok, normalized_config} <-
           validate_binding_config(
             definition,
             merge_binding_config(
               current_config,
               ConfigSecrets.preserve(definition.fields, config_patch, current_config)
             ),
             config_patch != %{}
           ),
         {:ok, application} <-
           resolve_platform_application(definition.config_module, normalized_config, :binding),
         {:ok, mode} <- group_message_mode(attrs, nil),
         :ok <- validate_supported_group_message_mode(definition, mode),
         {:ok, policy} <- group_message_policy(mode),
         {:ok, unmatched_sender_policy} <- unmatched_sender_policy(attrs, nil),
         {:ok, config_key} <-
           binding_config_key(definition, target_principal.uid, binding_name),
         {:ok, {binding, normalized_config}} <-
           persist_binding_update(
             definition,
             source_principal.uid,
             target_principal.uid,
             binding_name,
             current_config,
             normalized_config,
             application,
             config_key,
             policy,
             unmatched_sender_policy
           ),
         :ok <- maybe_handle_binding_saved(definition, binding, normalized_config),
         :ok <- Outbox.wake_blocked_for_binding(target_principal.uid, binding_name),
         :ok <- Actors.wake_blocked_reply_previews(target_principal.uid, binding_name) do
      {:ok, %{binding: binding, config_key: config_key}}
    else
      nil -> {:error, :binding_not_found}
      {:error, :not_found} -> {:error, :agent_not_found}
      {:error, _reason} = error -> error
    end
  end

  def update_binding(_source_agent_uid, _target_agent_uid, _binding_name, _attrs),
    do: {:error, :invalid_signal_binding}

  @spec get_binding_configuration(String.t(), String.t()) ::
          {:ok, %{binding: Binding.t(), config: map(), stored_secret_paths: [String.t()]}}
          | {:error, term()}
  def get_binding_configuration(agent_uid, binding_name)
      when is_binary(agent_uid) and is_binary(binding_name) do
    with {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
         %Binding{} = binding <-
           Repo.get_by(Binding, agent_uid: principal.uid, name: binding_name),
         {:ok, definition} <- Adapters.fetch(binding.adapter),
         {:ok, config} <- stored_binding_config(binding) do
      {config, stored_secret_paths} = ConfigSecrets.redact(definition.fields, config)

      {:ok,
       %{
         binding: binding,
         config: config,
         stored_secret_paths: stored_secret_paths
       }}
    else
      nil -> {:error, :binding_not_found}
      {:error, :not_found} -> {:error, :agent_not_found}
      {:error, _reason} = error -> error
    end
  end

  def get_binding_configuration(_agent_uid, _binding_name),
    do: {:error, :binding_not_found}

  @spec get_binding(String.t(), String.t()) :: {:ok, Binding.t()} | {:error, term()}
  def get_binding(agent_uid, binding_name) do
    case Repo.get_by(Binding, agent_uid: Utils.normalize_uid(agent_uid), name: binding_name) do
      %Binding{enabled: true, unavailable_reason: reason} when is_binary(reason) ->
        {:error, {:binding_unavailable, reason}}

      %Binding{enabled: true} = binding ->
        {:ok, binding}

      %Binding{enabled: false} ->
        {:error, :binding_disabled}

      nil ->
        {:error, :binding_not_found}
    end
  end

  @doc """
  Lists bindings across the deployment instance for the Console, including disabled
  bindings. An agent filter narrows the list without an existence check: an
  unknown agent reads as an empty list, not an error.
  """
  @spec list_bindings(String.t() | nil) :: {:ok, [Binding.t()]}
  def list_bindings(agent_uid \\ nil) do
    bindings =
      Binding
      |> maybe_where_agent(agent_uid)
      |> order_by([binding], asc: binding.agent_uid, asc: binding.adapter, asc: binding.name)
      |> Repo.all()

    {:ok, bindings}
  end

  defp maybe_where_agent(query, nil), do: query

  defp maybe_where_agent(query, agent_uid) when is_binary(agent_uid),
    do: where(query, [binding], binding.agent_uid == ^String.downcase(agent_uid))

  @spec list_agent_bindings(String.t(), keyword()) ::
          {:ok, [Binding.t()]} | {:error, term()}
  def list_agent_bindings(agent_uid, opts \\ [])

  def list_agent_bindings(agent_uid, opts) when is_binary(agent_uid) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid) do
      bindings =
        Binding
        |> where([binding], binding.agent_uid == ^principal.uid)
        |> order_by([binding], asc: binding.adapter, asc: binding.name)
        |> repo.all()

      {:ok, bindings}
    else
      {:error, :not_found} -> {:error, :agent_not_found}
      {:error, _reason} = error -> error
    end
  end

  def list_agent_bindings(_agent_uid, _opts), do: {:error, :agent_not_found}

  @spec disable_binding(String.t(), String.t()) :: {:ok, Binding.t()} | {:error, term()}
  def disable_binding(agent_uid, binding_name)
      when is_binary(agent_uid) and is_binary(binding_name) do
    Repo.transact(fn repo ->
      with {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
           %Binding{} = binding <- lock_binding(repo, principal.uid, binding_name) do
        binding
        |> Binding.changeset(%{enabled: false, unavailable_reason: nil})
        |> repo.update()
      else
        nil -> {:error, :binding_not_found}
        {:error, :not_found} -> {:error, :agent_not_found}
        {:error, _reason} = error -> error
      end
    end)
  end

  def disable_binding(_agent_uid, _binding_name), do: {:error, :binding_not_found}

  defp adapter_catalog(%Definition{} = definition) do
    with {:ok, fields} <- catalog_fields(definition.fields) do
      {:ok,
       %{
         adapter_id: definition.id,
         adapter_category: definition.adapter_category,
         plugin_id: definition.plugin_id,
         display_name: definition.display_name,
         fields: fields,
         group_message_mode_field:
           GroupMessageModes.field(definition.supported_group_message_modes),
         unmatched_sender_policy_field: UnmatchedSenderPolicies.field()
       }}
    end
  end

  # An identity-provider reference is served as a select over the configured
  # providers of its adapter plus the standalone choice. It is required only
  # while several providers exist; a single one is adopted by default. Without
  # any provider the field is not shown and the adapter default namespace
  # applies. See `Ankole.SignalsGateway.SubjectNamespace`.
  defp catalog_fields(fields) do
    with {:ok, groups} <-
           collect_ok(fields, fn
             %{type: "identity_provider"} = field ->
               with {:ok, provider_ids} <- identity_provider_ids(field) do
                 {:ok, identity_provider_select(field, provider_ids)}
               end

             field ->
               {:ok, [field]}
           end) do
      {:ok, List.flatten(groups)}
    end
  end

  defp collect_ok(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  defp identity_provider_select(_field, []), do: []

  defp identity_provider_select(field, provider_ids) do
    options =
      Enum.map(provider_ids, &%{value: &1, label: %{"default" => &1}}) ++
        [
          %{
            value: SubjectNamespace.standalone_reference(),
            label: %{
              "default" => "No identity provider (standalone namespace)",
              "zh-Hans-CN" => "不关联身份源（独立命名空间）"
            }
          }
        ]

    [
      field
      |> Map.drop([:identity_provider_adapter])
      |> Map.merge(%{
        type: "select",
        required: length(provider_ids) > 1,
        options: options
      })
    ]
  end

  defp identity_provider_ids(%{identity_provider_adapter: adapter_id}) do
    SubjectNamespace.provider_ids(adapter_id)
  end

  defp maybe_handle_binding_saved(%Definition{} = definition, %Binding{} = binding, config)
       when is_map(config) do
    case definition.binding_saved_module do
      module when is_atom(module) and not is_nil(module) ->
        case module.handle_binding_saved(binding, config) do
          :ok -> :ok
          {:ok, _result} -> :ok
          {:error, _reason} = error -> error
          other -> {:error, {:invalid_binding_saved_result, other}}
        end

      nil ->
        :ok
    end
  end

  defp binding_config(%{"config" => config}) when is_map(config), do: {:ok, config}
  defp binding_config(%{config: config}) when is_map(config), do: {:ok, config}
  defp binding_config(_attrs), do: {:error, :missing_config}

  defp group_message_mode(attrs, default) do
    case Map.get(attrs, :group_message_mode, Map.get(attrs, "group_message_mode")) do
      mode when is_binary(mode) and mode != "" -> {:ok, mode}
      nil when is_nil(default) -> {:ok, nil}
      nil -> {:ok, default}
      mode -> {:error, {:invalid_group_message_mode, mode}}
    end
  end

  defp group_message_policy(nil), do: {:ok, nil}
  defp group_message_policy(mode), do: GroupMessageModes.policy(mode)

  defp unmatched_sender_policy(attrs, default) do
    case Map.get(attrs, :unmatched_sender_policy, Map.get(attrs, "unmatched_sender_policy")) do
      value when is_binary(value) and value != "" -> UnmatchedSenderPolicies.policy(value)
      nil when is_nil(default) -> {:ok, nil}
      nil -> UnmatchedSenderPolicies.policy(default)
      value -> {:error, {:unknown_unmatched_sender_policy, value}}
    end
  end

  defp validate_supported_group_message_mode(%Definition{}, nil), do: :ok

  defp validate_supported_group_message_mode(%Definition{} = definition, mode) do
    case definition.supported_group_message_modes do
      modes when is_list(modes) ->
        case mode in modes do
          true -> :ok
          false -> {:error, {:unsupported_group_message_mode, definition.id, mode}}
        end

      _modes ->
        :ok
    end
  end

  # Enabling or moving a binding sends no config, so it keeps the reference
  # it has; only a config write must name a provider while several exist.
  defp validate_binding_config(%Definition{} = definition, config, check_references?) do
    with {:ok, normalized_config} <- validate_adapter_binding_config(definition, config) do
      if check_references?,
        do: validate_identity_provider_references(definition, normalized_config),
        else: {:ok, normalized_config}
    end
  end

  defp validate_adapter_binding_config(%Definition{} = definition, config) do
    case definition.config_module do
      nil ->
        {:ok, config}

      module when is_atom(module) ->
        module.validate_binding_config(config)
    end
  end

  # The subject namespace of a binding is the identity provider it references,
  # so chat senders and directory users resolve to one Principal. A missing
  # reference is ambiguous only while several providers exist; an unknown
  # reference is rejected so a typo cannot open a namespace of its own.
  defp validate_identity_provider_references(%Definition{fields: fields}, config) do
    fields
    |> Enum.filter(&(&1[:type] == "identity_provider"))
    |> Enum.reduce_while({:ok, config}, fn field, acc ->
      case validate_identity_provider_reference(field, Map.get(config, field.path)) do
        :ok -> {:cont, acc}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_identity_provider_reference(field, value) do
    with {:ok, provider_ids} <- identity_provider_ids(field) do
      standalone = SubjectNamespace.standalone_reference()

      cond do
        is_nil(value) and length(provider_ids) > 1 -> {:error, {:missing, field.path}}
        is_nil(value) -> :ok
        value == standalone -> :ok
        value in provider_ids -> :ok
        true -> {:error, {:invalid_enum, field.path, provider_ids ++ [standalone]}}
      end
    end
  end

  defp validate_binding_assignment(
         %Definition{} = definition,
         repo,
         agent_uid,
         binding_name,
         config
       ) do
    case definition.config_module do
      module when is_atom(module) and not is_nil(module) ->
        if function_exported?(module, :validate_binding_assignment, 4) do
          module.validate_binding_assignment(repo, agent_uid, binding_name, config)
        else
          :ok
        end

      nil ->
        :ok
    end
  end

  defp validate_application_bindings(
         %Definition{application_bindings: nil},
         _repo,
         _uid,
         _name,
         _config,
         _application
       ),
       do: :ok

  defp validate_application_bindings(
         %Definition{application_bindings: :one} = definition,
         repo,
         agent_uid,
         binding_name,
         config,
         application
       ) do
    repo.all(
      from binding in Binding,
        left_join: config in AppConfig,
        on:
          config.scope == "global" and
            binding.config_ref == fragment("'app-config://' || ?", config.key),
        where:
          binding.adapter == ^definition.id and binding.enabled == true and
            (binding.agent_uid != ^agent_uid or binding.name != ^binding_name),
        select: {binding, fragment("?->>'platform_application'", config.value)}
    )
    |> Enum.reduce_while(:ok, fn {binding, other_application}, :ok ->
      case validate_application_binding(
             repo,
             definition,
             binding,
             other_application,
             config,
             application
           ) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_application_binding(
         repo,
         definition,
         binding,
         other_application,
         config,
         application
       ) do
    # Public identity metadata cannot make an unreadable enabled binding safe.
    # Keep the existing configuration rejection before comparing applications.
    with {:ok, other} <- binding_config_in_tx(repo, binding, definition.config_module) do
      if other_application == application do
        {:error,
         {:platform_application_already_bound, application, binding.agent_uid, binding.name}}
      else
        validate_binding_pair(definition.config_module, binding, config, other)
      end
    else
      :error -> application_binding_config_missing(definition.id, binding)
      {:error, reason} -> application_binding_config_error(definition.id, binding, reason)
    end
  end

  defp validate_binding_pair(module, binding, config, other) do
    if function_exported?(module, :validate_binding_pair, 3),
      do: module.validate_binding_pair(binding, config, other),
      else: :ok
  end

  defp application_binding_config_missing("lark", binding),
    do: application_binding_config_error("lark", binding, :missing)

  defp application_binding_config_missing(adapter_id, binding),
    do:
      {:error,
       {Map.fetch!(@application_binding_config_errors, adapter_id), binding.agent_uid,
        binding.name}}

  defp application_binding_config_error(adapter_id, binding, reason),
    do:
      {:error,
       {Map.fetch!(@application_binding_config_errors, adapter_id), binding.agent_uid,
        binding.name, reason}}

  defp persist_binding_assignment(
         %Definition{} = definition,
         agent_uid,
         binding_name,
         normalized_config,
         application,
         config_key,
         policy,
         unmatched_sender_policy
       ) do
    case Repo.transact(fn repo ->
           with :ok <- validate_platform_application_in_tx(repo, application),
                :ok <-
                  validate_application_bindings(
                    definition,
                    repo,
                    agent_uid,
                    binding_name,
                    normalized_config,
                    application
                  ),
                :ok <-
                  validate_binding_assignment(
                    definition,
                    repo,
                    agent_uid,
                    binding_name,
                    normalized_config
                  ),
                {:ok, binding} <-
                  upsert_binding(repo, %{
                    agent_uid: agent_uid,
                    name: binding_name,
                    adapter: definition.id,
                    config_ref: "app-config://#{config_key}",
                    filters: %{},
                    unaddressed_group_message_policy: policy,
                    unmatched_sender_policy: unmatched_sender_policy,
                    enabled: true
                  }),
                {:ok, committed_config} <-
                  AppConfigure.put_global_by_key_in_tx(repo, config_key, normalized_config),
                :ok <- record_platform_application_in_tx(repo, committed_config, application) do
             {:ok, {binding, committed_config}}
           end
         end) do
      {:ok, {binding, committed_config}} ->
        AppConfigure.cache_committed_write(committed_config)
        {:ok, binding}

      {:error, _reason} = error ->
        error
    end
  end

  defp persist_binding_update(
         %Definition{} = definition,
         source_agent_uid,
         target_agent_uid,
         binding_name,
         current_config,
         normalized_config,
         application,
         config_key,
         policy,
         unmatched_sender_policy
       ) do
    case Repo.transact(fn repo ->
           with :ok <- validate_platform_application_in_tx(repo, application),
                %Binding{} = source_binding <- lock_binding(repo, source_agent_uid, binding_name),
                :ok <- ensure_binding_adapter(source_binding, definition.id),
                {:ok, locked_config} <- binding_config_in_tx(repo, source_binding),
                true <- locked_config == current_config,
                :ok <-
                  ensure_target_binding_available(
                    repo,
                    source_binding,
                    target_agent_uid,
                    binding_name
                  ),
                {:ok, _source_binding} <-
                  maybe_disable_source_binding(repo, source_binding, target_agent_uid),
                :ok <-
                  validate_application_bindings(
                    definition,
                    repo,
                    target_agent_uid,
                    binding_name,
                    normalized_config,
                    application
                  ),
                :ok <-
                  validate_binding_assignment(
                    definition,
                    repo,
                    target_agent_uid,
                    binding_name,
                    normalized_config
                  ),
                {:ok, binding} <-
                  upsert_binding(repo, %{
                    agent_uid: target_agent_uid,
                    name: binding_name,
                    adapter: definition.id,
                    config_ref: "app-config://#{config_key}",
                    filters: source_binding.filters,
                    unaddressed_group_message_policy:
                      policy || source_binding.unaddressed_group_message_policy,
                    unmatched_sender_policy:
                      unmatched_sender_policy || source_binding.unmatched_sender_policy,
                    enabled: true,
                    unavailable_reason: nil
                  }),
                {:ok, committed_config} <-
                  AppConfigure.put_global_by_key_in_tx(repo, config_key, normalized_config),
                :ok <- record_platform_application_in_tx(repo, committed_config, application) do
             {:ok, {binding, committed_config, normalized_config}}
           else
             nil -> {:error, :binding_not_found}
             false -> {:error, :binding_changed}
             {:error, _reason} = error -> error
           end
         end) do
      {:ok, {binding, committed_config, normalized_config}} ->
        AppConfigure.cache_committed_write(committed_config)
        {:ok, {binding, normalized_config}}

      {:error, _reason} = error ->
        error
    end
  end

  defp binding_config_in_tx(repo, %Binding{config_ref: "app-config://" <> key}) do
    case AppConfigure.get_global_by_key_in_tx(repo, key) do
      {:ok, config} when is_map(config) -> {:ok, config}
      {:ok, _config} -> {:error, :binding_config_unavailable}
      :error -> {:error, :binding_config_unavailable}
      {:error, _reason} = error -> error
    end
  end

  defp binding_config_in_tx(_repo, %Binding{}), do: {:error, :binding_config_unavailable}

  @doc false
  @spec stored_binding_config(Binding.t()) :: {:ok, map()} | {:error, term()}
  def stored_binding_config(%Binding{config_ref: "app-config://" <> key}) do
    case AppConfigure.get_by_key(key) do
      {:ok, config} when is_map(config) -> {:ok, config}
      {:ok, _config} -> {:error, :binding_config_unavailable}
      :error -> {:error, :binding_config_unavailable}
      {:error, _reason} = error -> error
    end
  end

  def stored_binding_config(%Binding{}), do: {:error, :binding_config_unavailable}

  defp merge_binding_config(current, patch) when is_map(current) and is_map(patch) do
    Map.merge(current, patch, fn _key, current_value, patch_value ->
      if is_map(current_value) and is_map(patch_value) do
        merge_binding_config(current_value, patch_value)
      else
        patch_value
      end
    end)
  end

  defp ensure_binding_adapter(%Binding{adapter: adapter}, adapter), do: :ok
  defp ensure_binding_adapter(%Binding{}, _adapter), do: {:error, :binding_conflict}

  defp ensure_target_binding_available(
         _repo,
         %Binding{agent_uid: agent_uid},
         agent_uid,
         _binding_name
       ),
       do: :ok

  defp ensure_target_binding_available(repo, %Binding{}, target_agent_uid, binding_name) do
    case lock_binding(repo, target_agent_uid, binding_name) do
      nil -> :ok
      %Binding{enabled: false} -> :ok
      %Binding{enabled: true} -> {:error, :binding_target_conflict}
    end
  end

  defp maybe_disable_source_binding(
         _repo,
         %Binding{agent_uid: agent_uid} = source_binding,
         agent_uid
       ),
       do: {:ok, source_binding}

  defp maybe_disable_source_binding(repo, %Binding{} = source_binding, _target_agent_uid) do
    source_binding
    |> Binding.changeset(%{enabled: false, unavailable_reason: nil})
    |> repo.update()
  end

  @doc "Adapter-owned identity resolution; callers run this before acquiring database locks."
  def resolve_platform_application(
        _module,
        %{"sync" => %{"contacts" => false}},
        :identity_provider
      ),
      do: {:ok, nil}

  def resolve_platform_application(module, config, _source) when is_atom(module) do
    if function_exported?(module, :platform_application, 1),
      do: module.platform_application(config),
      else: {:error, :platform_application_identity_unavailable}
  end

  @doc false
  def validate_platform_application_in_tx(_repo, nil), do: :ok

  def validate_platform_application_in_tx(repo, application) when is_binary(application) do
    tenant_id = Repo.tenant_id!()

    with {:ok, _} <-
           SQL.query(repo, "SELECT pg_advisory_xact_lock(hashtext($1::text))", [
             "signals_gateway:application:" <> application
           ]) do
      conflict =
        Repo.across_tenants(fn ->
          repo.exists?(
            from row in Ankole.AppConfigure.AppConfig,
              left_join: binding in Binding,
              on:
                row.scope == "global" and
                  binding.config_ref == fragment("'app-config://' || ?", row.key),
              where:
                fragment("?->>'platform_application' = ?", row.value, ^application) and
                  (row.tenant_id != ^tenant_id or binding.tenant_id != ^tenant_id)
          )
        end)

      if conflict, do: {:error, :platform_app_bound_to_another_tenant}, else: :ok
    end
  end

  # Public identity metadata belongs to the same durable config row as its
  # encrypted credentials. It is never accepted from an API request.
  @doc false
  def record_platform_application_in_tx(repo, {_parsed, scope, key}, application) do
    case SQL.query(
           repo,
           "UPDATE app_configurations SET value = value || $1::jsonb WHERE scope = $2 AND key = $3",
           [%{"platform_application" => application}, scope, key]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp binding_config_key(%Definition{} = definition, agent_uid, binding_name) do
    case definition.config_module do
      module when is_atom(module) and not is_nil(module) ->
        if function_exported?(module, :binding_config_key, 2) do
          case module.binding_config_key(agent_uid, binding_name) do
            key when is_binary(key) and key != "" -> {:ok, key}
            key -> {:error, {:invalid_adapter_config_key, definition.id, key}}
          end
        else
          binding_config_key_from_pattern(definition, agent_uid, binding_name)
        end

      nil ->
        binding_config_key_from_pattern(definition, agent_uid, binding_name)
    end
  end

  defp binding_config_key_from_pattern(definition, agent_uid, binding_name) do
    case definition.config_key_pattern do
      pattern when is_binary(pattern) ->
        key =
          pattern
          |> String.replace("<agent_uid>", agent_uid)
          |> String.replace("<id>", binding_name)

        {:ok, key}

      _pattern ->
        {:error, {:missing_adapter_config_key_pattern, definition.id}}
    end
  end

  defp normalize_binding_name(binding_name) do
    case String.trim(binding_name) do
      "" -> {:error, :invalid_signal_binding}
      normalized -> {:ok, normalized}
    end
  end

  defp lock_binding(repo, agent_uid, binding_name) do
    Binding
    |> where([binding], binding.agent_uid == ^agent_uid and binding.name == ^binding_name)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp available_bindings_query do
    Binding
    |> where([binding], binding.enabled == true)
    |> where([binding], is_nil(binding.unavailable_reason))
  end

  @spec list_enabled_bindings(String.t(), keyword()) :: [Binding.t()]
  def list_enabled_bindings(adapter, opts \\ []) when is_binary(adapter) do
    repo = Keyword.get(opts, :repo, Repo)

    available_bindings_query()
    |> where([binding], binding.adapter == ^adapter)
    |> order_by([binding], asc: binding.agent_uid, asc: binding.name)
    |> repo.all()
  end

  @spec binding_config(Binding.t(), module()) :: {:ok, map()} | :error | {:error, term()}
  def binding_config(%Binding{config_ref: "app-config://" <> key}, config_module) do
    with {:ok, value} <- AppConfigure.get_by_key(key) do
      config_module.validate_binding_config(value)
    end
  end

  def binding_config(%Binding{}, _config_module), do: {:error, :invalid_config_ref}

  @spec binding_config_in_tx(module(), Binding.t(), module()) ::
          {:ok, map()} | :error | {:error, term()}
  def binding_config_in_tx(repo, %Binding{config_ref: "app-config://" <> key}, config_module) do
    with {:ok, value} <- AppConfigure.get_global_by_key_in_tx(repo, key) do
      config_module.validate_binding_config(value)
    end
  end

  def binding_config_in_tx(_repo, %Binding{}, _config_module),
    do: {:error, :invalid_config_ref}

  @spec outbox_config(OutboxEntry.t(), module()) :: {:ok, map()} | {:error, term()}
  def outbox_config(%OutboxEntry{} = outbox, config_module) do
    case Repo.get_by(Binding, agent_uid: outbox.agent_uid, name: outbox.binding_name) do
      %Binding{config_ref: nil} ->
        {:error, :binding_config_ref_missing}

      %Binding{} = binding ->
        case binding_config(binding, config_module) do
          :error -> {:error, :binding_config_not_found}
          result -> result
        end

      nil ->
        {:error, :binding_not_found}
    end
  end
end
