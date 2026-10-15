defmodule Ankole.Signals.BindingCatalog do
  @moduledoc false
  import Ecto.Query, warn: false

  alias Ankole.Repo
  alias Ankole.Principals
  alias Ankole.Plugins.ConfigSecrets
  alias Ankole.Signals.Adapters
  alias Ankole.Signals.Adapters.Definition
  alias Ankole.Signals.Binding
  alias Ankole.Conversations.GroupMessageModes
  alias Ankole.Signals.SubjectNamespace
  alias Ankole.Signals.UnmatchedSenderPolicies

  @spec list_adapters() :: {:ok, [map()]} | {:error, term()}
  def list_adapters do
    with {:ok, definitions} <- Adapters.list(),
         {:ok, catalog} <- collect_ok(definitions, &adapter_catalog/1) do
      {:ok, Enum.sort_by([cloud_event_catalog() | catalog], & &1.adapter_id)}
    end
  end

  def binding_fields(%Binding{adapter: "cloudevents"}), do: {:ok, cloud_event_catalog().fields}

  def binding_fields(binding) do
    with {:ok, definition} <- Adapters.fetch(binding.adapter), do: {:ok, definition.fields}
  end

  defp cloud_event_catalog do
    %{
      adapter_id: "cloudevents",
      adapter_category: "event_source",
      plugin_id: nil,
      display_name: %{default: "CloudEvents"},
      group_message_mode_field: nil,
      unmatched_sender_policy_field: nil,
      fields: [
        %{
          path: "webhook_endpoint_id",
          type: "string",
          required: true,
          label: %{default: "Endpoint ID", "zh-Hans-CN": "端点 ID"}
        },
        %{
          path: "target_kind",
          type: "enum",
          default: "conversation",
          required: true,
          label: %{default: "Target type", "zh-Hans-CN": "目标类型"},
          options: [
            %{value: "conversation", label: %{default: "Conversation", "zh-Hans-CN": "对话"}},
            %{value: "session", label: %{default: "Session", "zh-Hans-CN": "执行会话"}}
          ]
        },
        %{
          path: "target_id",
          type: "string",
          required: true,
          label: %{default: "Target ID", "zh-Hans-CN": "目标 ID"},
          description: %{
            default: "The Conversation UUID or fixed Session key.",
            "zh-Hans-CN": "固定对话或执行会话时必填；按 subject 归并或每个事件独立时留空。"
          }
        },
        %{
          path: "filter_cel",
          type: "string",
          label: %{default: "CEL filter", "zh-Hans-CN": "CEL 筛选条件"}
        }
      ]
    }
  end

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
  # applies. See `Ankole.Signals.SubjectNamespace`.
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

  def identity_provider_ids(%{identity_provider_adapter: adapter_id}) do
    SubjectNamespace.provider_ids(adapter_id)
  end

  @spec get_binding_configuration(String.t(), String.t()) ::
          {:ok, %{binding: Binding.t(), config: map(), stored_secret_paths: [String.t()]}}
          | {:error, term()}
  def get_binding_configuration(agent_uid, binding_name)
      when is_binary(agent_uid) and is_binary(binding_name) do
    with {:ok, %{principal: principal}} <- Principals.get_agent(agent_uid),
         %Binding{} = binding <-
           Repo.get_by(Binding, agent_uid: principal.uid, name: binding_name),
         {:ok, config} <- Ankole.Signals.Bindings.stored_binding_config(binding) do
      with {:ok, fields} <- Ankole.Signals.BindingCatalog.binding_fields(binding) do
        {config, stored_secret_paths} = ConfigSecrets.redact(fields, config)

        {:ok, %{binding: binding, config: config, stored_secret_paths: stored_secret_paths}}
      end
    else
      nil -> {:error, :binding_not_found}
      {:error, :not_found} -> {:error, :agent_not_found}
      {:error, _reason} = error -> error
    end
  end

  def get_binding_configuration(_agent_uid, _binding_name),
    do: {:error, :binding_not_found}

  def binding_config_key(%Definition{} = definition, agent_uid, binding_name) do
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
