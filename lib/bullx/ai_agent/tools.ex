defmodule BullX.AIAgent.Tools do
  @moduledoc """
  ToolSet expansion and `ReqLLM.Tool` rendering for AIAgent runtime.

  Tools are organized into code-owned **ToolSets**. Each Tool declares an access
  tag (`:ordinary` or `:privileged`) and optional Agent/Session availability
  checks. Agent profiles can only enable or disable ToolSets; they cannot
  change tool access, schemas, or callbacks.

  `enabled_tools/5` renders ToolSet/profile/availability-enabled tools for the
  provider request. ACL is deliberately enforced by the dispatcher when a tool
  call is executed, not by hiding provider schemas.
  """

  alias BullX.AIAgent.Profile
  alias BullX.AIAgent.Tools.{Context, Registry}
  alias BullX.AIAgent.Tools.Registry.{Tool, ToolSet}

  @type rendered_tool :: %{entry: Tool.t(), access: atom(), tool: ReqLLM.Tool.t()}

  @spec enabled_tools(Profile.t(), String.t(), String.t(), map(), map()) :: [rendered_tool()]
  def enabled_tools(
        %Profile{} = profile,
        _caller_principal_uid,
        _agent_uid,
        _acl_context,
        runtime_seed \\ %{}
      ) do
    runtime_seed
    |> Registry.list_toolsets()
    |> Enum.flat_map(&expand_toolset(profile, &1, runtime_seed))
  end

  @spec effective_tool(Profile.t(), String.t(), map()) ::
          {:ok, Tool.t(), atom()}
          | {:error, :tool_unknown | :tool_disabled | :tool_unavailable}
  def effective_tool(%Profile{} = profile, tool_name, runtime_seed \\ %{})
      when is_binary(tool_name) do
    with {:ok, entry} <- Registry.get_tool(tool_name, runtime_seed),
         {:ok, toolset} <- Registry.toolset(entry.toolset_id, runtime_seed),
         true <- toolset_enabled?(profile, toolset),
         :ok <- available?(toolset.availability, runtime_seed),
         :ok <- available?(entry.availability, runtime_seed) do
      {:ok, entry, entry.access}
    else
      {:error, :not_found} -> {:error, :tool_unknown}
      false -> {:error, :tool_disabled}
      {:error, :tool_unavailable} -> {:error, :tool_unavailable}
      {:error, _reason} -> {:error, :tool_unavailable}
    end
  end

  @spec profile_tool_names(Profile.t(), map()) :: [String.t()]
  def profile_tool_names(%Profile{} = profile, runtime_seed \\ %{}) do
    runtime_seed
    |> Registry.list_toolsets()
    |> Enum.filter(&toolset_enabled?(profile, &1))
    |> Enum.filter(&(available?(&1.availability, runtime_seed) == :ok))
    |> Enum.flat_map(fn toolset ->
      toolset.id
      |> Registry.tools_for_toolset(runtime_seed)
      |> Enum.filter(&(available?(&1.availability, runtime_seed) == :ok))
    end)
    |> Enum.map(& &1.name)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec validate_arguments(Tool.t(), map()) :: {:ok, map()} | {:error, :tool_malformed_arguments}
  def validate_arguments(%Tool{} = entry, args) when is_map(args) do
    with {:ok, validator} <- validator_tool(entry),
         {:ok, validated} <- ReqLLM.Tool.execute(validator, args) do
      {:ok, normalize_validated_arguments(validated)}
    else
      {:error, _reason} -> {:error, :tool_malformed_arguments}
    end
  end

  def validate_arguments(%Tool{}, _args), do: {:error, :tool_malformed_arguments}

  @spec idempotency_key(map()) :: String.t()
  def idempotency_key(parts) when is_map(parts) do
    parts
    |> Jason.encode!()
    |> BullX.Ext.generic_hash()
  end

  @spec build_context(map(), map()) :: Context.t()
  def build_context(seed, tool_call) when is_map(seed) and is_map(tool_call) do
    tool_name = tool_call[:name] || tool_call["name"]
    tool_call_id = tool_call[:id] || tool_call["id"]
    arguments = tool_call[:arguments] || tool_call["arguments"] || %{}

    idempotency_key =
      idempotency_key(%{
        conversation_id: seed.conversation_id,
        assistant_message_id: seed.assistant_message_id,
        tool_call_id: tool_call_id,
        tool_name: tool_name,
        arguments: arguments
      })

    %Context{
      caller_principal_uid: seed.caller_principal_uid,
      agent_uid: seed.agent_uid,
      conversation_id: seed.conversation_id,
      trigger_type: seed.trigger_type,
      trigger_id: seed.trigger_id,
      tool_call_id: tool_call_id,
      tool_name: tool_name,
      effective_access: seed.effective_access,
      timeout_ms: seed.timeout_ms,
      deadline_at_ms: Map.get(seed, :deadline_at_ms),
      idempotency_key: idempotency_key,
      metadata: Map.get(seed, :metadata, %{})
    }
  end

  defp expand_toolset(profile, %ToolSet{} = toolset, runtime_seed) do
    with true <- toolset_enabled?(profile, toolset),
         :ok <- available?(toolset.availability, runtime_seed) do
      toolset.id
      |> Registry.tools_for_toolset(runtime_seed)
      |> Enum.flat_map(&render_tool(&1, runtime_seed))
    else
      _other -> []
    end
  end

  defp render_tool(%Tool{} = entry, runtime_seed) do
    with :ok <- available?(entry.availability, runtime_seed),
         {:ok, tool} <- req_llm_tool(entry, runtime_seed) do
      [%{entry: entry, access: entry.access, tool: tool}]
    else
      _other -> []
    end
  end

  defp toolset_enabled?(_profile, %ToolSet{id: "basic"}), do: true

  defp toolset_enabled?(%Profile{} = profile, %ToolSet{} = toolset) do
    case Map.fetch(profile.toolsets, toolset.id) do
      {:ok, %{enabled: enabled}} when is_boolean(enabled) -> enabled
      :error -> toolset.default_enabled
      _other -> false
    end
  end

  defp available?(nil, _runtime_seed), do: :ok

  defp available?(fun, runtime_seed) when is_function(fun, 1) do
    fun
    |> safe_availability_call([runtime_seed])
    |> normalize_availability()
  end

  defp available?({module, function, args}, runtime_seed)
       when is_atom(module) and is_atom(function) and is_list(args) do
    {module, function}
    |> safe_availability_call(args ++ [runtime_seed])
    |> normalize_availability()
  end

  defp available?({module, function}, runtime_seed)
       when is_atom(module) and is_atom(function) do
    {module, function}
    |> safe_availability_call([runtime_seed])
    |> normalize_availability()
  end

  defp available?(_availability, _runtime_seed), do: {:error, :tool_unavailable}

  defp safe_availability_call(fun, args) when is_function(fun, 1) do
    apply(fun, args)
  rescue
    _error -> {:error, :tool_unavailable}
  catch
    :exit, _reason -> {:error, :tool_unavailable}
  end

  defp safe_availability_call({module, function}, args) do
    apply(module, function, args)
  rescue
    _error -> {:error, :tool_unavailable}
  catch
    :exit, _reason -> {:error, :tool_unavailable}
  end

  defp normalize_availability(:ok), do: :ok
  defp normalize_availability(true), do: :ok
  defp normalize_availability({:ok, _value}), do: :ok
  defp normalize_availability({:error, _reason}), do: {:error, :tool_unavailable}
  defp normalize_availability(false), do: {:error, :tool_unavailable}
  defp normalize_availability(_other), do: {:error, :tool_unavailable}

  defp req_llm_tool(%Tool{} = entry, runtime_seed) do
    ReqLLM.Tool.new(
      name: entry.name,
      description: entry.description,
      parameter_schema: entry.parameter_schema,
      strict: entry.strict,
      callback:
        {BullX.AIAgent.Tools.Dispatcher, :execute_with_context,
         [entry.name, entry.access, runtime_seed]},
      provider_options: entry.provider_options
    )
  end

  defp validator_tool(%Tool{} = entry) do
    ReqLLM.Tool.new(
      name: entry.name,
      description: entry.description,
      parameter_schema: entry.parameter_schema,
      strict: entry.strict,
      callback: fn input -> {:ok, input} end,
      provider_options: entry.provider_options
    )
  end

  defp normalize_validated_arguments(validated) when is_list(validated), do: Map.new(validated)
  defp normalize_validated_arguments(validated) when is_map(validated), do: validated
end
