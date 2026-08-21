defmodule Ankole.SignalsGateway.ReplyPresentation do
  @moduledoc """
  Provider-neutral, renderer-safe projection of one visible Agent reply.

  This is deliberately a bounded JSON map rather than provider card JSON. The
  worker may describe semantic work, but only this module decides which fields
  can reach an IM renderer or durable terminal outbox. Transient reasoning is
  kept only in the live value and is removed from checkpoints and every
  non-working state. A live phase label stays in working checkpoints for
  recovery, but every non-working state removes it before rendering or durable
  delivery.
  """

  alias Ankole.I18n

  @schema_version 1
  @terminal_states ~w(awaiting_input completed continued failed stopped scheduled)
  @states ["debouncing", "working" | @terminal_states]
  @plan_statuses ~w(pending in_progress completed cancelled)
  @activity_phases ~w(pending running completed failed)
  @action_types ~w(button form)
  @interaction_statuses ~w(pending answered superseded)
  @result_kinds ~w(table chart image artifact metrics)
  @trigger_context_kinds ~w(background_agent_job_failure scheduled_task)

  @max_thought_chars 4_000
  @max_plan_items 24
  @max_plan_item_chars 500
  @max_activities 20
  @max_activity_label_chars 120
  @max_results 12
  @max_receipts 20
  @max_actions 8
  @max_interaction_answer_chars 1_000
  @max_table_columns 8
  @max_table_rows 20
  @max_chart_series 6
  @max_chart_points 40
  @max_trigger_title_chars 160
  @max_trigger_summary_chars 800

  @type t :: %{String.t() => term()}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %{
      "schema_version" => @schema_version,
      "state" => normalize_state(Keyword.get(opts, :state, "debouncing")),
      "revision" => 0,
      "answer" => "",
      "activities" => %{},
      "results" => [],
      "receipts" => [],
      "actions" => [],
      "meta" => %{}
    }
  end

  @doc """
  Normalizes a persisted or caller-provided snapshot back into the closed
  presentation contract.
  """
  @spec normalize(map() | nil) :: t()
  def normalize(nil), do: new()

  def normalize(presentation) when is_map(presentation) do
    base = new(state: text(presentation, "state") || "working")

    base
    |> Map.put("revision", non_negative_integer(value(presentation, "revision")))
    |> Map.put("answer", answer_text(value(presentation, "answer")))
    |> Ankole.Attrs.maybe_put(
      "thought",
      bounded_optional_text(value(presentation, "thought"), @max_thought_chars)
    )
    |> Ankole.Attrs.maybe_put("plan", normalize_plan(value(presentation, "plan")))
    |> Map.put("activities", normalize_activities(value(presentation, "activities")))
    |> Map.put("results", normalize_results(value(presentation, "results")))
    |> Map.put("receipts", normalize_receipts(value(presentation, "receipts")))
    |> Map.put("actions", normalize_actions(value(presentation, "actions")))
    |> Ankole.Attrs.maybe_put(
      "trigger_context",
      normalize_trigger_context(value(presentation, "trigger_context"))
    )
    |> Map.put("meta", normalize_meta(value(presentation, "meta")))
    |> normalize_interaction_status(value(presentation, "interaction_status"))
    |> normalize_interaction_answer(value(presentation, "interaction_answer"))
    |> remove_transient_fields_unless_working()
  end

  def normalize(_presentation), do: new()

  @spec append_answer(t(), String.t()) :: t()
  def append_answer(presentation, delta) when is_map(presentation) and is_binary(delta) do
    presentation = normalize(presentation)
    answer = presentation["answer"] <> delta

    presentation
    |> Map.put("state", working_state(presentation["state"]))
    |> Map.put("answer", answer)
    |> bump_revision()
  end

  def append_answer(presentation, _delta), do: normalize(presentation)

  @spec replace_answer(t(), String.t()) :: t()
  def replace_answer(presentation, answer) when is_map(presentation) and is_binary(answer) do
    presentation
    |> normalize()
    |> Map.put("answer", answer)
    |> bump_revision()
  end

  @doc """
  Merges one turn-fenced semantic event. Unknown kinds and stale revisions are
  ignored. Event-specific clauses copy only closed, renderer-safe fields.
  """
  @spec apply_event(t(), String.t() | atom(), map()) :: t()
  def apply_event(presentation, kind, payload) when is_map(payload) do
    presentation = normalize(presentation)
    kind = to_string(kind)

    case kind do
      "turn.phase" -> apply_phase(presentation, payload)
      "reasoning.delta" -> apply_reasoning_delta(presentation, payload)
      "plan.snapshot" -> apply_plan_snapshot(presentation, payload)
      "tool.activity" -> apply_activity(presentation, payload)
      "effect.receipt" -> apply_receipt(presentation, payload, "effect")
      "result.table" -> apply_result(presentation, payload, "table")
      "result.chart" -> apply_result(presentation, payload, "chart")
      "artifact.available" -> apply_result(presentation, payload, "artifact")
      "result.image" -> apply_result(presentation, payload, "image")
      "result.metrics" -> apply_result(presentation, payload, "metrics")
      "interaction.request" -> apply_interaction_request(presentation, payload)
      _unknown -> presentation
    end
  end

  def apply_event(presentation, _kind, _payload), do: normalize(presentation)

  @doc """
  Projects the internal event that triggered a visible Agent turn into bounded
  renderer context. The projection is deterministic and never model-authored.
  """
  @spec project_trigger(t(), String.t(), map()) :: t()
  def project_trigger(presentation, "background_agent_job.failed", payload)
      when is_map(payload) do
    presentation = normalize(presentation)
    data = value(payload, "data")

    trigger_context =
      normalize_trigger_context(%{
        "kind" => "background_agent_job_failure",
        "title" => value(data, "title"),
        "summary" => value(data, "result_summary")
      })

    Ankole.Attrs.maybe_put(presentation, "trigger_context", trigger_context)
  end

  def project_trigger(presentation, "cron.fire", payload) when is_map(payload) do
    presentation = normalize(presentation)
    wake_payload = payload |> value("data") |> value("wake_payload")

    if value(wake_payload, "trigger") in [nil, "scheduled"] do
      Map.put(presentation, "trigger_context", %{"kind" => "scheduled_task"})
    else
      presentation
    end
  end

  def project_trigger(presentation, _event_type, _payload), do: normalize(presentation)

  @doc """
  Returns the bounded crash-recovery projection. Original reasoning is never
  durable presentation truth.
  """
  @spec checkpoint(t()) :: t()
  def checkpoint(presentation) do
    presentation
    |> normalize()
    |> Map.delete("thought")
  end

  @doc """
  Builds exact terminal truth from a live or checkpointed presentation.
  """
  @spec terminal(t(), String.t() | atom(), String.t() | nil) :: t()
  def terminal(presentation, state, answer) do
    state = normalize_state(state)
    state = if state in @terminal_states, do: state, else: "completed"

    presentation
    |> normalize()
    |> Map.put("state", state)
    |> Map.put("answer", terminal_answer(answer))
    |> remove_transient_fields_unless_working()
    |> terminalize_plan()
    |> bump_revision()
  end

  @doc """
  Freezes one visible reply fragment when a steer moves later work to a new
  card. The existing answer, plan, activities, results, and receipts remain
  exact. Transient thought and controls do not cross the presentation owner
  boundary.
  """
  @spec continued(t()) :: t()
  def continued(presentation) do
    presentation = normalize(presentation)

    if presentation["state"] == "continued" do
      presentation
    else
      presentation
      |> Map.put("state", "continued")
      |> Map.put("actions", [])
      |> Map.delete("prompt")
      |> Map.delete("thought")
      |> Map.delete("interaction_status")
      |> Map.delete("interaction_answer")
      |> bump_revision()
    end
  end

  @spec fallback_text(t()) :: String.t()
  def fallback_text(presentation) do
    presentation = normalize(presentation)
    answer = String.trim(presentation["answer"] || "")

    cond do
      answer != "" ->
        answer

      presentation["state"] == "awaiting_input" ->
        text(presentation, "prompt") || I18n.t("signals_gateway.reply.needs_input")

      presentation["state"] == "failed" ->
        I18n.t("signals_gateway.reply.task_failed")

      presentation["state"] == "stopped" ->
        I18n.t("signals_gateway.reply.task_stopped")

      true ->
        I18n.t("signals_gateway.reply.no_content")
    end
  end

  @spec terminal_state?(t()) :: boolean()
  def terminal_state?(presentation), do: normalize(presentation)["state"] in @terminal_states

  @doc """
  Projects one terminal reply-interaction result into the visible presentation.

  The durable interaction state is provider-neutral. Renderers receive the
  resulting locked controls, terminal status, and bounded display text for an
  accepted answer. They never decide whether an answer still counts.
  """
  @spec resolve_interaction(t(), String.t(), map() | nil) :: t()
  def resolve_interaction(presentation, status, answer \\ nil)

  def resolve_interaction(presentation, status, answer)
      when status in ["answered", "superseded"] do
    presentation = normalize(presentation)

    if presentation["state"] == "awaiting_input" and presentation["actions"] != [] do
      option_id = if is_map(answer), do: value(answer, "option_id")

      actions =
        Enum.map(presentation["actions"], fn action ->
          action
          |> Map.put("disabled", true)
          |> maybe_put_selected(status, option_id)
        end)

      interaction_answer = resolved_interaction_answer(status, answer, actions)

      resolved =
        presentation
        |> Map.put("actions", actions)
        |> Map.put("interaction_status", status)
        |> put_or_delete("interaction_answer", interaction_answer)

      if resolved == presentation do
        presentation
      else
        bump_revision(resolved)
      end
    else
      presentation
    end
  end

  def resolve_interaction(presentation, _status, _answer), do: normalize(presentation)

  defp apply_phase(presentation, payload) do
    revision = revision(payload)

    if revision < presentation["revision"] do
      presentation
    else
      state = normalize_state(value(payload, "state") || value(payload, "phase"))

      presentation
      |> Map.put("state", state)
      |> Map.put("revision", max(presentation["revision"], revision))
      |> maybe_put_meta("status", localized_optional_text(payload, "label", 160))
      |> remove_transient_fields_unless_working()
    end
  end

  defp apply_reasoning_delta(%{"state" => state} = presentation, _payload)
       when state != "working" and state != "debouncing",
       do: presentation

  defp apply_reasoning_delta(presentation, payload) do
    case bounded_optional_text(
           value(payload, "text") || value(payload, "delta"),
           @max_thought_chars
         ) do
      nil ->
        presentation

      delta ->
        current = Map.get(presentation, "thought") || ""
        thought = rolling_text(current <> delta, @max_thought_chars)

        presentation
        |> Map.put("state", "working")
        |> Map.put("thought", thought)
        |> put_revision(payload)
    end
  end

  defp apply_plan_snapshot(presentation, payload) do
    incoming = normalize_plan(payload)
    current_revision = get_in(presentation, ["plan", "revision"]) || -1

    cond do
      is_nil(incoming) -> presentation
      incoming["revision"] < current_revision -> presentation
      true -> presentation |> Map.put("plan", incoming) |> put_revision(payload)
    end
  end

  defp apply_activity(presentation, payload) do
    operation_id = operation_id(payload)
    current = get_in(presentation, ["activities", operation_id])
    incoming_revision = revision(payload)
    current_revision = if is_map(current), do: current["revision"] || 0, else: -1

    if is_nil(operation_id) or incoming_revision < current_revision do
      presentation
    else
      activity = %{
        "operation_id" => operation_id,
        "revision" => incoming_revision,
        "phase" => normalize_in(value(payload, "phase"), @activity_phases, "running"),
        "label" =>
          localized_text(payload, "label", default_activity_label(), @max_activity_label_chars),
        "consequential" => value(payload, "consequential") == true
      }

      activities =
        presentation["activities"]
        |> Map.put(operation_id, activity)
        |> trim_map(@max_activities)

      presentation
      |> Map.put("state", working_state(presentation["state"]))
      |> Map.put("activities", activities)
      |> put_revision(payload)
    end
  end

  defp apply_receipt(presentation, payload, kind) do
    operation_id = operation_id(payload)
    phase = to_string(value(payload, "phase") || "")

    if is_nil(operation_id) or phase not in ["confirmed", "completed"] do
      presentation
    else
      receipt =
        %{
          "kind" => kind,
          "operation_id" => operation_id,
          "revision" => revision(payload),
          "summary" =>
            localized_text(
              payload,
              "summary",
              I18n.t("signals_gateway.reply.activity.completed"),
              500
            )
        }
        |> Ankole.Attrs.maybe_put("scope", localized_optional_text(payload, "scope", 160))
        |> Ankole.Attrs.maybe_put("target", bounded_optional_text(value(payload, "target"), 240))
        |> Ankole.Attrs.maybe_put("follow_up", localized_optional_text(payload, "follow_up", 240))

      receipts = upsert_by_id(presentation["receipts"], receipt, "operation_id", @max_receipts)

      presentation
      |> Map.put("receipts", receipts)
      |> put_revision(payload)
    end
  end

  defp apply_result(presentation, payload, kind) do
    operation_id = operation_id(payload)
    result = normalize_result(Map.put(string_key_map(payload), "kind", kind))

    if is_nil(operation_id) or is_nil(result) do
      presentation
    else
      result = Map.put(result, "operation_id", operation_id)
      results = upsert_by_id(presentation["results"], result, "operation_id", @max_results)

      presentation
      |> Map.put("results", results)
      |> put_revision(payload)
    end
  end

  defp apply_interaction_request(presentation, payload) do
    prompt = bounded_optional_text(value(payload, "prompt"), 2_000)
    actions = normalize_actions(value(payload, "controls"))

    if is_nil(prompt) or actions == [] do
      presentation
    else
      presentation
      |> Map.put("state", "awaiting_input")
      |> Map.put("prompt", prompt)
      |> Map.put("actions", actions)
      |> Map.put("interaction_status", "pending")
      |> Map.delete("interaction_answer")
      |> remove_transient_fields_unless_working()
      |> put_revision(payload)
    end
  end

  defp normalize_plan(plan) when is_map(plan) do
    items =
      plan
      |> value("items")
      |> list()
      |> Enum.take(@max_plan_items)
      |> Enum.flat_map(fn
        item when is_map(item) ->
          id = bounded_optional_text(value(item, "id"), 80)
          content = bounded_optional_text(value(item, "content"), @max_plan_item_chars)

          if is_nil(id) or is_nil(content) do
            []
          else
            [
              %{
                "id" => id,
                "content" => content,
                "status" => normalize_in(value(item, "status"), @plan_statuses, "pending")
              }
            ]
          end

        _item ->
          []
      end)

    if items == [] do
      nil
    else
      %{
        "operation_id" => operation_id(plan) || "plan",
        "revision" => revision(plan),
        "items" => items,
        "summary" => plan_summary(items)
      }
      |> Ankole.Attrs.maybe_put("folded", optional_boolean(value(plan, "folded")))
    end
  end

  defp normalize_plan(_plan), do: nil

  defp normalize_activities(activities) when is_map(activities) do
    activities
    |> Enum.reduce(%{}, fn {id, activity}, acc ->
      case activity do
        %{} ->
          safe = %{
            "operation_id" => bounded_text(id, 100),
            "revision" => revision(activity),
            "phase" => normalize_in(value(activity, "phase"), @activity_phases, "running"),
            "label" =>
              bounded_text(
                value(activity, "label") || default_activity_label(),
                @max_activity_label_chars
              ),
            "consequential" => value(activity, "consequential") == true
          }

          Map.put(acc, safe["operation_id"], safe)

        _activity ->
          acc
      end
    end)
    |> trim_map(@max_activities)
  end

  defp normalize_activities(_activities), do: %{}

  defp localized_text(payload, field, default, max_chars) do
    localized_optional_text(payload, field, max_chars) || bounded_text(default, max_chars)
  end

  defp localized_optional_text(payload, field, max_chars) do
    key = bounded_optional_text(value(payload, "#{field}_key"), 160)

    text =
      if is_binary(key) and String.starts_with?(key, "signals_gateway.reply.activity.") do
        I18n.t(key, activity_bindings(value(payload, "#{field}_bindings")))
      else
        value(payload, field)
      end

    bounded_optional_text(text, max_chars)
  end

  defp activity_bindings(bindings) when is_map(bindings) do
    bindings
    |> Enum.take(8)
    |> Map.new(fn {key, value} ->
      {bounded_text(key, 64), scalar_text(value, @max_activity_label_chars)}
    end)
  end

  defp activity_bindings(_bindings), do: %{}

  defp default_activity_label, do: I18n.t("signals_gateway.reply.activity.processing")

  defp normalize_results(results),
    do:
      results
      |> list()
      |> Enum.map(&normalize_result/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(@max_results)

  defp normalize_result(result) when is_map(result) do
    kind = normalize_in(value(result, "kind"), @result_kinds, nil)
    operation_id = operation_id(result)

    case kind do
      "table" -> normalize_table(result, operation_id)
      "chart" -> normalize_chart(result, operation_id)
      "image" -> normalize_image(result, operation_id)
      "artifact" -> normalize_artifact(result, operation_id)
      "metrics" -> normalize_metrics(result, operation_id)
      _kind -> nil
    end
  end

  defp normalize_result(_result), do: nil

  defp normalize_table(result, operation_id) do
    columns =
      result
      |> value("columns")
      |> list()
      |> Enum.take(@max_table_columns)
      |> Enum.flat_map(fn
        column when is_map(column) ->
          key = bounded_optional_text(value(column, "key"), 64)
          label = bounded_optional_text(value(column, "label"), 80)
          if key && label, do: [%{"key" => key, "label" => label}], else: []

        _column ->
          []
      end)

    rows =
      result
      |> value("rows")
      |> list()
      |> Enum.take(@max_table_rows)
      |> Enum.map(fn row ->
        Map.new(columns, fn %{"key" => key} -> {key, scalar_text(value(row, key), 240)} end)
      end)

    if columns == [] do
      nil
    else
      base_result("table", result, operation_id)
      |> Map.put("columns", columns)
      |> Map.put("rows", rows)
    end
  end

  defp normalize_chart(result, operation_id) do
    series =
      result
      |> value("series")
      |> list()
      |> Enum.take(@max_chart_series)
      |> Enum.flat_map(fn
        item when is_map(item) ->
          name = bounded_optional_text(value(item, "name"), 80)

          points =
            item
            |> value("points")
            |> list()
            |> Enum.take(@max_chart_points)
            |> Enum.flat_map(fn
              point when is_map(point) ->
                case numeric(value(point, "value")) do
                  nil ->
                    []

                  number ->
                    [%{"label" => scalar_text(value(point, "label"), 80), "value" => number}]
                end

              _point ->
                []
            end)

          if name && points != [], do: [%{"name" => name, "points" => points}], else: []

        _item ->
          []
      end)

    if series == [] do
      nil
    else
      base_result("chart", result, operation_id)
      |> Map.put("series", series)
      |> Ankole.Attrs.maybe_put("unit", bounded_optional_text(value(result, "unit"), 40))
      |> Ankole.Attrs.maybe_put("takeaway", bounded_optional_text(value(result, "takeaway"), 500))
    end
  end

  defp normalize_image(result, operation_id) do
    image_key = bounded_optional_text(value(result, "image_key"), 240)
    alt = bounded_optional_text(value(result, "alt"), 240)

    if image_key && alt do
      base_result("image", result, operation_id)
      |> Map.put("image_key", image_key)
      |> Map.put("alt", alt)
      |> Ankole.Attrs.maybe_put("caption", bounded_optional_text(value(result, "caption"), 300))
    end
  end

  defp normalize_artifact(result, operation_id) do
    name = bounded_optional_text(value(result, "name"), 240)
    url = bounded_optional_text(value(result, "url"), 1_000)

    if name && safe_url?(url) do
      base_result("artifact", result, operation_id)
      |> Map.put("name", name)
      |> Map.put("url", url)
      |> Ankole.Attrs.maybe_put(
        "description",
        bounded_optional_text(value(result, "description"), 500)
      )
    end
  end

  defp normalize_metrics(result, operation_id) do
    metrics =
      result
      |> value("metrics")
      |> list()
      |> Enum.take(6)
      |> Enum.flat_map(fn
        metric when is_map(metric) ->
          label = bounded_optional_text(value(metric, "label"), 80)
          metric_value = bounded_optional_text(value(metric, "value"), 120)
          if label && metric_value, do: [%{"label" => label, "value" => metric_value}], else: []

        _metric ->
          []
      end)

    if metrics == [],
      do: nil,
      else: base_result("metrics", result, operation_id) |> Map.put("metrics", metrics)
  end

  defp base_result(kind, result, operation_id) do
    %{
      "kind" => kind,
      "operation_id" => operation_id || "#{kind}-#{revision(result)}",
      "revision" => revision(result)
    }
    |> Ankole.Attrs.maybe_put("title", bounded_optional_text(value(result, "title"), 160))
  end

  defp normalize_receipts(receipts) do
    receipts
    |> list()
    |> Enum.flat_map(fn
      receipt when is_map(receipt) ->
        operation_id = operation_id(receipt)
        summary = bounded_optional_text(value(receipt, "summary"), 500)

        if operation_id && summary do
          [
            %{
              "kind" => normalize_in(value(receipt, "kind"), ["memory", "effect"], "effect"),
              "operation_id" => operation_id,
              "revision" => revision(receipt),
              "summary" => summary
            }
            |> Ankole.Attrs.maybe_put(
              "scope",
              bounded_optional_text(value(receipt, "scope"), 160)
            )
            |> Ankole.Attrs.maybe_put(
              "target",
              bounded_optional_text(value(receipt, "target"), 240)
            )
            |> Ankole.Attrs.maybe_put(
              "follow_up",
              bounded_optional_text(value(receipt, "follow_up"), 240)
            )
          ]
        else
          []
        end

      _receipt ->
        []
    end)
    |> Enum.take(@max_receipts)
  end

  defp normalize_actions(actions) do
    actions
    |> list()
    |> Enum.flat_map(fn
      action when is_map(action) ->
        type = normalize_in(value(action, "type"), @action_types, nil)
        id = bounded_optional_text(value(action, "id"), 80)
        label = bounded_optional_text(value(action, "label"), 200)
        fields = normalize_form_fields(value(action, "fields"))

        if type && id && label && valid_action_fields?(type, fields) do
          [
            %{
              "type" => type,
              "id" => id,
              "label" => label,
              "style" =>
                normalize_in(value(action, "style"), ["primary", "default", "danger"], "default")
            }
            |> Ankole.Attrs.maybe_put(
              "interaction_id",
              bounded_optional_text(value(action, "interaction_id"), 120)
            )
            |> Ankole.Attrs.maybe_put(
              "source_actor_event_id",
              bounded_optional_text(value(action, "source_actor_event_id"), 80)
            )
            |> Ankole.Attrs.maybe_put(
              "control_id",
              bounded_optional_text(value(action, "control_id"), 80)
            )
            |> Ankole.Attrs.maybe_put(
              "selected_option_id",
              bounded_optional_text(value(action, "selected_option_id"), 80)
            )
            |> Ankole.Attrs.maybe_put(
              "option_value",
              bounded_optional_text(value(action, "option_value"), 500)
            )
            |> Ankole.Attrs.maybe_put(
              "description",
              bounded_optional_text(value(action, "description"), 500)
            )
            |> Ankole.Attrs.maybe_put(
              "revision",
              optional_non_negative_integer(value(action, "revision"))
            )
            |> Ankole.Attrs.maybe_put("disabled", optional_boolean(value(action, "disabled")))
            |> Ankole.Attrs.maybe_put("selected", optional_boolean(value(action, "selected")))
            |> Ankole.Attrs.maybe_put("fields", fields)
          ]
        else
          []
        end

      _action ->
        []
    end)
    |> Enum.take(@max_actions)
  end

  defp normalize_form_fields(fields) do
    fields
    |> list()
    |> Enum.take(8)
    |> Enum.flat_map(fn
      field when is_map(field) ->
        id = bounded_optional_text(value(field, "id"), 80)
        label = bounded_optional_text(value(field, "label"), 80)
        type = normalize_in(value(field, "type"), ~w(input), nil)

        if id && label && type do
          [
            %{
              "id" => id,
              "label" => label,
              "type" => type,
              "required" => value(field, "required") == true
            }
            |> Ankole.Attrs.maybe_put(
              "placeholder",
              bounded_optional_text(value(field, "placeholder"), 240)
            )
            |> Ankole.Attrs.maybe_put("multiline", optional_boolean(value(field, "multiline")))
            |> Ankole.Attrs.maybe_put(
              "max_length",
              bounded_positive_integer(value(field, "max_length"), 1_000)
            )
          ]
        else
          []
        end

      _field ->
        []
    end)
    |> case do
      [] -> nil
      values -> values
    end
  end

  defp normalize_meta(meta) when is_map(meta) do
    %{}
    |> Ankole.Attrs.maybe_put("status", bounded_optional_text(value(meta, "status"), 160))
    |> Ankole.Attrs.maybe_put(
      "source_count",
      optional_non_negative_integer(value(meta, "source_count"))
    )
    |> Ankole.Attrs.maybe_put(
      "memory_source_count",
      optional_non_negative_integer(value(meta, "memory_source_count"))
    )
    |> Ankole.Attrs.maybe_put(
      "elapsed_ms",
      optional_non_negative_integer(value(meta, "elapsed_ms"))
    )
    |> Ankole.Attrs.maybe_put(
      "attachment_count",
      optional_non_negative_integer(value(meta, "attachment_count"))
    )
  end

  defp normalize_meta(_meta), do: %{}

  defp normalize_trigger_context(context) when is_map(context) do
    kind = normalize_in(value(context, "kind"), @trigger_context_kinds, nil)

    case kind do
      "scheduled_task" ->
        %{"kind" => "scheduled_task"}

      "background_agent_job_failure" ->
        title = bounded_single_line_text(value(context, "title"), @max_trigger_title_chars)

        if title do
          %{
            "kind" => kind,
            "title" => title
          }
          |> Ankole.Attrs.maybe_put(
            "summary",
            bounded_single_line_text(value(context, "summary"), @max_trigger_summary_chars)
          )
        end

      _unknown ->
        nil
    end
  end

  defp normalize_trigger_context(_context), do: nil

  defp valid_action_fields?("button", _fields), do: true
  defp valid_action_fields?("form", [%{"type" => "input"}]), do: true
  defp valid_action_fields?(_type, _fields), do: false

  defp normalize_interaction_status(
         %{"state" => "awaiting_input", "actions" => [_ | _]} = presentation,
         status
       ) do
    Map.put(
      presentation,
      "interaction_status",
      normalize_in(status, @interaction_statuses, "pending")
    )
  end

  defp normalize_interaction_status(presentation, _status),
    do: Map.delete(presentation, "interaction_status")

  defp normalize_interaction_answer(
         %{"state" => "awaiting_input", "interaction_status" => "answered"} = presentation,
         answer
       ) do
    put_or_delete(
      presentation,
      "interaction_answer",
      bounded_optional_text(answer, @max_interaction_answer_chars)
    )
  end

  defp normalize_interaction_answer(presentation, _answer),
    do: Map.delete(presentation, "interaction_answer")

  defp resolved_interaction_answer("answered", answer, actions) when is_map(answer) do
    kind = value(answer, "kind")
    interaction_id = bounded_optional_text(value(answer, "interaction_id"), 120)
    option_id = bounded_optional_text(value(answer, "option_id"), 80)
    answer_text = bounded_optional_text(value(answer, "value"), @max_interaction_answer_chars)

    case {kind, interaction_id, option_id, answer_text} do
      {"choice", interaction_id, option_id, answer_text}
      when is_binary(interaction_id) and is_binary(option_id) and is_binary(answer_text) ->
        selected_choice_label(actions, interaction_id, option_id) || answer_text

      {"free_text", interaction_id, _option_id, answer_text}
      when is_binary(interaction_id) and is_binary(answer_text) ->
        answer_text

      _invalid ->
        nil
    end
  end

  defp resolved_interaction_answer(_status, _answer, _actions), do: nil

  defp selected_choice_label(actions, interaction_id, option_id) do
    Enum.find_value(actions, fn
      %{
        "type" => "button",
        "interaction_id" => ^interaction_id,
        "selected_option_id" => ^option_id,
        "label" => label
      }
      when is_binary(label) ->
        label

      _action ->
        nil
    end)
  end

  defp maybe_put_selected(action, "answered", option_id) when is_binary(option_id) do
    Map.put(action, "selected", action["selected_option_id"] == option_id)
  end

  defp maybe_put_selected(action, _status, _option_id), do: Map.delete(action, "selected")

  defp bounded_positive_integer(value, max) when is_integer(value) and value > 0,
    do: min(value, max)

  defp bounded_positive_integer(_value, _max), do: nil

  defp optional_boolean(value) when is_boolean(value), do: value
  defp optional_boolean(_value), do: nil

  defp terminalize_plan(%{"plan" => %{} = plan} = presentation) do
    incomplete? =
      Enum.any?(plan["items"], &(&1["status"] in ["pending", "in_progress", "cancelled"]))

    if incomplete? do
      presentation
    else
      put_in(presentation, ["plan", "folded"], true)
    end
  end

  defp terminalize_plan(presentation), do: presentation

  defp remove_transient_fields_unless_working(%{"state" => state} = presentation)
       when state in ["debouncing", "working"],
       do: presentation

  defp remove_transient_fields_unless_working(presentation) do
    presentation
    |> Map.delete("thought")
    |> update_in(["meta"], &Map.delete(&1, "status"))
  end

  defp plan_summary(items) do
    total = length(items)
    completed = Enum.count(items, &(&1["status"] == "completed"))
    in_progress = Enum.find(items, &(&1["status"] == "in_progress"))

    %{"total" => total, "completed" => completed}
    |> Ankole.Attrs.maybe_put("current_item_id", if(in_progress, do: in_progress["id"]))
  end

  defp upsert_by_id(items, item, key, limit) do
    items
    |> Enum.reject(&(value(&1, key) == item[key]))
    |> Kernel.++([item])
    |> Enum.take(-limit)
  end

  defp trim_map(map, limit) when map_size(map) <= limit, do: map

  defp trim_map(map, limit) do
    map
    |> Enum.sort_by(fn {_key, value} -> value["revision"] || 0 end, :desc)
    |> Enum.take(limit)
    |> Map.new()
  end

  defp put_revision(presentation, payload) do
    Map.put(presentation, "revision", max(presentation["revision"], revision(payload)))
  end

  defp bump_revision(presentation), do: Map.update!(presentation, "revision", &(&1 + 1))

  defp maybe_put_meta(presentation, _key, nil), do: presentation

  defp maybe_put_meta(presentation, key, value) do
    Map.update!(presentation, "meta", &Map.put(&1, key, value))
  end

  defp terminal_answer(answer) when is_binary(answer) do
    case String.trim(answer) do
      "" -> I18n.t("signals_gateway.reply.no_content")
      _text -> answer
    end
  end

  defp terminal_answer(_answer), do: I18n.t("signals_gateway.reply.no_content")

  defp working_state(state) when state in ["debouncing", "working"], do: "working"
  defp working_state(state), do: state

  defp normalize_state(state) do
    state = to_string(state || "working")
    if state in @states, do: state, else: "working"
  end

  defp normalize_in(value, allowed, default) do
    normalized = if is_atom(value) or is_binary(value), do: to_string(value)
    if normalized in allowed, do: normalized, else: default
  end

  defp revision(map), do: non_negative_integer(value(map, "revision"))

  defp operation_id(map) do
    bounded_optional_text(
      value(map, "operation_id") || value(map, "call_id") || value(map, "id"),
      100
    )
  end

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer(_value), do: 0
  defp optional_non_negative_integer(value) when is_integer(value) and value >= 0, do: value
  defp optional_non_negative_integer(_value), do: nil

  defp numeric(value) when is_integer(value) or is_float(value), do: value
  defp numeric(_value), do: nil

  defp bounded_text(value, max_chars) do
    value
    |> to_safe_string()
    |> String.slice(0, max_chars)
  end

  defp bounded_optional_text(value, max_chars) do
    case bounded_text(value, max_chars) |> String.trim() do
      "" -> nil
      text -> text
    end
  end

  defp bounded_single_line_text(value, max_chars) do
    value
    |> to_safe_string()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> case do
      "" ->
        nil

      text ->
        if String.length(text) <= max_chars,
          do: text,
          else: String.slice(text, 0, max_chars - 1) <> "…"
    end
  end

  defp rolling_text(value, max_chars) do
    length = String.length(value)
    if length <= max_chars, do: value, else: String.slice(value, length - max_chars, max_chars)
  end

  defp scalar_text(value, max_chars) when is_binary(value), do: bounded_text(value, max_chars)

  defp scalar_text(value, _max_chars) when is_number(value) or is_boolean(value),
    do: to_string(value)

  defp scalar_text(nil, _max_chars), do: ""
  defp scalar_text(_value, _max_chars), do: ""

  defp to_safe_string(value) when is_binary(value), do: value
  defp to_safe_string(nil), do: ""
  defp to_safe_string(value) when is_atom(value), do: Atom.to_string(value)
  defp to_safe_string(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp to_safe_string(_value), do: ""

  defp safe_url?(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["https", "http"] -> true
      _uri -> false
    end
  end

  defp safe_url?(_url), do: false

  defp list(values) when is_list(values), do: values
  defp list(_values), do: []

  defp text(map, key), do: bounded_optional_text(value(map, key), 8_000)

  defp answer_text(value) when is_binary(value), do: value
  defp answer_text(nil), do: ""
  defp answer_text(value), do: to_safe_string(value)

  defp put_or_delete(map, key, nil), do: Map.delete(map, key)
  defp put_or_delete(map, key, value), do: Map.put(map, key, value)

  defp string_key_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp value(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        case Enum.find(map, fn
               {map_key, _value} when is_atom(map_key) -> Atom.to_string(map_key) == key
               _entry -> false
             end) do
          {_map_key, value} -> value
          nil -> nil
        end
    end
  end

  defp value(_map, _key), do: nil
end
