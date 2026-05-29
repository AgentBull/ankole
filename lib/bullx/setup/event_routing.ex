defmodule BullX.Setup.EventRouting do
  @moduledoc false

  import Ecto.Query

  alias BullX.MailBox.Matcher
  alias BullX.MailBox.DeliveryRule
  alias BullX.Repo
  alias BullX.RuleEngine.CEL
  alias BullX.Setup.{AIAgents, ChannelSources}

  @setup_route_types [
    "bullx.message.received",
    "bullx.message.edited",
    "bullx.message.recalled",
    "bullx.message.deleted",
    "bullx.command.invoked"
  ]

  @spec status(map()) :: map()
  def status(session \\ %{}) do
    with {:ok, agent} <- selected_agent(session),
         {:ok, source} <- ChannelSources.first_ready_source() do
      status_for_source(source, agent)
    else
      {:error, reason} -> prerequisite_missing(reason)
    end
  end

  @spec save(map()) :: {:ok, map()} | {:error, map()}
  def save(session \\ %{}) do
    with {:ok, agent} <- selected_agent(session),
         {:ok, source} <- ChannelSources.first_ready_source(),
         attrs <- rule_attrs(source, agent.principal.uid),
         {:ok, rule} <- upsert_setup_rule(source, attrs),
         :ok <- live_rule_matches?(rule, source, agent.principal.uid) do
      {:ok,
       %{rule: public_rule(rule), source: public_source(source), target: public_agent(agent)}}
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp selected_agent(session) do
    status = AIAgents.status(session)

    case status.selected_agent do
      %{principal_uid: uid} when is_binary(uid) ->
        BullX.Principals.list_active_agents()
        |> Enum.find(&(&1.principal.uid == uid))
        |> case do
          nil -> {:error, :agent_not_found}
          agent -> {:ok, agent}
        end

      _other ->
        {:error, :agent_not_configured}
    end
  end

  defp status_for_source(source, agent) do
    base = base_projection(source, agent)

    case setup_rule(source, agent.principal.uid) do
      {:ok, rule} -> live_status(base, rule, source, agent.principal.uid)
      {:error, :setup_rule_missing} -> base
      {:error, {:setup_rule_targets_different_agent, rule}} -> target_mismatch(base, rule)
    end
  end

  defp live_status(base, rule, source, agent_uid) do
    case live_rule_matches?(rule, source, agent_uid) do
      :ok -> %{base | complete?: true, state: "live", reason: nil, live_rule: public_rule(rule)}
      {:error, {:routing_conflict, conflict_rule}} -> routing_conflict(base, rule, conflict_rule)
      {:error, :routing_no_match} -> routing_no_match(base, rule)
      {:error, reason} -> routing_error(base, rule, reason)
    end
  end

  defp base_projection(source, agent) do
    %{
      complete?: false,
      state: "missing",
      reason: "setup_rule_missing",
      source: public_source(source),
      target: public_agent(agent),
      expected_rule: public_rule_attrs(source, agent.principal.uid),
      live_rule: nil,
      conflict_rule: nil
    }
  end

  defp prerequisite_missing(reason) do
    %{
      complete?: false,
      state: "prerequisite_missing",
      reason: reason_code(reason),
      source: nil,
      target: nil,
      expected_rule: nil,
      live_rule: nil,
      conflict_rule: nil
    }
  end

  defp target_mismatch(base, %DeliveryRule{} = rule) do
    %{
      base
      | state: "target_mismatch",
        reason: "setup_rule_targets_different_agent",
        conflict_rule: public_rule(rule)
    }
  end

  defp routing_conflict(base, %DeliveryRule{} = rule, conflict_rule) do
    %{
      base
      | state: "conflict",
        reason: "routing_conflict",
        live_rule: public_rule(rule),
        conflict_rule: conflict_rule
    }
  end

  defp routing_no_match(base, %DeliveryRule{} = rule) do
    %{base | state: "no_match", reason: "routing_no_match", live_rule: public_rule(rule)}
  end

  defp routing_error(base, %DeliveryRule{} = rule, reason) do
    %{base | state: "error", reason: reason_code(reason), live_rule: public_rule(rule)}
  end

  defp setup_rule(source, agent_uid) do
    case Repo.get_by(DeliveryRule, name: rule_name(source)) do
      %DeliveryRule{agent_uid: ^agent_uid} = rule ->
        {:ok, rule}

      %DeliveryRule{} = rule ->
        {:error, {:setup_rule_targets_different_agent, rule}}

      nil ->
        {:error, :setup_rule_missing}
    end
  end

  defp upsert_setup_rule(source, attrs) do
    name = rule_name(source)

    case Repo.get_by(DeliveryRule, name: name) do
      %DeliveryRule{} = rule ->
        rule
        |> DeliveryRule.changeset(attrs)
        |> Repo.update()

      nil ->
        attrs = Map.put(attrs, :name, name)

        %DeliveryRule{}
        |> DeliveryRule.changeset(attrs)
        |> Repo.insert()
    end
  end

  defp live_rule_matches?(%DeliveryRule{} = expected, source, agent_uid) do
    with {:ok, context} <- routing_context(source),
         {:ok, {:matched, matched_id, _diagnostics}} <- Matcher.match([expected], context) do
      case matched_id == expected.id and expected.agent_uid == agent_uid do
        true -> :ok
        false -> {:error, {:routing_conflict, public_rule(expected)}}
      end
    else
      {:ok, {:no_match, _diagnostics}} -> {:error, :routing_no_match}
      {:error, reason} -> {:error, reason}
    end
  end

  defp routing_context(%{setup_module: module, source: source}) do
    module.routing_sample(source)
  end

  defp rule_attrs(source, agent_uid) do
    %{
      active: true,
      priority: priority_for(rule_name(source)),
      match_expr: match_expr(source),
      agent_uid: agent_uid,
      attention: :addressed,
      session_key_template: nil
    }
  end

  defp priority_for(name) do
    case Repo.get_by(DeliveryRule, name: name) do
      %DeliveryRule{priority: priority} ->
        priority

      nil ->
        max_priority =
          Repo.one(
            from rule in DeliveryRule,
              where: rule.priority > 0,
              select: max(rule.priority)
          ) || 999

        max(max_priority + 1, 1000)
    end
  end

  defp match_expr(%{adapter_id: adapter_id, source_id: source_id}) do
    type_expr =
      @setup_route_types
      |> Enum.map(&["type == ", CEL.string_literal(&1)])
      |> Enum.intersperse(" || ")

    [
      "(",
      type_expr,
      ")",
      " && channel.adapter == ",
      CEL.string_literal(adapter_id),
      " && channel.id == ",
      CEL.string_literal(source_id)
    ]
    |> IO.iodata_to_binary()
  end

  defp rule_name(%{adapter_id: adapter_id, source_id: source_id}) do
    "setup.default.#{slug(adapter_id)}.#{slug(source_id)}.channel"
  end

  defp slug(value) do
    value = to_string(value)

    case Regex.match?(~r/\A[a-zA-Z0-9_.-]+\z/, value) do
      true -> value
      false -> "b64-" <> Base.url_encode64(value, padding: false)
    end
  end

  defp public_rule(%DeliveryRule{} = rule) do
    %{
      id: rule.id,
      name: rule.name,
      priority: rule.priority,
      match_expr: rule.match_expr,
      target_type: "agent",
      target_ref: rule.agent_uid,
      agent_uid: rule.agent_uid,
      attention: Atom.to_string(rule.attention),
      session_key_template: rule.session_key_template
    }
  end

  defp public_rule_attrs(source, agent_uid) do
    source
    |> rule_attrs(agent_uid)
    |> Map.put(:name, rule_name(source))
    |> Map.update!(:attention, &Atom.to_string/1)
    |> Map.put(:target_type, "agent")
    |> Map.put(:target_ref, agent_uid)
  end

  defp public_source(source) do
    source_config = Map.get(source, :source) || Map.get(source, "source") || %{}

    %{
      adapter_id: Map.get(source, :adapter_id) || Map.get(source, "adapter_id"),
      plugin_id: Map.get(source, :plugin_id) || Map.get(source, "plugin_id"),
      source_id: Map.get(source, :source_id) || Map.get(source, "source_id"),
      domain: Map.get(source_config, "domain") || Map.get(source_config, :domain),
      im_listen_mode:
        Map.get(source_config, "im_listen_mode") || Map.get(source_config, :im_listen_mode),
      runtime:
        public_runtime(Map.get(source_config, "runtime") || Map.get(source_config, :runtime))
    }
  end

  defp public_runtime(%{} = runtime) do
    %{
      ready: Map.get(runtime, "ready") || Map.get(runtime, :ready) || false
    }
  end

  defp public_runtime(_runtime), do: %{ready: false}

  defp public_agent(%{principal: principal}) do
    %{
      principal_uid: principal.uid,
      uid: principal.uid,
      display_name: principal.display_name
    }
  end

  defp reason_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_code(reason), do: inspect(reason)

  defp normalize_error(%Ecto.Changeset{} = changeset),
    do: %{message: "validation failed", errors: changeset_errors(changeset)}

  defp normalize_error({:routing_conflict, rule}), do: %{message: "routing conflict", rule: rule}
  defp normalize_error(reason), do: %{message: inspect(reason)}

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
