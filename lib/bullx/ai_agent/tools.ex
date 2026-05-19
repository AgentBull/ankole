defmodule BullX.AIAgent.Tools do
  @moduledoc """
  ToolSet expansion and `ReqLLM.Tool` rendering for AIAgent runtime.

  In an OpenClaw / Hermes-style harness, tool access is configured per-agent:
  the operator enables or denies a tool for the assistant, and that policy is
  evaluated either as the model invokes the tool or even just as guidance in
  the system prompt. BullX gates tools per-**caller**-per-**call**.

  Tools are organized into **ToolSets** (a registered package of related
  tools), and each tool declares an access tag (`:ordinary` or
  `:privileged`). When the Runner prepares a generation, it asks `ACL` which
  tags the *caller's* Principal holds in the *agent's* scope, and renders
  only the tools whose tag the caller has into the schema sent to the model.
  The model never sees tools the caller isn't authorized to invoke —
  authorization happens at schema rendering, so the boundary is what the
  model can even *propose*, not what gets rejected at execution time.

  `enabled_tools/5` is the per-generation entry point used by `Runner`.
  """

  alias BullX.AIAgent.{ACL, Profile}
  alias BullX.AIAgent.Tools.{Context, Registry}

  @type rendered_tool :: %{entry: map(), access: atom(), tool: ReqLLM.Tool.t()}

  @spec enabled_tools(Profile.t(), String.t(), String.t(), map(), map()) :: [rendered_tool()]
  def enabled_tools(
        %Profile{} = profile,
        caller_principal_id,
        agent_principal_id,
        acl_context,
        runtime_seed \\ %{}
      )
      when is_binary(caller_principal_id) and is_binary(agent_principal_id) do
    allowed_tags = ACL.filter_allowed_tags(caller_principal_id, agent_principal_id, acl_context)

    profile.toolsets
    |> Enum.flat_map(fn {toolset_id, toolset_config} ->
      expand_toolset(toolset_id, toolset_config, allowed_tags, runtime_seed)
    end)
  end

  @spec effective_tool(Profile.t(), String.t()) ::
          {:ok, map(), atom()} | {:error, :tool_unknown | :tool_disabled}
  def effective_tool(%Profile{} = profile, tool_name) when is_binary(tool_name) do
    with {:ok, entry} <- Registry.get_tool(tool_name),
         {:ok, toolset_config} <- enabled_toolset_config(profile, entry.toolset_id),
         {:ok, tool_config} <- enabled_tool_config(toolset_config, tool_name),
         {:ok, access} <- effective_access(entry, toolset_config, tool_config) do
      {:ok, entry, access}
    else
      {:error, :not_found} -> {:error, :tool_unknown}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec idempotency_key(map()) :: String.t()
  def idempotency_key(parts) when is_map(parts) do
    parts
    |> Jason.encode!()
    |> BullX.Ext.generic_hash()
  end

  defp expand_toolset(toolset_id, %{enabled: true} = toolset_config, allowed_tags, runtime_seed) do
    Registry.tools_for_toolset(toolset_id)
    |> Enum.flat_map(fn entry ->
      with {:ok, tool_config} <- enabled_tool_config(toolset_config, entry.name),
           {:ok, access} <- effective_access(entry, toolset_config, tool_config),
           true <- MapSet.member?(allowed_tags, access),
           {:ok, tool} <- req_llm_tool(entry, access, runtime_seed) do
        [%{entry: entry, access: access, tool: tool}]
      else
        _other -> []
      end
    end)
  end

  defp expand_toolset(_toolset_id, _toolset_config, _allowed_tags, _runtime_seed), do: []

  defp enabled_toolset_config(%Profile{} = profile, toolset_id) do
    case Map.fetch(profile.toolsets, toolset_id) do
      {:ok, %{enabled: true} = config} -> {:ok, config}
      {:ok, _config} -> {:error, :tool_disabled}
      :error -> {:error, :tool_disabled}
    end
  end

  defp enabled_tool_config(toolset_config, tool_name) do
    case Map.get(toolset_config.tools, tool_name, %{enabled: true, access: nil}) do
      %{enabled: true} = tool_config -> {:ok, tool_config}
      _tool_config -> {:error, :tool_disabled}
    end
  end

  defp effective_access(entry, toolset_config, tool_config) do
    registry_default =
      entry[:default_access] || default_toolset_access(Registry.toolset(entry.toolset_id))

    {:ok, tool_config.access || toolset_config.access || registry_default}
  end

  defp default_toolset_access({:ok, toolset}), do: toolset.default_access
  defp default_toolset_access(_other), do: :ordinary

  defp req_llm_tool(entry, access, runtime_seed) do
    ReqLLM.Tool.new(
      name: entry.name,
      description: entry.description,
      parameter_schema: entry.parameter_schema,
      callback:
        {BullX.AIAgent.Tools.Dispatcher, :execute_with_context,
         [entry.name, access, runtime_seed]},
      provider_options: Map.get(entry, :provider_options, %{})
    )
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
      caller_principal_id: seed.caller_principal_id,
      agent_principal_id: seed.agent_principal_id,
      conversation_id: seed.conversation_id,
      source_type: seed.source_type,
      source_id: seed.source_id,
      tool_call_id: tool_call_id,
      tool_name: tool_name,
      effective_access: seed.effective_access,
      timeout_ms: seed.timeout_ms,
      deadline_at_ms: Map.get(seed, :deadline_at_ms),
      idempotency_key: idempotency_key,
      metadata: Map.get(seed, :metadata, %{})
    }
  end
end
