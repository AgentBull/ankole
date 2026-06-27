defmodule Ankole.Plugins.Spec do
  @moduledoc """
  Validates a plugin module's callbacks into a normalized `Spec` struct.

  This is the gate that turns a discovered module into a usable plugin. It runs
  at boot (via the registry), so validation is strict and fail-fast: every
  callback value is checked, and for known subsystem contracts the declared
  adapter modules are checked to actually export the callbacks that contract
  requires. A plugin that mis-declares an adapter fails Ankole startup here
  rather than crashing later when a subsystem first tries to invoke it.
  """

  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.PatternDefinition

  # Only api_version 1 exists today; a plugin declaring anything else is rejected
  # so an incompatible future plugin cannot load against an old runtime.
  @api_version 1
  # Plugin/adapter ids are lowercase slugs. Contract ids additionally allow dots
  # so subsystem contracts can be namespaced, e.g. "signals_gateway.adapter".
  @id_pattern ~r/\A[a-z][a-z0-9_-]*\z/
  @contract_id_pattern ~r/\A[a-z][a-z0-9_.-]*\z/

  @enforce_keys [:module, :id, :api_version]
  defstruct [
    :module,
    :id,
    :api_version,
    :display_name,
    :description,
    app_config_definitions: [],
    app_config_patterns: [],
    setup_metadata: [],
    adapter_declarations: [],
    children: []
  ]

  @type localized_text :: Ankole.Plugins.Plugin.localized_text()
  @type t :: %__MODULE__{
          module: module(),
          id: String.t(),
          api_version: pos_integer(),
          display_name: localized_text() | nil,
          description: localized_text() | nil,
          app_config_definitions: [Definition.t()],
          app_config_patterns: [PatternDefinition.t()],
          setup_metadata: [map()],
          adapter_declarations: [map()],
          children: [Supervisor.child_spec()]
        }

  @doc """
  Builds a normalized plugin spec from a loaded plugin module.

  Required identity callbacks must be present and valid; every optional callback
  defaults to empty/`nil` when the module does not export it. Errors are wrapped
  with the offending module so a boot failure points at the responsible plugin.
  """
  @spec from_module(module()) :: {:ok, t()} | {:error, term()}
  def from_module(module) when is_atom(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         :ok <- require_callback(module, :plugin_id, 0),
         :ok <- require_callback(module, :api_version, 0),
         {:ok, id} <- normalize_id(module.plugin_id()),
         {:ok, api_version} <- normalize_api_version(module.api_version()),
         {:ok, display_name} <- optional_localized_text(module, :display_name),
         {:ok, description} <- optional_localized_text(module, :description),
         {:ok, definitions} <- optional_list(module, :app_config_definitions, &definition?/1),
         {:ok, patterns} <- optional_list(module, :app_config_patterns, &pattern?/1),
         {:ok, setup_metadata} <- optional_list(module, :setup_metadata, &map?/1),
         {:ok, adapter_declarations} <- optional_adapter_declarations(module),
         {:ok, children} <- optional_children(module) do
      {:ok,
       %__MODULE__{
         module: module,
         id: id,
         api_version: api_version,
         display_name: display_name,
         description: description,
         app_config_definitions: definitions,
         app_config_patterns: patterns,
         setup_metadata: setup_metadata,
         adapter_declarations: adapter_declarations,
         children: children
       }}
    else
      {:error, reason} -> {:error, {module, reason}}
      {:error, _what, _reason} -> {:error, {module, :not_loaded}}
    end
  end

  def from_module(module), do: {:error, {module, :invalid_module}}

  @doc """
  Returns whether a value is a valid plugin id.
  """
  @spec valid_id?(term()) :: boolean()
  def valid_id?(id) when is_binary(id), do: Regex.match?(@id_pattern, id)
  def valid_id?(_id), do: false

  defp require_callback(module, function, arity) do
    case function_exported?(module, function, arity) do
      true -> :ok
      false -> {:error, {:missing_callback, function, arity}}
    end
  end

  defp normalize_id(id) when is_binary(id) do
    case valid_id?(id) do
      true -> {:ok, id}
      false -> {:error, {:invalid_plugin_id, id}}
    end
  end

  defp normalize_id(id), do: {:error, {:invalid_plugin_id, id}}

  defp normalize_api_version(@api_version), do: {:ok, @api_version}
  defp normalize_api_version(version), do: {:error, {:unsupported_api_version, version}}

  defp optional_localized_text(module, function) do
    case function_exported?(module, function, 0) do
      true -> normalize_localized_text(apply(module, function, []), function)
      false -> {:ok, nil}
    end
  end

  defp normalize_localized_text(nil, _function), do: {:ok, nil}
  defp normalize_localized_text(value, _function) when is_binary(value), do: {:ok, value}

  defp normalize_localized_text(value, _function) when is_map(value) do
    case Enum.all?(value, &localized_text_entry?/1) do
      true -> {:ok, value}
      false -> {:error, {:invalid_localized_text, value}}
    end
  end

  defp normalize_localized_text(value, function),
    do: {:error, {:invalid_localized_text, function, value}}

  defp localized_text_entry?({locale, text}) when is_binary(locale) and is_binary(text), do: true
  defp localized_text_entry?(_entry), do: false

  defp optional_list(module, function, item_valid?) do
    values =
      case function_exported?(module, function, 0) do
        true -> apply(module, function, [])
        false -> []
      end

    normalize_list(values, function, item_valid?)
  end

  defp normalize_list(values, function, item_valid?) when is_list(values) do
    case Enum.all?(values, item_valid?) do
      true -> {:ok, values}
      false -> {:error, {:invalid_list_items, function}}
    end
  end

  defp normalize_list(values, function, _item_valid?),
    do: {:error, {:invalid_list, function, values}}

  defp optional_children(module) do
    values =
      case function_exported?(module, :children, 0) do
        true -> module.children()
        false -> []
      end

    case is_list(values) do
      true -> {:ok, values}
      false -> {:error, {:invalid_list, :children, values}}
    end
  end

  defp definition?(%Definition{}), do: true
  defp definition?(_value), do: false

  defp pattern?(%PatternDefinition{}), do: true
  defp pattern?(_value), do: false

  defp map?(value), do: is_map(value)

  defp optional_adapter_declarations(module) do
    values =
      case function_exported?(module, :adapter_declarations, 0) do
        true -> module.adapter_declarations()
        false -> []
      end

    with {:ok, declarations} <- normalize_list(values, :adapter_declarations, &map?/1),
         :ok <- validate_adapter_declarations(declarations) do
      {:ok, declarations}
    end
  end

  defp validate_adapter_declarations(declarations) do
    Enum.reduce_while(declarations, :ok, fn declaration, :ok ->
      case validate_adapter_declaration(declaration) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_adapter_declaration, reason}}}
      end
    end)
  end

  defp validate_adapter_declaration(declaration) do
    with {:ok, contract_id} <- declaration_text(declaration, :contract_id),
         :ok <- validate_contract_id(contract_id),
         {:ok, adapter_id} <- declaration_text(declaration, :id),
         :ok <- validate_adapter_id(adapter_id),
         :ok <- validate_optional_adapter_id(declaration, :plugin_id),
         :ok <- validate_optional_module(declaration, :module) do
      validate_known_adapter_contract(contract_id, declaration)
    end
  end

  # Per-contract structural checks. A declaration names which contract it plugs
  # into; for the contracts Ankole ships, we verify the declared adapter modules
  # actually export the callbacks that contract will call at runtime. Unknown
  # contract ids pass through (last clause) so plugins can declare adapters for
  # contracts this validator does not yet know about.
  defp validate_known_adapter_contract("signals_gateway.adapter", declaration) do
    with :ok <- validate_signals_ingress(declaration),
         :ok <- validate_signals_outbox(declaration),
         :ok <- validate_connection_supervisor(declaration) do
      :ok
    end
  end

  defp validate_known_adapter_contract("principals.identity_provider", declaration) do
    with {:ok, module} <- declaration_module(declaration, :module),
         :ok <- validate_module_callback(module, :upsert_user, 2),
         :ok <- validate_identity_capabilities(module, declaration) do
      :ok
    end
  end

  defp validate_known_adapter_contract(_contract_id, _declaration), do: :ok

  # A plugin opts into ingress by listing inbound capabilities; each capability
  # name maps to one required callback on its ingress module (see the
  # `validate_signals_inbound_capability/2` clauses). Declaring no inbound
  # capabilities is valid for an outbound-only adapter.
  defp validate_signals_ingress(declaration) do
    capabilities = declaration_list(declaration, :inbound_capabilities)

    if capabilities == [] do
      :ok
    else
      with {:ok, module} <- declaration_module(declaration, :ingress_module),
           :ok <- validate_module_callback(module, :chat_consumer, 3) do
        Enum.reduce_while(capabilities, :ok, fn capability, :ok ->
          case validate_signals_inbound_capability(module, capability) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
      end
    end
  end

  defp validate_signals_inbound_capability(module, "entry_receive"),
    do: validate_module_callback(module, :handle_message_receive, 3)

  defp validate_signals_inbound_capability(module, "entry_removed"),
    do: validate_module_callback(module, :handle_message_removed, 3)

  defp validate_signals_inbound_capability(module, "reaction_add"),
    do: validate_module_callback(module, :handle_reaction_created, 3)

  defp validate_signals_inbound_capability(module, "reaction_remove"),
    do: validate_module_callback(module, :handle_reaction_deleted, 3)

  defp validate_signals_inbound_capability(module, "action_event"),
    do: validate_module_callback(module, :handle_card_action, 3)

  defp validate_signals_inbound_capability(_module, capability),
    do: {:error, {:unknown_inbound_capability, capability}}

  defp validate_signals_outbox(declaration) do
    capabilities = declaration_list(declaration, :outbound_capabilities)

    if capabilities == [] do
      :ok
    else
      with {:ok, module} <- declaration_module(declaration, :outbox_module),
           :ok <- validate_module_callback(module, :send, 1) do
        case "outbound_reconciliation" in capabilities do
          true -> validate_module_callback(module, :reconcile, 1)
          false -> :ok
        end
      end
    end
  end

  defp validate_connection_supervisor(declaration) do
    case declaration_module(declaration, :connection_supervisor) do
      {:ok, module} -> validate_module_callback(module, :ensure_started, 3)
      {:error, {:missing_adapter_module, :connection_supervisor}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_identity_capabilities(module, declaration) do
    declaration
    |> declaration_list(:capabilities)
    |> Enum.reduce_while(:ok, fn capability, :ok ->
      case validate_identity_capability(module, capability) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_identity_capability(module, "oidc_authorization"),
    do: validate_module_callback(module, :authorization_url, 2)

  defp validate_identity_capability(module, "oidc_code_exchange"),
    do: validate_module_callback(module, :exchange_code, 3)

  defp validate_identity_capability(module, "user_full_sync"),
    do: validate_module_callback(module, :sync_users, 3)

  defp validate_identity_capability(module, "department_full_sync"),
    do: validate_module_callback(module, :sync_departments, 3)

  defp validate_identity_capability(_module, _capability), do: :ok

  defp validate_contract_id(contract_id) do
    case Regex.match?(@contract_id_pattern, contract_id) do
      true -> :ok
      false -> {:error, {:invalid_contract_id, contract_id}}
    end
  end

  defp validate_adapter_id(adapter_id) do
    case valid_id?(adapter_id) do
      true -> :ok
      false -> {:error, {:invalid_adapter_id, adapter_id}}
    end
  end

  defp validate_optional_adapter_id(declaration, key) do
    case declaration_text(declaration, key) do
      {:ok, value} -> validate_adapter_id(value)
      {:error, {:missing_adapter_text, ^key}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_optional_module(declaration, key) do
    case declaration_module(declaration, key) do
      {:ok, _module} -> :ok
      {:error, {:missing_adapter_module, ^key}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_module_callback(module, function, arity) do
    case function_exported?(module, function, arity) do
      true -> :ok
      false -> {:error, {:missing_adapter_callback, module, function, arity}}
    end
  end

  defp declaration_module(declaration, key) do
    case declaration_value(declaration, key) do
      {:ok, module} when is_atom(module) ->
        case Code.ensure_loaded(module) do
          {:module, ^module} -> {:ok, module}
          {:error, reason} -> {:error, {:adapter_module_not_loaded, key, module, reason}}
        end

      {:ok, module} ->
        {:error, {:invalid_adapter_module, key, module}}

      :error ->
        {:error, {:missing_adapter_module, key}}
    end
  end

  defp declaration_text(declaration, key) do
    case declaration_value(declaration, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, value} -> {:error, {:invalid_adapter_text, key, value}}
      :error -> {:error, {:missing_adapter_text, key}}
    end
  end

  defp declaration_list(declaration, key) do
    case declaration_value(declaration, key) do
      {:ok, values} when is_list(values) -> values
      _other -> []
    end
  end

  # Plugins may author declaration maps with atom or string keys, so every read
  # tries the atom key first and falls back to its string form.
  defp declaration_value(declaration, key) do
    case Map.fetch(declaration, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(declaration, Atom.to_string(key))
    end
  end
end
