defmodule Ankole.Schedule.Planner do
  @moduledoc false

  alias Ankole.Schedule.Attrs
  alias Ankole.SystemConfig

  @min_delay_ms 1_000
  @max_horizon_ms 366 * 24 * 60 * 60 * 1_000

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
             "stagger_ms" => stagger_ms,
             "day_match" => "and"
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
      value when is_binary(value) -> validate_timezone(value)
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
      |> datetime_in_timezone(NaiveDateTime.to_time(naive), timezone)
      |> to_utc()
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
    with {:ok, local_after} <- DateTime.shift_zone(after_at, timezone),
         {:ok, expression} <- Attrs.required_text(schedule, "expression"),
         {:ok, stagger_ms} <- Attrs.non_negative_integer(schedule, "stagger_ms", 0),
         {:ok, local_next} <- next_cron_local(expression, local_after),
         {:ok, utc_next} <- DateTime.shift_zone(local_next, "Etc/UTC") do
      {:ok, DateTime.add(utc_next, stagger_ms, :millisecond)}
    else
      {:error, _reason} = error -> error
    end
  end

  defp next_cron_local(expression, %DateTime{} = local_after) do
    fields = String.split(expression, ~r/\s+/, trim: true)

    case fields do
      [_minute, _hour, _day, _month, _weekday] ->
        with {:ok, expr} <- Oban.Plugins.Cron.parse(expression) do
          {:ok, Oban.Cron.Expression.next_at(expr, local_after)}
        end

      [seconds, minute, hour, day, month, weekday] ->
        five_field = Enum.join([minute, hour, day, month, weekday], " ")

        with {:ok, seconds} <- parse_cron_seconds(seconds),
             {:ok, expr} <- Oban.Plugins.Cron.parse(five_field) do
          {:ok, next_six_field_cron_local(expr, seconds, local_after)}
        end

      _fields ->
        {:error, :invalid_cron_expression}
    end
  end

  defp next_six_field_cron_local(expr, seconds, %DateTime{} = local_after) do
    minute_start = %{DateTime.truncate(local_after, :second) | second: 0}

    same_minute_second =
      if Oban.Cron.Expression.now?(expr, minute_start) do
        Enum.find(seconds, &(&1 > local_after.second))
      end

    case same_minute_second do
      second when is_integer(second) ->
        %{minute_start | second: second}

      _value ->
        next_minute = Oban.Cron.Expression.next_at(expr, local_after)
        %{next_minute | second: List.first(seconds)}
    end
  end

  defp validate_cron_expression(expression) do
    fields = String.split(expression, ~r/\s+/, trim: true)

    case fields do
      [_minute, _hour, _day, _month, _weekday] ->
        with {:ok, _expr} <- Oban.Plugins.Cron.parse(expression), do: {:ok, expression}

      [seconds, minute, hour, day, month, weekday] ->
        five_field = Enum.join([minute, hour, day, month, weekday], " ")

        with {:ok, _seconds} <- parse_cron_seconds(seconds),
             {:ok, _expr} <- Oban.Plugins.Cron.parse(five_field) do
          {:ok, expression}
        end

      _fields ->
        {:error, :invalid_cron_expression}
    end
  end

  defp parse_cron_seconds(field) when is_binary(field) do
    field
    |> String.split(",", trim: true)
    |> Enum.map(&parse_cron_second_part/1)
    |> Attrs.collect_results()
    |> case do
      {:ok, ranges} ->
        seconds =
          ranges
          |> Enum.flat_map(& &1)
          |> Enum.uniq()
          |> Enum.sort()

        case seconds != [] and Enum.all?(seconds, &(&1 in 0..59)) do
          true -> {:ok, seconds}
          false -> {:error, :invalid_cron_seconds}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_cron_second_part("*"), do: {:ok, Enum.to_list(0..59)}

  defp parse_cron_second_part("*/" <> step) do
    with {:ok, step} <- Attrs.parse_positive_integer(step) do
      {:ok, Enum.take_every(Enum.to_list(0..59), step)}
    end
  end

  defp parse_cron_second_part(part) do
    cond do
      String.contains?(part, "/") ->
        with [range, step] <- String.split(part, "/", parts: 2),
             {:ok, values} <- parse_cron_second_part(range),
             {:ok, step} <- Attrs.parse_positive_integer(step) do
          {:ok, Enum.take_every(values, step)}
        else
          _value -> {:error, :invalid_cron_seconds}
        end

      String.contains?(part, "-") ->
        with [left, right] <- String.split(part, "-", parts: 2),
             {:ok, left} <- Attrs.parse_non_negative_integer(left),
             {:ok, right} <- Attrs.parse_non_negative_integer(right),
             true <- left <= right do
          {:ok, Enum.to_list(left..right)}
        else
          _value -> {:error, :invalid_cron_seconds}
        end

      true ->
        with {:ok, second} <- Attrs.parse_non_negative_integer(part) do
          {:ok, [second]}
        end
    end
  end

  defp validate_timezone("UTC"), do: {:ok, "Etc/UTC"}

  defp validate_timezone(timezone) when is_binary(timezone) do
    case DateTime.now(timezone) do
      {:ok, _now} -> {:ok, timezone}
      {:error, reason} -> {:error, {:invalid_timezone, timezone, reason}}
    end
  end

  defp datetime_in_timezone(%Date{} = date, %Time{} = time, timezone) do
    case DateTime.new(date, Time.truncate(time, :second), timezone) do
      {:ok, datetime} -> {:ok, datetime}
      {:ambiguous, first_datetime, _second_datetime} -> {:ok, first_datetime}
      {:gap, _before_gap, after_gap} -> {:ok, after_gap}
      {:error, reason} -> {:error, {:invalid_timezone, timezone, reason}}
    end
  end

  defp to_utc({:ok, %DateTime{} = datetime}), do: DateTime.shift_zone(datetime, "Etc/UTC")
  defp to_utc({:error, _reason} = error), do: error

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
