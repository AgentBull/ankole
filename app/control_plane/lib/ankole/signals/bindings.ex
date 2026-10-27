defmodule Ankole.Signals.Bindings do
  @moduledoc """
  Owns Signal Binding configuration, assignment, and availability.

  `put_binding/4` and `update_binding/4` validate adapter configuration and
  persist the Binding with its configuration. After commit they refresh the
  cache, run the adapter save hook, and wake blocked delivery and previews.
  A save-hook error does not roll back the committed configuration.

  Ingress reads available Bindings. Console repair and delivery reads retain
  their separate configuration contracts. See `docs/design-docs/Signals.md`.
  """

  import Ash.Expr, only: [expr: 1]
  require Ash.Query

  alias Ankole.Conversations.Delivery.PreviewStates
  alias Ankole.Repo
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.AppConfig
  alias Ankole.Plugins.ConfigSecrets
  alias Ankole.Principals

  alias Ankole.Signals.{
    Adapters,
    Binding,
    CloudBindings,
    GroupMessageModes,
    SubjectNamespace,
    UnmatchedSenderPolicies
  }

  alias Ankole.Signals.Adapters.Definition
  alias Ankole.Conversations.Delivery.Intent
  alias Ankole.Conversations.Delivery

  @doc "Builds a durable adapter configuration key for one Agent and binding."
  @spec binding_config_key(String.t(), String.t(), String.t()) :: String.t()
  def binding_config_key(prefix, agent_uid, binding_name)
      when is_binary(prefix) and is_binary(agent_uid) and is_binary(binding_name) do
    digest =
      [agent_uid, binding_name]
      |> Ankole.JSON.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    prefix <> "." <> digest
  end

  @application_binding_config_errors %{
    "line" => :line_binding_config_unavailable,
    "lark" => :lark_binding_config_unavailable,
    "email" => :email_binding_config_unavailable,
    "whatsapp" => :whatsapp_binding_config_unavailable
  }

  @doc false
  def delete_agent_config_rows_in_tx(uid) do
    Binding
    |> Ash.Query.filter(agent_uid == ^uid)
    |> Ash.Query.select([:config_ref])
    |> Ankole.Ash.read!()
    |> Enum.each(fn
      %Binding{config_ref: "app-config://" <> key = reference} ->
        if not config_ref_shared?(reference, uid) do
          case AppConfigure.delete_global_by_key_in_tx(key) do
            :ok -> :ok
            {:error, error} -> Repo.rollback(error)
          end
        end

      %Binding{} ->
        :ok
    end)

    :ok
  end

  # A global configuration row stays while a Binding of another Agent, in any
  # tenant, references it.
  defp config_ref_shared?(reference, uid) do
    Repo.across_tenants(fn ->
      Binding
      |> Ash.Query.for_read(:lookup_across_tenants)
      |> Ash.Query.filter(config_ref == ^reference and agent_uid != ^uid)
      |> Ankole.Ash.exists?()
    end)
  end

  def put_binding(agent_uid, "cloudevents", binding_name, attrs) when is_map(attrs),
    do: CloudBindings.put(agent_uid, binding_name, attrs)

  @spec put_binding(String.t(), String.t(), String.t(), map()) ::
          {:ok, %{binding: Binding.t(), config_key: String.t()}} | {:error, term()}
  def put_binding(agent_uid, adapter_id, binding_name, attrs)
      when is_binary(adapter_id) and is_binary(binding_name) and is_map(attrs) do
    with {:ok, binding_name} <- normalize_name(binding_name),
         {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
         {:ok, definition} <- Adapters.fetch(adapter_id),
         {:ok, config} <- extract_binding_config(attrs),
         {:ok, normalized_config} <- validate_binding_config(definition, config, true),
         {:ok, application} <-
           resolve_platform_application(definition.config_module, normalized_config, :binding),
         {:ok, mode} <- group_message_mode(attrs, GroupMessageModes.default_mode()),
         :ok <- validate_supported_group_message_mode(definition, mode),
         {:ok, policy} <- GroupMessageModes.policy(mode),
         {:ok, unmatched_sender_policy} <-
           unmatched_sender_policy(attrs, UnmatchedSenderPolicies.default_value()),
         {:ok, config_key} <-
           resolve_binding_config_key(
             definition,
             principal.uid,
             binding_name
           ),
         {:ok, {binding, _committed_config}} <-
           Repo.transact_top_level(
             fn ->
               assign_in_tx(%{
                 definition: definition,
                 agent_uid: principal.uid,
                 binding_name: binding_name,
                 config: normalized_config,
                 application: application,
                 config_key: config_key,
                 filters: Map.fetch(Ankole.Attrs.normalize_external_attrs(attrs), "filters"),
                 policy: policy,
                 unmatched_sender_policy: unmatched_sender_policy
               })
             end,
             after_commit: &cache_committed_assignment/1
           ) do
      publish_binding(definition, binding, normalized_config)
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
    case Ankole.Signals.get_binding!(
           Ankole.PrincipalKey.canonicalize(source_agent_uid),
           binding_name
         ) do
      %Binding{adapter: "cloudevents"} = binding ->
        CloudBindings.update(binding, target_agent_uid, binding_name, attrs)

      _ ->
        update_host_binding(source_agent_uid, target_agent_uid, binding_name, attrs)
    end
  end

  def update_binding(_source_agent_uid, _target_agent_uid, _binding_name, _attrs),
    do: {:error, :invalid_signal_binding}

  defp update_host_binding(source_agent_uid, target_agent_uid, binding_name, attrs) do
    with {:ok, binding_name} <- normalize_name(binding_name),
         {:ok, %{principal: source_principal}} <- Principals.get_agent(source_agent_uid),
         {:ok, %{principal: target_principal}} <- Principals.get_agent(target_agent_uid),
         %Binding{} = source_binding <-
           Ankole.Signals.get_binding!(source_principal.uid, binding_name),
         {:ok, definition} <- Adapters.fetch(source_binding.adapter),
         {:ok, current_config} <- stored_binding_config(source_binding),
         {:ok, config_patch} <- extract_binding_config(attrs),
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
           resolve_binding_config_key(
             definition,
             target_principal.uid,
             binding_name
           ),
         {:ok, {binding, _committed_config, normalized_config}} <-
           Repo.transact_top_level(
             fn ->
               reassign_in_tx(%{
                 definition: definition,
                 source_agent_uid: source_principal.uid,
                 agent_uid: target_principal.uid,
                 binding_name: binding_name,
                 current_config: current_config,
                 config: normalized_config,
                 application: application,
                 config_key: config_key,
                 filters: Map.fetch(Ankole.Attrs.normalize_external_attrs(attrs), "filters"),
                 policy: policy,
                 unmatched_sender_policy: unmatched_sender_policy
               })
             end,
             after_commit: &cache_committed_assignment/1
           ) do
      publish_binding(definition, binding, normalized_config)
      {:ok, %{binding: binding, config_key: config_key}}
    else
      nil -> {:error, :binding_not_found}
      {:error, :not_found} -> {:error, :agent_not_found}
      {:error, _reason} = error -> error
    end
  end

  defdelegate get_binding_configuration(agent_uid, binding_name),
    to: Ankole.Signals.BindingCatalog

  @spec get_binding(String.t(), String.t()) :: {:ok, Binding.t()} | {:error, term()}
  def get_binding(agent_uid, binding_name) when is_binary(agent_uid) do
    case Ankole.Signals.get_binding!(Ankole.PrincipalKey.canonicalize(agent_uid), binding_name) do
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

  def get_binding(_agent_uid, _binding_name), do: {:error, :binding_not_found}

  @doc """
  Lists bindings across the deployment instance for the Console, including disabled
  bindings. An agent filter narrows the list without an existence check: an
  unknown agent reads as an empty list, not an error.
  """
  @spec list_bindings(String.t() | nil) :: {:ok, [Binding.t()]}
  def list_bindings(agent_uid \\ nil) do
    bindings =
      binding_query()
      |> maybe_where_agent(agent_uid)
      |> Ash.Query.sort(agent_uid: :asc, adapter: :asc, name: :asc)
      |> Ankole.Ash.read!()

    {:ok, bindings}
  end

  defp maybe_where_agent(query, nil), do: query

  defp maybe_where_agent(query, uid) when is_binary(uid) do
    uid = String.downcase(uid)
    Ash.Query.filter(query, agent_uid == ^uid)
  end

  @spec list_agent_bindings(String.t()) ::
          {:ok, [Binding.t()]} | {:error, term()}
  def list_agent_bindings(agent_uid) when is_binary(agent_uid) do
    with {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid) do
      bindings =
        binding_query()
        |> Ash.Query.filter(agent_uid == ^principal.uid)
        |> Ash.Query.sort(adapter: :asc, name: :asc)
        |> Ankole.Ash.read!()

      {:ok, bindings}
    else
      {:error, :not_found} -> {:error, :agent_not_found}
      {:error, _reason} = error -> error
    end
  end

  def list_agent_bindings(_agent_uid), do: {:error, :agent_not_found}

  @spec disable_binding(String.t(), String.t()) :: {:ok, Binding.t()} | {:error, term()}
  def disable_binding(agent_uid, binding_name)
      when is_binary(agent_uid) and is_binary(binding_name),
      do: Repo.transact_top_level(fn -> disable_binding_in_tx(agent_uid, binding_name) end)

  def disable_binding(_agent_uid, _binding_name), do: {:error, :binding_not_found}

  @doc false
  def disable_binding_in_tx(agent_uid, binding_name) do
    with {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
         %Binding{} = binding <- lock_binding(principal.uid, binding_name) do
      Ankole.Ash.update(binding, :disable, %{})
    else
      nil -> {:error, :binding_not_found}
      {:error, :not_found} -> {:error, :agent_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp publish_binding(definition, binding, config) do
    for {operation, callback} <- [
          {:adapter_saved, fn -> maybe_handle_binding_saved(definition, binding, config) end},
          {:wake_delivery,
           fn -> Delivery.wake_blocked_for_binding(binding.agent_uid, binding.name) end},
          {:wake_preview, fn -> PreviewStates.wake_blocked(binding.agent_uid, binding.name) end}
        ] do
      try do
        case callback.() do
          :ok -> :ok
          {:error, reason} -> log_publication_failure(binding, operation, :error, reason, [])
        end
      rescue
        error -> log_publication_failure(binding, operation, :error, error, __STACKTRACE__)
      catch
        kind, reason -> log_publication_failure(binding, operation, kind, reason, __STACKTRACE__)
      end
    end

    :ok
  end

  defp log_publication_failure(binding, operation, kind, reason, stacktrace) do
    Ankole.Logging.warning(
      "signals.binding_publication_failed",
      "Signal Binding was saved, but publication failed",
      Ankole.Logging.failure_fields(kind, reason, stacktrace)
      |> Map.merge(%{
        agent_uid: binding.agent_uid,
        binding_name: binding.name,
        operation: operation
      })
    )
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

  @doc false
  def extract_binding_config(%{"config" => config}) when is_map(config), do: {:ok, config}
  def extract_binding_config(%{config: config}) when is_map(config), do: {:ok, config}
  def extract_binding_config(_attrs), do: {:error, :missing_config}

  defp group_message_mode(attrs, default) do
    case Ankole.Attrs.get(attrs, :group_message_mode) do
      mode when is_binary(mode) and mode != "" -> {:ok, mode}
      nil when is_nil(default) -> {:ok, nil}
      nil -> {:ok, default}
      mode -> {:error, {:invalid_group_message_mode, mode}}
    end
  end

  defp group_message_policy(nil), do: {:ok, nil}
  defp group_message_policy(mode), do: GroupMessageModes.policy(mode)

  defp unmatched_sender_policy(attrs, default) do
    case Ankole.Attrs.get(attrs, :unmatched_sender_policy) do
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
    with {:ok, provider_ids} <- SubjectNamespace.provider_ids(field.identity_provider_adapter) do
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
         agent_uid,
         binding_name,
         config
       ) do
    case definition.config_module do
      module when is_atom(module) and not is_nil(module) ->
        if function_exported?(module, :validate_binding_assignment, 3) do
          module.validate_binding_assignment(agent_uid, binding_name, config)
        else
          :ok
        end

      nil ->
        :ok
    end
  end

  defp validate_application_bindings(
         %Definition{application_bindings: nil},
         _uid,
         _name,
         _config,
         _application
       ),
       do: :ok

  defp validate_application_bindings(
         %Definition{application_bindings: :one} = definition,
         agent_uid,
         binding_name,
         config,
         application
       ) do
    bindings =
      Binding
      |> Ash.Query.filter(
        adapter == ^definition.id and enabled == true and
          (agent_uid != ^agent_uid or name != ^binding_name)
      )
      |> Ankole.Ash.read!()

    applications = config_applications(bindings)

    bindings
    |> Enum.map(&{&1, Map.get(applications, &1.config_ref)})
    |> Enum.reduce_while(:ok, fn {binding, other_application}, :ok ->
      case validate_application_binding(
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

  # Gives the platform application of each global configuration that a
  # Binding references.
  defp config_applications(bindings) do
    keys = for %Binding{config_ref: "app-config://" <> key} <- bindings, do: key

    {:ok, configs} =
      AppConfigure.list_site_configs(
        query: [
          filter: [scope: "global", key: [in: keys]],
          calculate:
            {:platform_application, :string, expr(fragment("?->>'platform_application'", value))}
        ]
      )

    Map.new(configs, &{"app-config://" <> &1.key, &1.calculations[:platform_application]})
  end

  defp validate_application_binding(
         definition,
         binding,
         other_application,
         config,
         application
       ) do
    # Public identity metadata cannot make an unreadable enabled binding safe.
    # Keep the existing configuration rejection before comparing applications.
    with {:ok, other} <- binding_config_in_tx(binding, definition.config_module) do
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

  @doc false
  def assign_in_tx(assignment) do
    %{definition: definition, agent_uid: agent_uid, binding_name: binding_name} = assignment

    with :ok <- validate_platform_application_in_tx(assignment.application),
         :ok <-
           validate_application_bindings(
             definition,
             agent_uid,
             binding_name,
             assignment.config,
             assignment.application
           ),
         :ok <-
           validate_binding_assignment(
             definition,
             agent_uid,
             binding_name,
             assignment.config
           ),
         previous <- lock_binding(agent_uid, binding_name),
         {:ok, binding} <-
           enable_in_tx(
             %{
               agent_uid: agent_uid,
               name: binding_name,
               adapter: definition.id,
               config_ref: "app-config://#{assignment.config_key}",
               filters: binding_filters(assignment.filters, previous, definition.id),
               unaddressed_group_message_policy: assignment.policy,
               unmatched_sender_policy: assignment.unmatched_sender_policy,
               enabled: true
             },
             previous
           ),
         {:ok, committed_config} <-
           AppConfigure.put_global_by_key_in_tx(assignment.config_key, assignment.config),
         :ok <-
           record_platform_application_in_tx(committed_config, assignment.application) do
      {:ok, {binding, committed_config}}
    end
  end

  @doc false
  def reassign_in_tx(assignment) do
    %{
      definition: definition,
      source_agent_uid: source_agent_uid,
      agent_uid: target_agent_uid,
      binding_name: binding_name
    } = assignment

    with :ok <- validate_platform_application_in_tx(assignment.application),
         {:ok, source_binding} <-
           lock_binding_update_in_tx(
             source_agent_uid,
             target_agent_uid,
             binding_name,
             definition.id,
             assignment.current_config
           ),
         {:ok, _source_binding} <- maybe_disable_source_binding(source_binding, target_agent_uid),
         :ok <-
           validate_application_bindings(
             definition,
             target_agent_uid,
             binding_name,
             assignment.config,
             assignment.application
           ),
         :ok <-
           validate_binding_assignment(
             definition,
             target_agent_uid,
             binding_name,
             assignment.config
           ),
         {:ok, binding} <-
           enable_in_tx(
             %{
               agent_uid: target_agent_uid,
               name: binding_name,
               adapter: definition.id,
               config_ref: "app-config://#{assignment.config_key}",
               filters: binding_filters(assignment.filters, source_binding, definition.id),
               unaddressed_group_message_policy:
                 assignment.policy || source_binding.unaddressed_group_message_policy,
               unmatched_sender_policy:
                 assignment.unmatched_sender_policy || source_binding.unmatched_sender_policy,
               enabled: true,
               unavailable_reason: nil
             },
             source_binding
           ),
         {:ok, committed_config} <-
           AppConfigure.put_global_by_key_in_tx(assignment.config_key, assignment.config),
         :ok <-
           record_platform_application_in_tx(committed_config, assignment.application) do
      {:ok, {binding, committed_config, assignment.config}}
    end
  end

  defp binding_filters(:error, %{adapter: adapter, filters: filters}, adapter), do: filters
  defp binding_filters(:error, _binding, _adapter), do: %{}
  defp binding_filters({:ok, filters}, _binding, _adapter), do: filters

  @doc false
  def enable_in_tx(attrs),
    do: enable_in_tx(attrs, lock_binding(attrs.agent_uid, attrs.name))

  @doc false
  def enable_in_tx(attrs, previous) do
    admission =
      case previous do
        %Binding{enabled: true} -> :ok
        _ -> Ankole.Plugins.Hook.before_commit_in_tx(:enable_signal_binding, attrs)
      end

    with :ok <- admission, do: Ankole.Ash.create(Binding, :put, attrs)
  end

  @doc "Refreshes the configuration cache after a committed Binding assignment."
  def cache_committed_assignment(result),
    do: AppConfigure.cache_committed_write(elem(result, 1))

  @doc false
  def lock_binding_update_in_tx(source_uid, target_uid, name, adapter, current_config) do
    with %Binding{} = binding <- lock_binding(source_uid, name),
         :ok <- ensure_binding_adapter(binding, adapter),
         {:ok, locked_config} <- binding_config_in_tx(binding),
         true <- locked_config == current_config,
         :ok <- ensure_target_binding_available(binding, target_uid, name) do
      {:ok, binding}
    else
      nil -> {:error, :binding_not_found}
      false -> {:error, :binding_changed}
      {:error, _} = error -> error
    end
  end

  defp binding_config_in_tx(%Binding{adapter: "cloudevents"} = binding),
    do: CloudBindings.stored_config(binding)

  defp binding_config_in_tx(%Binding{config_ref: "app-config://" <> key}) do
    case AppConfigure.get_global_by_key_in_tx(key) do
      {:ok, config} when is_map(config) -> {:ok, config}
      {:ok, _config} -> {:error, :binding_config_unavailable}
      :error -> {:error, :binding_config_unavailable}
      {:error, _reason} = error -> error
    end
  end

  defp binding_config_in_tx(%Binding{}), do: {:error, :binding_config_unavailable}

  @doc false
  @spec stored_binding_config(Binding.t()) :: {:ok, map()} | {:error, term()}
  def stored_binding_config(
        %Binding{adapter: "cloudevents", config_ref: "webhook-endpoint://" <> _id} = binding
      ),
      do: CloudBindings.stored_config(binding)

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
         %Binding{agent_uid: agent_uid},
         agent_uid,
         _binding_name
       ),
       do: :ok

  defp ensure_target_binding_available(%Binding{}, target_agent_uid, binding_name) do
    case lock_binding(target_agent_uid, binding_name) do
      nil -> :ok
      %Binding{enabled: false} -> :ok
      %Binding{enabled: true} -> {:error, :binding_target_conflict}
    end
  end

  defp maybe_disable_source_binding(%Binding{agent_uid: agent_uid} = source_binding, agent_uid),
    do: {:ok, source_binding}

  defp maybe_disable_source_binding(%Binding{} = source_binding, _target_agent_uid),
    do: Ankole.Ash.update(source_binding, :disable, %{})

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
  def validate_platform_application_in_tx(nil), do: :ok

  def validate_platform_application_in_tx(application) when is_binary(application) do
    tenant_id = Repo.tenant_id!()

    with {:ok, _} <-
           Ankole.AdvisoryLock.lock(Repo, "signals:application:" <> application) do
      conflict =
        AppConfigure.platform_application_in_other_tenant?(application, tenant_id) or
          site_application_bound_in_other_tenant?(application, tenant_id)

      if conflict, do: {:error, :platform_app_bound_to_another_tenant}, else: :ok
    end
  end

  # A global configuration that names the application is in use by the
  # Bindings that reference it.
  defp site_application_bound_in_other_tenant?(application, tenant_id) do
    {:ok, configs} =
      AppConfigure.list_site_configs(
        query: [
          filter: expr(fragment("?->>'platform_application' = ?", value, ^application)),
          select: [:key]
        ]
      )

    references = Enum.map(configs, &("app-config://" <> &1.key))

    references != [] and
      Repo.across_tenants(fn ->
        Binding
        |> Ash.Query.for_read(:lookup_across_tenants)
        |> Ash.Query.filter(config_ref in ^references and tenant_id != ^tenant_id)
        |> Ankole.Ash.exists?()
      end)
  end

  # Public identity metadata belongs to the same durable config row as its
  # encrypted credentials. It is never accepted from an API request.
  @doc false
  def record_platform_application_in_tx({_parsed, scope, key}, application) do
    {get, record} =
      case AppConfig.for_scope(scope) do
        AppConfig ->
          {&AppConfigure.get_app_config/2, &AppConfigure.record_platform_application_app_config/2}

        _site_config ->
          {&AppConfigure.get_site_config/2,
           &AppConfigure.record_platform_application_site_config/2}
      end

    case get.(scope, key) do
      {:ok, nil} ->
        {:error, :configuration_not_found}

      {:ok, config} ->
        with {:ok, _config} <- record.(config, %{application: application}), do: :ok

      {:error, _error} = error ->
        error
    end
  end

  @doc false
  def normalize_name(binding_name) do
    case String.trim(binding_name) do
      "" -> {:error, :invalid_signal_binding}
      normalized -> {:ok, normalized}
    end
  end

  defp lock_binding(agent_uid, binding_name) do
    Binding
    |> Ash.Query.filter(agent_uid == ^agent_uid and name == ^binding_name)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
  end

  # A caller that selected all tenants reads the Bindings of every tenant.
  defp binding_query do
    action = if Repo.across_tenants?(), do: :lookup_across_tenants, else: :read
    Ash.Query.for_read(Binding, action)
  end

  @spec list_enabled_bindings(String.t()) :: [Binding.t()]
  def list_enabled_bindings(adapter) when is_binary(adapter) do
    binding_query()
    |> Ash.Query.filter(enabled == true and is_nil(unavailable_reason) and adapter == ^adapter)
    |> Ash.Query.sort(agent_uid: :asc, name: :asc)
    |> Ankole.Ash.read!()
  end

  @spec binding_config(Binding.t(), module()) :: {:ok, map()} | :error | {:error, term()}
  def binding_config(%Binding{config_ref: "app-config://" <> key}, config_module) do
    with {:ok, value} <- AppConfigure.get_by_key(key) do
      config_module.validate_binding_config(value)
    end
  end

  def binding_config(%Binding{}, _config_module), do: {:error, :invalid_config_ref}

  @spec binding_config_in_tx(Binding.t(), module()) ::
          {:ok, map()} | :error | {:error, term()}
  def binding_config_in_tx(%Binding{config_ref: "app-config://" <> key}, config_module) do
    with {:ok, value} <- AppConfigure.get_global_by_key_in_tx(key) do
      config_module.validate_binding_config(value)
    end
  end

  def binding_config_in_tx(%Binding{}, _config_module),
    do: {:error, :invalid_config_ref}

  @spec delivery_config(Intent.t(), module()) :: {:ok, map()} | {:error, term()}
  def delivery_config(%Intent{} = intent, config_module) do
    case Ankole.Signals.get_binding!(intent.agent_uid, intent.binding_name) do
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

  defdelegate list_adapters(), to: Ankole.Signals.BindingCatalog

  defp resolve_binding_config_key(%Definition{} = definition, agent_uid, binding_name) do
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
end
