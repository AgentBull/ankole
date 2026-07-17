defmodule Ankole.Schedule.Planner do
  @moduledoc false

  alias Ankole.Schedule.Attrs
  alias Ankole.SystemConfig
  alias Ankole.TimeZone
  alias Crontab.CronExpression.Parser, as: CronParser
  alias Crontab.Scheduler, as: CronScheduler

  @min_delay_ms 1_000
  @max_horizon_ms 366 * 24 * 60 * 60 * 1_000
  @max_timezone_candidate_rejections 10_000

  @spec next_fire_after(map(), String.t(), DateTime.t()) ::
          {:ok, DateTime.t()} | {:error, term()}
  def next_fire_after(schedule, timezone, %DateTime{} = after_at)
      when is_map(schedule) and is_binary(timezone) do
    case Attrs.map_text(schedule, "kind") do
      "every" -> next_every_fire_after(schedule, after_at)
      "cron" -> next_cron_fire_after(schedule, timezone, after_at)
      _kind -> {:error, :invalid_schedule_kind}
    end
  end

  @spec normalize_schedule_json(map(), map(), keyword()) ::
          {:ok, map(), String.t()} | {:error, term()}
  def normalize_schedule_json(schedule, attrs, opts) when is_map(schedule) do
    case Attrs.map_text(schedule, "kind") do
      "every" ->
        with {:ok, timezone} <- schedule_timezone(schedule, attrs, opts),
             {:ok, every_ms} <- Attrs.positive_integer(schedule, "every_ms"),
             {:ok, anchor_at} <- absolute_datetime(Attrs.map_text(schedule, "anchor_at")) do
          {:ok,
           %{
             "kind" => "every",
             "every_ms" => every_ms,
             "anchor_at" => DateTime.to_iso8601(anchor_at)
           }, timezone}
        end

      "cron" ->
        with {:ok, timezone} <- schedule_timezone(schedule, attrs, opts),
             {:ok, expression} <- Attrs.required_text(schedule, "expression"),
             {:ok, normalized_expression} <- validate_cron_expression(expression),
             {:ok, stagger_ms} <- Attrs.non_negative_integer(schedule, "stagger_ms", 0) do
          {:ok,
           %{
             "kind" => "cron",
             "expression" => normalized_expression,
             "timezone" => timezone,
             "stagger_ms" => stagger_ms
           }, timezone}
        end

      _kind ->
        {:error, :invalid_schedule_kind}
    end
  end

  def normalize_schedule_json(_schedule, _attrs, _opts), do: {:error, :invalid_schedule}

  @spec parse_checkback_due(map(), String.t(), DateTime.t(), keyword()) ::
          {:ok, DateTime.t()} | {:error, term()}
  def parse_checkback_due(schedule, timezone, now, _opts) when is_map(schedule) do
    after_value = Attrs.map_value(schedule, "after")
    at_value = Map.get(schedule, "at")

    case {after_value, at_value} do
      {%{} = after_map, nil} -> parse_after(after_map, now)
      {nil, at} when is_binary(at) -> parse_at(at, timezone)
      _other -> {:error, :checkback_requires_exactly_one_time}
    end
  end

  def parse_checkback_due(_schedule, _timezone, _now, _opts), do: {:error, :invalid_schedule}

  @spec validate_bounds(DateTime.t(), DateTime.t(), keyword()) :: :ok | {:error, term()}
  def validate_bounds(%DateTime{} = due_at, %DateTime{} = now, opts) do
    min_delay_ms = Keyword.get(opts, :min_delay_ms, @min_delay_ms)
    max_horizon_ms = Keyword.get(opts, :max_horizon_ms, @max_horizon_ms)

    cond do
      DateTime.compare(due_at, DateTime.add(now, min_delay_ms, :millisecond)) == :lt ->
        {:error, :schedule_too_soon}

      DateTime.compare(due_at, DateTime.add(now, max_horizon_ms, :millisecond)) == :gt ->
        {:error, :schedule_too_far}

      true ->
        :ok
    end
  end

  @spec schedule_timezone(map() | nil, map() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def schedule_timezone(schedule, attrs, opts) do
    timezone =
      Attrs.map_text(schedule || %{}, "timezone") ||
        Attrs.map_text(attrs || %{}, "timezone") ||
        Keyword.get(opts, :timezone)

    case timezone do
      value when is_binary(value) -> TimeZone.validate(value)
      _value -> SystemConfig.timezone()
    end
  end

  @spec datetime(DateTime.t() | NaiveDateTime.t() | nil) :: String.t() | nil
  def datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  def datetime(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
  def datetime(nil), do: nil

  defp parse_after(after_map, now) do
    with {:ok, value} <- Attrs.positive_integer(after_map, "value"),
         {:ok, unit_ms} <- duration_unit_ms(Attrs.map_text(after_map, "unit")) do
      {:ok, DateTime.add(now, value * unit_ms, :millisecond)}
    end
  end

  defp parse_at(value, timezone) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        DateTime.shift_zone(datetime, "Etc/UTC")

      {:error, _reason} ->
        parse_local_at(value, timezone)
    end
  end

  defp parse_local_at(value, timezone) do
    with {:ok, naive} <- NaiveDateTime.from_iso8601(value) do
      naive
      |> NaiveDateTime.to_date()
      |> TimeZone.resolve_local(Time.truncate(NaiveDateTime.to_time(naive), :second), timezone)
      |> shift_to_utc()
    else
      _error -> {:error, :invalid_at}
    end
  end

  defp next_every_fire_after(schedule, %DateTime{} = after_at) do
    with {:ok, every_ms} <- Attrs.positive_integer(schedule, "every_ms"),
         {:ok, anchor_at} <- absolute_datetime(Attrs.map_text(schedule, "anchor_at")) do
      case DateTime.compare(anchor_at, after_at) do
        :gt ->
          {:ok, anchor_at}

        _comparison ->
          delta_ms = DateTime.diff(after_at, anchor_at, :millisecond)
          steps = div(delta_ms, every_ms) + 1
          {:ok, DateTime.add(anchor_at, steps * every_ms, :millisecond)}
      end
    end
  end

  defp next_cron_fire_after(schedule, timezone, %DateTime{} = after_at) do
    with {:ok, timezone} <- TimeZone.validate(timezone),
         {:ok, local_after} <- TimeZone.shift(after_at, timezone),
         {:ok, expression} <- Attrs.required_text(schedule, "expression"),
         {:ok, cron_expression} <- parse_cron_expression(expression),
         {:ok, stagger_ms} <- Attrs.non_negative_integer(schedule, "stagger_ms", 0),
         {:ok, local_next} <-
           next_cron_local(
             cron_expression,
             DateTime.to_naive(local_after),
             timezone,
             after_at,
             @max_timezone_candidate_rejections
           ),
         {:ok, utc_next} <- TimeZone.shift(local_next, "Etc/UTC") do
      {:ok, DateTime.add(utc_next, stagger_ms, :millisecond)}
    end
  end

  defp next_cron_local(_cron_expression, _cursor, _timezone, _after_at, 0) do
    {:error, :cron_timezone_resolution_exhausted}
  end

  defp next_cron_local(cron_expression, cursor, timezone, after_at, attempts_left) do
    search_from = NaiveDateTime.add(cursor, 1, :microsecond)

    with {:ok, candidate} <- CronScheduler.get_next_run_date(cron_expression, search_from),
         {:ok, resolved} <- TimeZone.resolve_local(candidate, timezone) do
      case DateTime.compare(resolved, after_at) do
        :gt ->
          {:ok, resolved}

        _comparison ->
          next_cron_local(
            cron_expression,
            candidate,
            timezone,
            after_at,
            attempts_left - 1
          )
      end
    end
  end

  defp validate_cron_expression(expression) do
    with {:ok, _cron_expression} <- parse_cron_expression(expression) do
      expression
      |> String.split(~r/\s+/, trim: true)
      |> Enum.join(" ")
      |> then(&{:ok, &1})
    end
  end

  defp parse_cron_expression(expression) when is_binary(expression) do
    fields = String.split(expression, ~r/\s+/, trim: true)

    case fields do
      [_minute, _hour, _day, _month, _weekday] ->
        parse_cron_fields(fields, false)

      [_second, _minute, _hour, _day, _month, _weekday] ->
        parse_cron_fields(fields, true)

      _fields ->
        {:error, :invalid_cron_expression}
    end
  end

  defp parse_cron_fields(fields, extended?) do
    case CronParser.parse(Enum.join(fields, " "), extended?) do
      {:ok, cron_expression} -> {:ok, cron_expression}
      {:error, _reason} -> {:error, :invalid_cron_expression}
    end
  end

  defp shift_to_utc({:ok, %DateTime{} = datetime}), do: TimeZone.shift(datetime, "Etc/UTC")
  defp shift_to_utc({:error, _reason} = error), do: error

  defp absolute_datetime(value) when is_binary(value) do
    with {:ok, datetime, _offset} <- DateTime.from_iso8601(value),
         {:ok, utc} <- DateTime.shift_zone(datetime, "Etc/UTC") do
      {:ok, utc}
    else
      _error -> {:error, :invalid_datetime}
    end
  end

  defp absolute_datetime(_value), do: {:error, :invalid_datetime}

  defp duration_unit_ms(unit) do
    case unit do
      "millisecond" -> {:ok, 1}
      "milliseconds" -> {:ok, 1}
      "second" -> {:ok, 1_000}
      "seconds" -> {:ok, 1_000}
      "minute" -> {:ok, 60_000}
      "minutes" -> {:ok, 60_000}
      "hour" -> {:ok, 3_600_000}
      "hours" -> {:ok, 3_600_000}
      "day" -> {:ok, 86_400_000}
      "days" -> {:ok, 86_400_000}
      "week" -> {:ok, 604_800_000}
      "weeks" -> {:ok, 604_800_000}
      _unit -> {:error, :invalid_duration_unit}
    end
  end
end
