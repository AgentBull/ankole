defmodule BullX.AIAgent.Tools.Registry.ToolSet do
  @moduledoc false

  @enforce_keys [:id, :default_enabled, :disableable, :tools]
  defstruct [
    :id,
    :description,
    :availability,
    default_enabled: true,
    disableable: true,
    tools: []
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          description: String.t() | nil,
          default_enabled: boolean(),
          disableable: boolean(),
          tools: [String.t()],
          availability: term()
        }
end

defmodule BullX.AIAgent.Tools.Registry.Tool do
  @moduledoc false

  @enforce_keys [:name, :toolset_id, :description, :parameter_schema, :access, :module]
  defstruct [
    :name,
    :toolset_id,
    :description,
    :parameter_schema,
    :access,
    :module,
    :availability,
    :retry,
    strict: false,
    provider_options: %{},
    parallel_safe: false,
    timeout_ms: 30_000
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          toolset_id: String.t(),
          description: String.t(),
          parameter_schema: keyword() | map(),
          strict: boolean(),
          provider_options: keyword() | map(),
          access: :ordinary | :privileged,
          parallel_safe: boolean(),
          module: module(),
          availability: term(),
          timeout_ms: pos_integer(),
          retry: keyword() | map() | nil
        }
end

defmodule BullX.AIAgent.Tools.Registry do
  @moduledoc """
  Code-owned AIAgent ToolSet registry.

  Tool definitions are normalized from BullX core and enabled compiled plugin
  extensions before they become visible to a model request. The registry is
  deliberately request-time and code-owned: it does not persist Tool or ToolSet
  definitions and it does not read Agent profile data.
  """

  alias BullX.AIAgent.Tools.Registry.{Tool, ToolSet}
  alias BullX.Plugins.Extension

  @extension_point :"bullx.ai_agent.toolset"
  @access_tags [:ordinary, :privileged]
  @toolset_fields [:id, :description, :default_enabled, :disableable, :availability]
  @tool_fields [
    :name,
    :toolset_id,
    :description,
    :parameter_schema,
    :strict,
    :provider_options,
    :access,
    :parallel_safe,
    :module,
    :availability,
    :timeout_ms,
    :retry
  ]

  @builtins [
    %{
      toolset: %{
        id: "basic",
        description: "Always-on basic interaction tools.",
        default_enabled: true,
        disableable: false
      },
      tools: [
        %{
          name: "clarify",
          description:
            "Ask the current human-facing run for missing information needed to continue.",
          parameter_schema: [
            question: [
              type: :string,
              required: true,
              doc: "The concise clarification question to show to the human."
            ],
            choices: [
              type: {:list, :string},
              default: [],
              doc: "Optional choices. BullX keeps at most four non-empty choices."
            ]
          ],
          access: :ordinary,
          parallel_safe: false,
          module: BullX.AIAgent.Tools.Clarify
        }
      ]
    },
    %{
      toolset: %{
        id: "web",
        description: "External web search and extraction through BullX-owned adapters.",
        default_enabled: true,
        disableable: true
      },
      tools: [
        %{
          name: "web_search",
          description: "Search the web and return normalized search results.",
          parameter_schema: [
            query: [type: :string, required: true, doc: "Search query."],
            limit: [
              type: :integer,
              default: 5,
              doc: "Maximum number of results. BullX clamps this to 1..100."
            ]
          ],
          access: :ordinary,
          parallel_safe: true,
          module: BullX.AIAgent.Tools.WebSearch,
          availability: {BullX.AIAgent.Tools.Web, :search_available?},
          timeout_ms: 75_000
        },
        %{
          name: "web_extract",
          description: "Extract readable text from up to five URLs.",
          parameter_schema: [
            urls: [
              type: {:list, :string},
              required: true,
              doc: "URLs to extract. BullX uses at most five."
            ]
          ],
          access: :ordinary,
          parallel_safe: true,
          module: BullX.AIAgent.Tools.WebExtract,
          availability: {BullX.AIAgent.Tools.Web, :extract_available?}
        }
      ]
    }
  ]

  @type registry :: %{toolsets: %{String.t() => ToolSet.t()}, tools: %{String.t() => Tool.t()}}

  @spec extension_point() :: atom()
  def extension_point, do: @extension_point

  @spec list_toolsets(map()) :: [ToolSet.t()]
  def list_toolsets(opts \\ %{}) do
    opts
    |> registry()
    |> Map.fetch!(:toolsets)
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  @spec list_tools(map()) :: [Tool.t()]
  def list_tools(opts \\ %{}) do
    opts
    |> registry()
    |> Map.fetch!(:tools)
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end

  @spec get_tool(String.t(), map()) :: {:ok, Tool.t()} | {:error, :not_found}
  def get_tool(tool_name, opts \\ %{}) when is_binary(tool_name) do
    case Map.fetch(registry(opts).tools, tool_name) do
      {:ok, tool} -> {:ok, tool}
      :error -> {:error, :not_found}
    end
  end

  @spec tools_for_toolset(String.t(), map()) :: [Tool.t()]
  def tools_for_toolset(toolset_id, opts \\ %{}) when is_binary(toolset_id) do
    opts
    |> registry()
    |> Map.fetch!(:tools)
    |> Map.values()
    |> Enum.filter(&(&1.toolset_id == toolset_id))
    |> Enum.sort_by(& &1.name)
  end

  @spec toolset(String.t(), map()) :: {:ok, ToolSet.t()} | {:error, :not_found}
  def toolset(toolset_id, opts \\ %{}) when is_binary(toolset_id) do
    case Map.fetch(registry(opts).toolsets, toolset_id) do
      {:ok, toolset} -> {:ok, toolset}
      :error -> {:error, :not_found}
    end
  end

  @spec registry(map()) :: registry()
  def registry(opts \\ %{}) when is_map(opts) do
    base =
      Enum.reduce(@builtins, empty_registry(), fn contribution, acc ->
        {:ok, normalized} = normalize_contribution(contribution, nil)
        merge_contribution!(acc, normalized)
      end)

    opts
    |> plugin_extensions()
    |> Enum.sort_by(&{&1.plugin_id, to_string(&1.id)})
    |> Enum.reduce(base, &merge_plugin_extension/2)
  end

  defp empty_registry, do: %{toolsets: %{}, tools: %{}}

  defp merge_contribution!(registry, %{toolset: toolset, tools: tools}) do
    registry
    |> put_in([:toolsets, toolset.id], toolset)
    |> update_in([:tools], fn existing ->
      Map.merge(existing, Map.new(tools, &{&1.name, &1}))
    end)
  end

  defp merge_plugin_extension(%Extension{} = extension, registry) do
    with {:ok, contribution} <- call_extension(extension),
         {:ok, normalized} <- normalize_contribution(contribution, to_string(extension.id)),
         :ok <- ensure_no_conflicts(registry, normalized) do
      merge_contribution!(registry, normalized)
    else
      {:error, reason} ->
        emit_skip(extension, reason)
        registry
    end
  end

  defp call_extension(%Extension{module: module, opts: opts}) do
    cond do
      function_exported?(module, :toolset, 1) ->
        normalize_callback_result(module.toolset(opts))

      function_exported?(module, :toolset, 0) ->
        normalize_callback_result(module.toolset())

      true ->
        {:error, :missing_toolset_callback}
    end
  rescue
    _error -> {:error, :toolset_callback_failed}
  catch
    :exit, _reason -> {:error, :toolset_callback_failed}
  end

  defp normalize_callback_result({:ok, contribution}), do: {:ok, contribution}
  defp normalize_callback_result(%{} = contribution), do: {:ok, contribution}
  defp normalize_callback_result(%_{} = contribution), do: {:ok, contribution}
  defp normalize_callback_result(_other), do: {:error, :invalid_toolset_callback_result}

  defp normalize_contribution(contribution, expected_toolset_id) do
    data = to_map(contribution)
    {toolset_data, tool_data} = split_contribution(data)

    with {:ok, toolset} <- normalize_toolset(toolset_data, expected_toolset_id),
         {:ok, tools} <- normalize_tools(tool_data, toolset.id),
         :ok <- ensure_unique_tool_names(tools) do
      {:ok, %{toolset: %{toolset | tools: Enum.map(tools, & &1.name)}, tools: tools}}
    end
  end

  defp split_contribution(data) do
    case fetch_field(data, :toolset) do
      {:ok, toolset_data} ->
        {to_map(toolset_data), list_field(data, :tools)}

      :error ->
        {Map.drop(data, [:tools, "tools"]), list_field(data, :tools)}
    end
  end

  defp normalize_toolset(data, expected_toolset_id) do
    with :ok <- reject_unsupported_fields(data, @toolset_fields),
         {:ok, id} <- required_string(data, :id),
         :ok <- ensure_expected_id(id, expected_toolset_id),
         {:ok, default_enabled} <- boolean_field(data, :default_enabled, true),
         {:ok, disableable} <- boolean_field(data, :disableable, true),
         {:ok, availability} <- availability_field(data, :availability),
         {:ok, description} <- optional_string(data, :description) do
      {:ok,
       %ToolSet{
         id: id,
         description: description,
         default_enabled: default_enabled,
         disableable: disableable,
         availability: availability,
         tools: []
       }}
    end
  end

  defp normalize_tools([], _toolset_id), do: {:error, :toolset_requires_tools}

  defp normalize_tools(tools, toolset_id) when is_list(tools) do
    tools
    |> Enum.reduce_while({:ok, []}, fn tool_data, {:ok, acc} ->
      case normalize_tool(tool_data, toolset_id) do
        {:ok, tool} -> {:cont, {:ok, [tool | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_tools(_tools, _toolset_id), do: {:error, :tools_must_be_list}

  defp normalize_tool(tool_data, owner_toolset_id) do
    data = to_map(tool_data)

    with :ok <- reject_unsupported_fields(data, @tool_fields),
         {:ok, name} <- required_string(data, :name),
         :ok <- validate_tool_name(name),
         :ok <- validate_owner(data, owner_toolset_id),
         {:ok, description} <- required_string(data, :description),
         {:ok, parameter_schema} <- required_field(data, :parameter_schema),
         {:ok, strict} <- boolean_field(data, :strict, false),
         {:ok, provider_options} <- field_value(data, :provider_options, %{}),
         {:ok, access} <- access_field(data),
         {:ok, parallel_safe} <- boolean_field(data, :parallel_safe, false),
         {:ok, module} <- module_field(data),
         {:ok, availability} <- availability_field(data, :availability),
         {:ok, timeout_ms} <- positive_integer_field(data, :timeout_ms, 30_000),
         {:ok, retry} <- field_value(data, :retry, nil),
         :ok <-
           validate_req_llm_shape(name, description, parameter_schema, strict, provider_options) do
      {:ok,
       %Tool{
         name: name,
         toolset_id: owner_toolset_id,
         description: description,
         parameter_schema: parameter_schema,
         strict: strict,
         provider_options: provider_options,
         access: access,
         parallel_safe: parallel_safe,
         module: module,
         availability: availability,
         timeout_ms: timeout_ms,
         retry: retry
       }}
    end
  end

  defp ensure_no_conflicts(registry, %{toolset: toolset, tools: tools}) do
    cond do
      Map.has_key?(registry.toolsets, toolset.id) ->
        {:error, {:conflicting_toolset_id, toolset.id}}

      conflict = Enum.find(tools, &Map.has_key?(registry.tools, &1.name)) ->
        {:error, {:conflicting_tool_name, conflict.name}}

      true ->
        :ok
    end
  end

  defp ensure_unique_tool_names(tools) do
    tools
    |> Enum.frequencies_by(& &1.name)
    |> Enum.find(fn {_name, count} -> count > 1 end)
    |> case do
      nil -> :ok
      {name, _count} -> {:error, {:duplicate_tool_name, name}}
    end
  end

  defp validate_owner(data, owner_toolset_id) do
    case optional_string(data, :toolset_id) do
      {:ok, nil} -> :ok
      {:ok, ^owner_toolset_id} -> :ok
      {:ok, toolset_id} -> {:error, {:orphan_tool, toolset_id}}
      {:error, _reason} = error -> error
    end
  end

  defp validate_tool_name(name) do
    cond do
      not ReqLLM.Tool.valid_name?(name) ->
        {:error, {:invalid_tool_name, name}}

      not Regex.match?(~r/^[a-z][a-z0-9_]*$/, name) ->
        {:error, {:invalid_tool_name_style, name}}

      true ->
        :ok
    end
  end

  defp validate_req_llm_shape(name, description, parameter_schema, strict, provider_options) do
    case ReqLLM.Tool.new(
           name: name,
           description: description,
           parameter_schema: parameter_schema,
           strict: strict,
           provider_options: provider_options,
           callback: fn input -> {:ok, input} end
         ) do
      {:ok, _tool} -> :ok
      {:error, _reason} -> {:error, {:invalid_req_llm_tool, name}}
    end
  end

  defp plugin_extensions(opts) do
    server = Map.get(opts, :plugin_registry, BullX.Plugins.Registry)

    cond do
      match?(%BullX.Plugins.Registry{}, server) ->
        enabled_extensions(server)

      true ->
        BullX.Plugins.enabled_extensions_for(@extension_point, server)
    end
  rescue
    _error -> []
  catch
    :exit, _reason -> []
  end

  defp enabled_extensions(%BullX.Plugins.Registry{} = state) do
    Enum.filter(state.extensions, fn extension ->
      extension.point == @extension_point and
        MapSet.member?(state.enabled_ids, extension.plugin_id)
    end)
  end

  defp emit_skip(%Extension{} = extension, reason) do
    :telemetry.execute([:bullx, :ai_agent, :tools, :registry, :skipped], %{}, %{
      plugin_id: extension.plugin_id,
      extension_id: to_string(extension.id),
      reason: safe_reason(reason)
    })
  end

  defp reject_unsupported_fields(data, allowed) do
    data
    |> Map.keys()
    |> Enum.reject(&allowed_field?(&1, allowed))
    |> case do
      [] -> :ok
      fields -> {:error, {:unsupported_fields, Enum.map(fields, &to_string/1)}}
    end
  end

  defp allowed_field?(key, allowed) when is_atom(key), do: key in allowed

  defp allowed_field?(key, allowed) when is_binary(key),
    do: key in Enum.map(allowed, &to_string/1)

  defp allowed_field?(_key, _allowed), do: false

  defp required_field(data, field) do
    case fetch_field(data, field) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, field}}
    end
  end

  defp required_string(data, field) do
    case fetch_field(data, field) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_string_field, field}}
      :error -> {:error, {:missing_field, field}}
    end
  end

  defp optional_string(data, field) do
    case fetch_field(data, field) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, nil} -> {:ok, nil}
      {:ok, _value} -> {:error, {:invalid_string_field, field}}
      :error -> {:ok, nil}
    end
  end

  defp access_field(data) do
    case fetch_field(data, :access) do
      {:ok, access} when access in @access_tags ->
        {:ok, access}

      {:ok, access} when is_binary(access) ->
        access
        |> normalize_access()
        |> case do
          value when value in @access_tags -> {:ok, value}
          _other -> {:error, {:invalid_access, access}}
        end

      {:ok, access} ->
        {:error, {:invalid_access, access}}

      :error ->
        {:error, {:missing_field, :access}}
    end
  end

  defp normalize_access("ordinary"), do: :ordinary
  defp normalize_access("privileged"), do: :privileged
  defp normalize_access(_value), do: nil

  defp boolean_field(data, field, default) do
    case fetch_field(data, field) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_boolean_field, field}}
      :error -> {:ok, default}
    end
  end

  defp positive_integer_field(data, field, default) do
    case fetch_field(data, field) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_positive_integer_field, field}}
      :error -> {:ok, default}
    end
  end

  defp field_value(data, field, default) do
    case fetch_field(data, field) do
      {:ok, value} -> {:ok, value}
      :error -> {:ok, default}
    end
  end

  defp module_field(data) do
    case fetch_field(data, :module) do
      {:ok, module} when is_atom(module) ->
        with {:module, ^module} <- Code.ensure_loaded(module),
             true <- function_exported?(module, :execute, 2) do
          {:ok, module}
        else
          _other -> {:error, {:invalid_tool_module, module}}
        end

      {:ok, module} ->
        {:error, {:invalid_tool_module, module}}

      :error ->
        {:error, {:missing_field, :module}}
    end
  end

  defp availability_field(data, field) do
    case fetch_field(data, field) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, fun} when is_function(fun, 1) ->
        {:ok, fun}

      {:ok, {module, function}} when is_atom(module) and is_atom(function) ->
        validate_availability_callback(module, function, [])

      {:ok, {module, function, args}}
      when is_atom(module) and is_atom(function) and is_list(args) ->
        validate_availability_callback(module, function, args)

      {:ok, value} ->
        {:error, {:invalid_availability, value}}

      :error ->
        {:ok, nil}
    end
  end

  defp validate_availability_callback(module, function, args) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, function, length(args) + 1) do
      {:ok, {module, function, args}}
    else
      _other -> {:error, {:invalid_availability, module, function}}
    end
  end

  defp ensure_expected_id(_id, nil), do: :ok
  defp ensure_expected_id(id, id), do: :ok
  defp ensure_expected_id(id, expected), do: {:error, {:extension_id_mismatch, expected, id}}

  defp fetch_field(data, field) when is_atom(field) do
    case Map.fetch(data, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(data, Atom.to_string(field))
    end
  end

  defp list_field(data, field) do
    case fetch_field(data, field) do
      {:ok, value} when is_list(value) -> value
      {:ok, _value} -> :invalid
      :error -> []
    end
  end

  defp to_map(%_{} = struct), do: Map.from_struct(struct)
  defp to_map(%{} = map), do: map
  defp to_map(_other), do: %{}

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp safe_reason(reason),
    do: reason |> inspect(limit: 5, printable_limit: 120) |> String.slice(0, 160)
end
