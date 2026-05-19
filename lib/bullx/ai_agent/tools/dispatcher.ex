defmodule BullX.AIAgent.Tools.Dispatcher do
  @moduledoc """
  Thin execution boundary for BullX-owned AIAgent tools.

  The dispatcher rechecks registry presence, profile enablement, effective
  access, ACL, and timeout before invoking the tool module.
  """

  alias BullX.AIAgent.{ACL, Profile, Tools}
  alias BullX.AIAgent.Tools.Error

  @spec execute(String.t(), atom(), map()) :: {:error, Error.t()}
  def execute(tool_name, expected_access, args)
      when is_binary(tool_name) and expected_access in [:ordinary, :privileged] and is_map(args) do
    {:error,
     Error.new(
       :tool_failed,
       "AIAgent tool execution requires runtime Conversation context.",
       true
     )}
  end

  def execute(_tool_name, _expected_access, _args) do
    {:error, Error.new(:tool_malformed_arguments, "Tool arguments are invalid.", false)}
  end

  @spec execute_with_context(String.t(), atom(), map(), map()) ::
          {:ok, ReqLLM.ToolResult.t() | String.t() | map() | list()} | {:error, Error.t()}
  def execute_with_context(tool_name, expected_access, seed, args)
      when is_binary(tool_name) and expected_access in [:ordinary, :privileged] and is_map(seed) and
             is_map(args) do
    execute(tool_name, expected_access, args, seed)
  end

  @spec execute(String.t(), atom(), map(), map()) ::
          {:ok, ReqLLM.ToolResult.t() | String.t() | map() | list()} | {:error, Error.t()}
  def execute(tool_name, expected_access, args, seed)
      when is_binary(tool_name) and expected_access in [:ordinary, :privileged] and is_map(args) and
             is_map(seed) do
    with {:ok, profile} <- fetch_profile(seed),
         {:ok, entry, access} <- Tools.effective_tool(profile, tool_name),
         :ok <- ensure_access_match(access, expected_access),
         :allowed <-
           ACL.authorize(
             seed.caller_principal_id,
             seed.agent_principal_id,
             access,
             Map.get(seed, :acl_context, %{})
           ),
         context <-
           Tools.build_context(
             Map.merge(seed, %{effective_access: access, timeout_ms: entry.timeout_ms}),
             %{
               id: seed.tool_call_id,
               name: tool_name,
               arguments: args
             }
           ),
         {:ok, result} <- run_tool(entry, args, context) do
      {:ok, result}
    else
      {:denied, _reason} ->
        {:error, Error.new(:tool_denied, message_for(:tool_denied), false)}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, :tool_unknown} ->
        {:error, Error.new(:tool_unknown, message_for(:tool_unknown), false)}

      {:error, :tool_disabled} ->
        {:error, Error.new(:tool_disabled, message_for(:tool_disabled), false)}

      {:error, :tool_denied} ->
        {:error, Error.new(:tool_denied, message_for(:tool_denied), false)}

      {:error, reason} ->
        {:error, Error.new(:tool_failed, safe_reason(reason), true)}
    end
  end

  def execute(_tool_name, _expected_access, _args, _seed) do
    {:error, Error.new(:tool_malformed_arguments, message_for(:tool_malformed_arguments), false)}
  end

  @spec execute_call(Profile.t(), map(), map(), map()) :: map()
  def execute_call(%Profile{} = profile, tool_call, seed, assistant_message) do
    tool_name = tool_call[:name] || tool_call["name"]
    tool_call_id = tool_call[:id] || tool_call["id"]
    args = tool_call[:arguments] || tool_call["arguments"] || %{}

    seed =
      seed
      |> Map.put(:profile, profile)
      |> Map.put(:tool_call_id, tool_call_id)
      |> Map.put(:assistant_message_id, assistant_message.id)

    result =
      with true <- is_binary(tool_name) and is_binary(tool_call_id),
           {:ok, _entry, access} <- Tools.effective_tool(profile, tool_name),
           :allowed <-
             ACL.authorize(
               seed.caller_principal_id,
               seed.agent_principal_id,
               access,
               Map.get(seed, :acl_context, %{})
             ),
           {:ok, value} <- execute(tool_name, access, args, seed) do
        %{
          "type" => "tool_result",
          "tool_call_id" => tool_call_id,
          "is_error" => false,
          "result" => normalize_tool_output(value)
        }
      else
        false ->
          tool_error_block(tool_call_id, :tool_malformed_arguments)

        {:denied, _reason} ->
          tool_error_block(tool_call_id, :tool_denied)

        {:error, :tool_unknown} ->
          tool_error_block(tool_call_id, :tool_unknown)

        {:error, :tool_disabled} ->
          tool_error_block(tool_call_id, :tool_disabled)

        {:error, %Error{} = error} ->
          tool_error_block(tool_call_id, error)

        {:error, _reason} ->
          tool_error_block(tool_call_id, :tool_failed)
      end

    result
  end

  defp fetch_profile(%{profile: %Profile{} = profile}), do: {:ok, profile}
  defp fetch_profile(_seed), do: {:error, :invalid_profile}

  defp ensure_access_match(access, access), do: :ok
  defp ensure_access_match(_access, _expected_access), do: {:error, :tool_denied}

  defp run_tool(entry, args, context) do
    task = Task.async(fn -> entry.module.execute(args, context) end)

    case Task.yield(task, entry.timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, %Error{} = error}} -> {:error, error}
      {:ok, {:error, reason}} -> {:error, Error.new(:tool_failed, safe_reason(reason), false)}
      nil -> {:error, Error.new(:tool_timeout, "Tool timed out.", true)}
      {:exit, _reason} -> {:error, Error.new(:tool_failed, "Tool failed.", false)}
    end
  end

  defp normalize_tool_output(%ReqLLM.ToolResult{} = result), do: Map.from_struct(result)
  defp normalize_tool_output(value) when is_binary(value), do: %{"text" => value}
  defp normalize_tool_output(value) when is_map(value), do: value
  defp normalize_tool_output(value) when is_list(value), do: value

  defp normalize_tool_output(value),
    do: %{"value" => inspect(value, limit: 10, printable_limit: 200)}

  defp tool_error_block(tool_call_id, %Error{} = error) do
    %{
      "type" => "tool_result",
      "tool_call_id" => tool_call_id || "missing_tool_call_id",
      "is_error" => true,
      "error" => Error.to_result(error)["error"]
    }
  end

  defp tool_error_block(tool_call_id, code),
    do: tool_error_block(tool_call_id, Error.new(code, message_for(code), false))

  defp message_for(:tool_unknown), do: "Tool is not available for this request."
  defp message_for(:tool_disabled), do: "Tool is not available for this request."
  defp message_for(:tool_denied), do: "Tool is not available for this request."
  defp message_for(:tool_malformed_arguments), do: "Tool arguments are invalid."
  defp message_for(:tool_timeout), do: "Tool timed out."
  defp message_for(:tool_failed), do: "Tool failed."

  defp safe_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 120)
  defp safe_reason(_reason), do: "Tool failed."
end
