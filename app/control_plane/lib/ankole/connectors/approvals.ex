defmodule Ankole.Connectors.Approvals do
  @moduledoc """
  Lean Composio / `qm`-grade write-approval policy and single-use ActionCard
  binding for external Connector and Skill MCP tool calls.
  """

  alias Ankole.AuthZ.Actor

  @max_argument_bytes 16_384
  @sensitive_key_regex ~r/(?:secret|token|password|passwd|api[_-]?key|authorization|cookie|private[_-]?key)/i

  @doc "Evaluates the 3-value `approval` policy (`annotations` | `all` | `none`)."
  def needs_approval?(metadata_or_declaration, tool_name, annotations, options \\ %{}) do
    if approved_execution?(options) do
      false
    else
      meta = metadata_or_declaration || %{}
      policy = Map.get(meta, "approval", "annotations")
      tools = meta |> Map.get("approval_tools", []) |> List.wrap()
      anns = annotations || %{}
      read_only? = anns["readOnlyHint"] == true
      destructive? = anns["destructiveHint"] == true

      case policy do
        "none" -> false
        "all" -> not read_only?
        _annotations -> (destructive? and not read_only?) or tool_name in tools
      end
    end
  end

  def intercept_or_allow(
        target,
        tool_name,
        annotations,
        args,
        context,
        options,
        policy_source,
        connection_meta
      ) do
    if not needs_approval?(policy_source, tool_name, annotations, options) do
      :allow
    else
      canonical = canonical_json(args)

      if byte_size(canonical) > @max_argument_bytes do
        {:halt,
         {:error,
          %{
            code: "approval_arguments_too_large",
            retryable: false,
            request_sent: false,
            message:
              "Tool arguments exceed the 16 KB human approval card limit. Split or summarize the payload before calling this tool."
          }}}
      else
        case interactive_turn(context) do
          nil ->
            {:halt,
             {:error,
              %{
                code: "approval_unavailable",
                retryable: false,
                request_sent: false,
                message:
                  "This connector tool requires human approval. Invoke it from a conversation, or set this connection's approval policy to 'none' for unattended automation."
              }}}

          turn ->
            tool_key = call_identity_key(target, tool_name, connection_meta)
            digest = sha256_hex(tool_key <> "\n" <> canonical)
            destructive? = (annotations || %{})["destructiveHint"] == true
            preview = preview_json(args)

            payload =
              Map.merge(connection_meta, %{
                "target" => encode_target(target),
                "tool_name" => tool_name,
                "destructive" => destructive?,
                "arguments" => args,
                "arguments_preview" => preview,
                "args_sha256" => digest
              })

            display_connection =
              connection_meta["connection_name"] || connection_meta["connection"] ||
                connection_meta["server"] || "connector"

            account_label =
              non_empty_label(connection_meta["account"]) ||
                non_empty_label(connection_meta["account_owner_uid"])

            summary_target =
              if account_label,
                do: "#{display_connection} (#{account_label})",
                else: display_connection

            summary =
              "Run #{summary_target} · #{tool_name}"
              |> String.slice(0, 500)

            case Ankole.Conversations.prepare_connector_action_card(
                   turn,
                   digest,
                   summary,
                   payload
                 ) do
              {:ok, card} ->
                {:halt,
                 {:error,
                  %{
                    code: "approval_required",
                    card_id: card.id,
                    retryable: false,
                    request_sent: false,
                    message:
                      "An approval card for this exact call is waiting for human confirmation in the conversation. When approved, Ankole executes this exact call once and posts the result—do not call it again."
                  }}}

              {:error, {:approval_already_pending_in_turn, existing}} ->
                {:halt,
                 {:error,
                  %{
                    code: "approval_already_pending",
                    card_id: existing.id,
                    retryable: false,
                    request_sent: false,
                    message:
                      "Another connector write approval (#{existing.summary}) is already pending for this turn. Finish your reply so the user can confirm that action card first, then invoke this tool after confirmation."
                  }}}

              {:error, reason} ->
                {:halt,
                 {:error,
                  %{
                    code: "approval_card_failed",
                    retryable: false,
                    request_sent: false,
                    message: "Could not prepare connector approval card: #{inspect(reason)}"
                  }}}
            end
        end
      end
    end
  end

  def verify_locked_payload(
        %{
          "target" => encoded_target,
          "tool_name" => tool_name,
          "arguments" => args,
          "args_sha256" => expected_digest
        } = payload
      )
      when is_map(encoded_target) and is_binary(tool_name) and is_map(args) and
             is_binary(expected_digest) do
    with {:ok, target} <- decode_target(encoded_target) do
      actual =
        sha256_hex(call_identity_key(target, tool_name, payload) <> "\n" <> canonical_json(args))

      if actual == expected_digest, do: {:ok, target, tool_name, args}, else: {:error, :tampered}
    end
  end

  def verify_locked_payload(_), do: {:error, :invalid_payload}

  def format_recovered_receipt(tool_name, connection_label, %{
        status: "succeeded",
        external_ref: ref
      }) do
    ref_suffix = if is_binary(ref) and ref != "", do: " (ref: #{ref})", else: ""

    {"ok",
     "Executed #{connection_label} · #{tool_name} once with the locked arguments#{ref_suffix}."}
  end

  def format_recovered_receipt(tool_name, connection_label, %{http_status: http_status}) do
    detail =
      if is_integer(http_status),
        do: "HTTP #{http_status}",
        else: "interrupted before completion"

    {"error",
     "#{connection_label} · #{tool_name} failed (upstream outcome uncertain; inspect before retrying): #{detail}"}
  end

  def format_execution_receipt(tool_name, connection_label, {:ok, result}) do
    snippet =
      case result do
        %{"structuredContent" => structured} -> bounded_json(structured, 800)
        %{"content" => [%{"text" => text} | _]} when is_binary(text) -> String.slice(text, 0, 800)
        other -> bounded_json(other, 800)
      end

    {"ok",
     "Executed #{connection_label} · #{tool_name} once with the locked arguments. Result: #{snippet}"}
  end

  def format_execution_receipt(tool_name, connection_label, {:error, error}) do
    message = if is_map(error), do: Ankole.Attrs.get_truthy(error, :message)
    code = if is_map(error), do: Ankole.Attrs.get_truthy(error, :code)

    detail =
      cond do
        is_binary(message) -> message
        is_binary(code) -> code
        true -> inspect(error)
      end
      |> String.slice(0, 600)

    uncertain_suffix =
      if Ankole.Connectors.WriteReceipts.uncertain_failure?(error),
        do: " (upstream outcome uncertain; inspect before retrying)",
        else: ""

    {"error", "#{connection_label} · #{tool_name} failed#{uncertain_suffix}: #{detail}"}
  end

  def canonical_json(value) do
    value
    |> canonicalize()
    |> Jason.encode!()
  end

  defp canonicalize(map) when is_map(map) and not is_struct(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), canonicalize(v)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonicalize(list) when is_list(list), do: Enum.map(list, &canonicalize/1)
  defp canonicalize(other), do: other

  defp preview_json(args) do
    args
    |> redact_sensitive()
    |> Jason.encode!(pretty: true)
    |> String.slice(0, 4_000)
  end

  defp redact_sensitive(map) when is_map(map) and not is_struct(map) do
    Map.new(map, fn {k, v} ->
      key = to_string(k)

      if Regex.match?(@sensitive_key_regex, key) and not is_nil(v) and v != "" do
        {key, "[REDACTED]"}
      else
        {key, redact_sensitive(v)}
      end
    end)
  end

  defp redact_sensitive(list) when is_list(list), do: Enum.map(list, &redact_sensitive/1)
  defp redact_sensitive(other), do: other

  defp bounded_json(value, limit) do
    value
    |> redact_sensitive()
    |> Jason.encode!()
    |> String.slice(0, limit)
  rescue
    _ -> value |> inspect() |> String.slice(0, limit)
  end

  defp sha256_hex(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  defp approved_execution?(options) when is_map(options),
    do: Map.get(options, :approved_card) == true or Map.get(options, "approved_card") == true

  defp approved_execution?(options) when is_list(options),
    do: Keyword.get(options, :approved_card) == true

  defp approved_execution?(_), do: false

  defp call_identity_key({:toolkit, id}, tool_name, meta) when is_map(meta) do
    auth_config_id = meta["auth_config_id"] || ""
    account_id = meta["account_id"] || "app"
    "toolkit:#{id}:#{auth_config_id}:#{account_id}:#{tool_name}"
  end

  defp call_identity_key({:skill, skill, server}, tool_name, _meta),
    do: "skill:#{skill}:#{server}:#{tool_name}"

  defp non_empty_label(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed != "", do: trimmed
  end

  defp non_empty_label(_), do: nil

  defp encode_target({:toolkit, id}), do: %{"kind" => "toolkit", "toolkit" => id}

  defp encode_target({:skill, skill, server}),
    do: %{"kind" => "skill", "skill" => skill, "server" => server}

  defp decode_target(%{"kind" => "toolkit", "toolkit" => id}) when is_binary(id),
    do: {:ok, {:toolkit, id}}

  defp decode_target(%{"kind" => "skill", "skill" => skill, "server" => server})
       when is_binary(skill) and is_binary(server),
       do: {:ok, {:skill, skill, server}}

  defp decode_target(_), do: {:error, :invalid_target}

  defp interactive_turn(%{
         actor: %Actor{
           principal: %{uid: agent_uid},
           turn_authority: {%Ankole.Sessions.RunRef{} = ref, _}
         }
       }) do
    with {:conversation, conversation_id} <- Ankole.Sessions.Key.parse(ref.session_id),
         {:ok, conversation} when not is_nil(conversation) <-
           Ankole.Conversations.get_conversation(conversation_id) do
      origin_conversation_id =
        case Ankole.Conversations.peer_exchange(conversation.id) do
          %{origin_conversation_id: id} when is_binary(id) -> id
          _ -> conversation.id
        end

      %{
        conversation_id: origin_conversation_id,
        session_id: ref.session_id,
        agent_uid: agent_uid,
        signal_id: ref.signal_id
      }
    else
      _ -> nil
    end
  end

  defp interactive_turn(_), do: nil
end
