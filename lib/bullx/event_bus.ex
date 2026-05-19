defmodule BullX.EventBus do
  @moduledoc """
  EventBus acceptance API — BullX's transport-agnostic Event dispatch layer.

  ## The shape of the system

  In an OpenClaw / Hermes-style agent harness, channels (Slack, Discord, cron,
  webhooks) deliver into one ambient assistant loop; the assistant is the
  subject and the channels are its inputs. BullX inverts that: channels emit
  normalized **Events** into one Bus, and operator-defined **Event Routing
  Rules** decide which **Target** (most commonly an `BullX.AIAgent`) handles
  each Event and inside which scope.

  Inbound events from IM channels, webhooks, schedulers, and internal
  callbacks are normalized to CloudEvents by `BullX.EventBus.ChannelAdapter`
  implementations and flow through one acceptance boundary — `accept/2`. The
  bus then:

  1. Matches the event against operator-defined Event Routing Rules
     (declarative match expressions evaluated by a Rust NIF — see
     `BullX.EventBus.RoutingTable`).
  2. Resolves a **TargetSession** for the matched rule + scope/window
     (`BullX.EventBus.TargetSession.Resolver`) — the durable per-window
     work-queue that serializes events to one consumer.
  3. Appends the event to that session and invokes the rule's Target.

  ## What this buys

  One Agent can be reached by a Discord DM, a Slack mention, a `/command`,
  or a scheduled tick without the Agent code knowing the source. A noisy
  group channel and a 1-on-1 DM with the same Agent are routed to *separate*
  TargetSessions, so observing the group doesn't pollute the DM's generation
  state. And the same Event can deliberately fan out to multiple Targets
  (e.g. an AIAgent for judgment and a Workflow for an audit log) via
  separate rules — routing is a declared, inspectable artifact rather than
  prompt plumbing.

  ## Acceptance boundary

  `accept/2` is the decoded CloudEvents-to-TargetSession handoff boundary. It
  validates the Event, matches one Event Routing Rule, and commits weak runtime
  handoff state for non-Blackhole Targets. Normalized command Events that do not
  match an explicit command rule may reuse the addressed-message route for the
  same channel and scope while preserving the original command Event.
  """

  import Ecto.Query

  require Logger

  alias BullX.EventBus.{
    Accepted,
    AppendFailed,
    Dedupe,
    EventRoutingRule,
    RoutingContext,
    RoutingTable,
    TargetSession,
    TargetSessionEntry,
    Validator
  }

  alias BullX.EventBus.TargetSession.{Job, Resolver, Worker}
  alias BullX.Repo

  @spec accept(map(), keyword()) ::
          {:ok, Accepted.t()}
          | {:error, BullX.EventBus.InvalidEvent.t() | :no_match | AppendFailed.t()}
  def accept(event_json, opts \\ []) when is_list(opts) do
    metadata = %{event_type: event_type(event_json)}
    :telemetry.execute([:bullx, :event_bus, :accept, :start], %{}, metadata)

    try do
      result = do_accept(event_json)
      emit_accept_stop(result, metadata)
      result
    rescue
      exception ->
        emit_accept_exception(exception, metadata)
        reraise exception, __STACKTRACE__
    end
  end

  defp do_accept(event_json) do
    with {:ok, event} <- Validator.validate(event_json),
         routing_context <- RoutingContext.project(event),
         {:ok, route_result} <- route(routing_context) do
      accept_route_result(route_result, event)
    else
      {:error, %AppendFailed{} = error} ->
        {:error, error}

      {:error, error} ->
        {:error, error}
    end
  end

  defp accept_route_result({:no_match, diagnostics}, _event) do
    emit_matcher_diagnostics(diagnostics)
    {:error, :no_match}
  end

  defp accept_route_result({:ignored_command, diagnostics}, event) do
    emit_matcher_diagnostics(diagnostics)

    accepted = %Accepted{
      status: :accepted_ignored,
      event_source: event["source"],
      event_id: event["id"]
    }

    :telemetry.execute([:bullx, :event_bus, :accepted_ignored], %{}, %{
      rule_id: nil,
      event_type: event["type"]
    })

    {:ok, accepted}
  end

  defp accept_route_result(
         {:matched, %EventRoutingRule{} = rule, routing_context, diagnostics},
         event
       ) do
    emit_matcher_diagnostics(diagnostics)
    emit_rule_matched(rule, event)
    accept_matched(rule, event, routing_context)
  end

  @spec ensure_active_target_session_jobs() :: :ok | {:error, term()}
  defdelegate ensure_active_target_session_jobs, to: BullX.EventBus.Repair

  defp route(routing_context) do
    with {:ok, route_result} <- RoutingTable.match(routing_context) do
      route_or_fallback(route_result, routing_context)
    end
  end

  defp route_or_fallback({:matched, %EventRoutingRule{} = rule, diagnostics}, routing_context) do
    {:ok, {:matched, rule, routing_context, diagnostics}}
  end

  # Commands fall back to the addressed-message rule for the same channel/scope
  # when no explicit command rule matches. This lets operators wire a single
  # `bullx.im.message.addressed` rule for an Agent and have slash commands
  # (e.g. `/reset`) reach the same TargetSession without a separate routing
  # rule. The original command Event is preserved — only the routing context's
  # `type` is rewritten for matching purposes.
  defp route_or_fallback({:no_match, diagnostics}, %{"type" => "bullx.command.invoked"} = context) do
    context
    |> addressed_command_context()
    |> RoutingTable.match()
    |> command_fallback_result(context, diagnostics)
  end

  defp route_or_fallback({:no_match, diagnostics}, _routing_context) do
    {:ok, {:no_match, diagnostics}}
  end

  defp addressed_command_context(context) do
    Map.put(context, "type", "bullx.im.message.addressed")
  end

  defp command_fallback_result(
         {:ok, {:matched, %EventRoutingRule{} = rule, fallback_diagnostics}},
         original_context,
         diagnostics
       ) do
    fallback_context = addressed_command_context(original_context)
    {:ok, {:matched, rule, fallback_context, diagnostics ++ fallback_diagnostics}}
  end

  defp command_fallback_result(
         {:ok, {:no_match, fallback_diagnostics}},
         original_context,
         diagnostics
       ) do
    Logger.warning("EventBus command fallback ignored unmatched command",
      event_source: original_context["source"],
      event_id: get_in(original_context, ["event", "id"]),
      command_name: get_in(original_context, ["routing_facts", "command_name"])
    )

    {:ok, {:ignored_command, diagnostics ++ fallback_diagnostics}}
  end

  defp command_fallback_result({:error, reason}, _original_context, _diagnostics) do
    {:error, reason}
  end

  defp accept_matched(
         %EventRoutingRule{target_type: :blackhole} = rule,
         event,
         _routing_context
       ) do
    accepted = %Accepted{
      status: :accepted_ignored,
      event_source: event["source"],
      event_id: event["id"],
      rule_id: rule.id
    }

    :telemetry.execute([:bullx, :event_bus, :accepted_ignored], %{}, %{
      rule_id: rule.id,
      event_type: event["type"]
    })

    {:ok, accepted}
  end

  defp accept_matched(%EventRoutingRule{} = rule, event, routing_context) do
    with {:ok, dedupe_hash} <- Dedupe.hash(event["source"], event["id"]),
         :not_duplicate <- duplicate_lookup(dedupe_hash) do
      accept_routed(rule, event, routing_context, dedupe_hash)
    else
      {:duplicate, accepted} ->
        {:ok, accepted}

      {:error, %AppendFailed{} = error} ->
        {:error, error}

      {:error, error} ->
        {:error, error}
    end
  end

  defp accept_routed(%EventRoutingRule{} = rule, event, routing_context, dedupe_hash) do
    now = DateTime.utc_now(:microsecond)

    Repo.transaction(fn ->
      with {:ok, resolved} <- Resolver.resolve(rule, routing_context, now),
           {:ok, entry} <-
             append_entry(resolved.session, event, routing_context, dedupe_hash, now),
           {:ok, session} <- Job.ensure(resolved.session) do
        %Accepted{
          status: :accepted,
          event_source: event["source"],
          event_id: event["id"],
          rule_id: rule.id,
          target_session_id: session.id,
          side_channel_entry_id: entry.id
        }
      else
        {:error, %AppendFailed{} = error} ->
          Repo.rollback(error)

        {:error, %Ecto.Changeset{} = changeset} ->
          Repo.rollback(
            append_failed(:side_channel_append_failed, "side-channel append failed", changeset)
          )
      end
    end)
    |> case do
      {:ok, %Accepted{} = accepted} ->
        Worker.nudge(accepted.target_session_id)
        emit_accepted(accepted, rule, dedupe_hash)
        {:ok, accepted}

      {:error, {:dedupe_conflict, ^dedupe_hash}} ->
        duplicate_or_collision(dedupe_hash, event)

      {:error, %AppendFailed{} = error} ->
        {:error, error}
    end
  end

  defp append_entry(%TargetSession{} = session, event, routing_context, dedupe_hash, now) do
    %TargetSessionEntry{}
    |> TargetSessionEntry.changeset(%{
      target_session_id: session.id,
      event_source: event["source"],
      event_id: event["id"],
      dedupe_hash: dedupe_hash,
      cloud_event: event,
      routing_context: routing_context,
      appended_at: now
    })
    |> Repo.insert()
    |> case do
      {:ok, entry} ->
        {:ok, entry}

      {:error, %Ecto.Changeset{} = changeset} ->
        case dedupe_conflict?(changeset) do
          true ->
            Repo.rollback({:dedupe_conflict, dedupe_hash})

          false ->
            {:error,
             append_failed(:side_channel_append_failed, "side-channel append failed", changeset)}
        end
    end
  end

  defp duplicate_lookup(dedupe_hash) do
    case entry_by_dedupe_hash(dedupe_hash) do
      nil -> :not_duplicate
      %TargetSessionEntry{} = entry -> duplicate_from_entry(entry)
    end
  end

  defp duplicate_or_collision(dedupe_hash, event) do
    case entry_by_dedupe_hash(dedupe_hash) do
      %TargetSessionEntry{} = entry ->
        duplicate_or_collision_from_entry(entry, dedupe_hash, event)

      nil ->
        {:error,
         %AppendFailed{
           code: :dedupe_hash_collision,
           message: "dedupe conflict row disappeared",
           details: %{"dedupe_hash" => dedupe_hash}
         }}
    end
  end

  defp duplicate_or_collision_from_entry(%TargetSessionEntry{} = entry, dedupe_hash, event) do
    case entry.event_source == event["source"] and entry.event_id == event["id"] do
      true ->
        accepted_duplicate(entry)

      false ->
        {:error,
         %AppendFailed{
           code: :dedupe_hash_collision,
           message: "dedupe hash collision",
           details: %{"dedupe_hash" => dedupe_hash}
         }}
    end
  end

  defp duplicate_from_entry(%TargetSessionEntry{} = entry) do
    case accepted_duplicate(entry) do
      {:ok, accepted} -> {:duplicate, accepted}
      {:error, error} -> {:error, error}
    end
  end

  defp accepted_duplicate(%TargetSessionEntry{} = entry) do
    with {:ok, session} <- duplicate_session(entry.target_session_id) do
      if session do
        Worker.nudge(entry.target_session_id)
      end

      {:ok,
       %Accepted{
         status: :duplicate,
         event_source: entry.event_source,
         event_id: entry.event_id,
         rule_id: session && session.event_routing_rule_id,
         target_session_id: entry.target_session_id,
         side_channel_entry_id: entry.id
       }}
    end
  end

  defp duplicate_session(target_session_id) do
    case Repo.get(TargetSession, target_session_id) do
      %TargetSession{status: :active} = session -> Job.ensure(session)
      %TargetSession{} = session -> {:ok, session}
      nil -> {:ok, nil}
    end
  end

  defp entry_by_dedupe_hash(dedupe_hash) do
    Repo.one(from e in TargetSessionEntry, where: e.dedupe_hash == ^dedupe_hash)
  end

  defp dedupe_conflict?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {:dedupe_hash, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
      _error -> false
    end)
  end

  defp append_failed(code, message, details) do
    %AppendFailed{code: code, message: message, details: safe_details(details)}
  end

  defp safe_details(%Ecto.Changeset{}), do: %{"reason" => "changeset"}
  defp safe_details(details) when is_map(details), do: details
  defp safe_details(details), do: %{"reason" => inspect(details, limit: 5, printable_limit: 120)}

  defp event_type(%{"type" => type}) when is_binary(type), do: type
  defp event_type(_event), do: nil

  defp emit_accepted(%Accepted{} = accepted, %EventRoutingRule{} = rule, dedupe_hash) do
    :telemetry.execute([:bullx, :event_bus, :accepted], %{}, %{
      rule_id: rule.id,
      target_session_id: accepted.target_session_id,
      target_session_entry_id: accepted.side_channel_entry_id,
      target_type: rule.target_type,
      status: accepted.status,
      dedupe_hash: dedupe_hash
    })
  end

  defp emit_rule_matched(%EventRoutingRule{} = rule, event) do
    :telemetry.execute([:bullx, :event_bus, :rule_matched], %{}, %{
      rule_id: rule.id,
      target_type: rule.target_type,
      event_type: event["type"]
    })
  end

  defp emit_matcher_diagnostics(diagnostics) do
    Enum.each(diagnostics, fn
      {rule_id, kind, reason} ->
        :telemetry.execute([:bullx, :event_bus, :matcher, :diagnostic], %{}, %{
          rule_id: rule_id,
          diagnostic_code: kind,
          reason: safe_diagnostic_reason(reason)
        })

      _diagnostic ->
        :ok
    end)
  end

  defp safe_diagnostic_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 200)
  defp safe_diagnostic_reason(reason), do: inspect(reason, limit: 5, printable_limit: 120)

  defp emit_accept_stop({:ok, %Accepted{status: :duplicate} = accepted}, metadata) do
    :telemetry.execute(
      [:bullx, :event_bus, :duplicate],
      %{},
      Map.put(metadata, :target_session_id, accepted.target_session_id)
    )

    :telemetry.execute(
      [:bullx, :event_bus, :accept, :stop],
      %{},
      Map.put(metadata, :status, :duplicate)
    )
  end

  defp emit_accept_stop({:ok, %Accepted{} = accepted}, metadata) do
    :telemetry.execute(
      [:bullx, :event_bus, :accept, :stop],
      %{},
      Map.put(metadata, :status, accepted.status)
    )
  end

  defp emit_accept_stop({:error, %AppendFailed{} = error}, metadata) do
    :telemetry.execute(
      [:bullx, :event_bus, :append_failed],
      %{},
      Map.put(metadata, :diagnostic_code, error.code)
    )

    :telemetry.execute(
      [:bullx, :event_bus, :accept, :stop],
      %{},
      Map.put(metadata, :status, :error)
    )
  end

  defp emit_accept_stop({:error, reason}, metadata) do
    :telemetry.execute(
      [:bullx, :event_bus, :accept, :stop],
      %{},
      Map.merge(metadata, %{status: :error, diagnostic_code: diagnostic_code(reason)})
    )
  end

  defp emit_accept_exception(exception, metadata) do
    :telemetry.execute(
      [:bullx, :event_bus, :accept, :exception],
      %{duration: 0},
      Map.merge(metadata, %{
        kind: :error,
        reason: exception.__struct__
      })
    )
  end

  defp diagnostic_code(reason) when is_atom(reason), do: reason
  defp diagnostic_code(%{code: code}), do: code
  defp diagnostic_code(_reason), do: :error
end
