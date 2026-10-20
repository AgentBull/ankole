defmodule Ankole.TimeZone do
  @moduledoc false

  @utc_timezone "Etc/UTC"

  @spec normalize(String.t()) :: String.t()
  def normalize("UTC"), do: @utc_timezone
  def normalize(timezone) when is_binary(timezone), do: timezone

  @spec validate(term()) :: {:ok, String.t()} | {:error, term()}
  def validate(timezone) when is_binary(timezone) and timezone != "" do
    timezone = normalize(timezone)

    case DateTime.now(timezone) do
      {:ok, _now} -> {:ok, timezone}
      {:error, reason} -> {:error, {:invalid_timezone, timezone, reason}}
    end
  end

  def validate(_timezone), do: {:error, :invalid_timezone}

  @spec shift(DateTime.t(), String.t()) :: {:ok, DateTime.t()} | {:error, term()}
  def shift(%DateTime{} = datetime, timezone) when is_binary(timezone) do
    timezone = normalize(timezone)

    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> {:ok, shifted}
      {:error, reason} -> {:error, {:invalid_timezone, timezone, reason}}
    end
  end

  @spec resolve_local(NaiveDateTime.t(), String.t()) :: {:ok, DateTime.t()} | {:error, term()}
  def resolve_local(%NaiveDateTime{} = naive, timezone) when is_binary(timezone) do
    resolve_local(NaiveDateTime.to_date(naive), NaiveDateTime.to_time(naive), timezone)
  end

  @spec resolve_local(Date.t(), Time.t(), String.t()) ::
          {:ok, DateTime.t()} | {:error, term()}
  def resolve_local(%Date{} = date, %Time{} = time, timezone) when is_binary(timezone) do
    timezone = normalize(timezone)

    case DateTime.new(date, time, timezone) do
      {:ok, datetime} -> {:ok, datetime}
      {:ambiguous, first_datetime, _second_datetime} -> {:ok, first_datetime}
      {:gap, _before_gap, after_gap} -> {:ok, after_gap}
      {:error, reason} -> {:error, {:invalid_timezone, timezone, reason}}
    end
  end
end
