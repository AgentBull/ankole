defmodule BullX.AIAgent.Time do
  @moduledoc """
  Time-zone helpers for AIAgent runtime text and reset boundaries.

  Durable timestamps stay UTC. Wall-clock rendering uses the configured
  Installation time zone unless a profile field provides a narrower one.
  """

  @spec installation_timezone() :: String.t()
  def installation_timezone do
    Application.get_env(:bullx, :installation_timezone, "Etc/UTC")
  end

  @spec valid_timezone?(term()) :: boolean()
  def valid_timezone?("Etc/UTC"), do: true
  def valid_timezone?("UTC"), do: true

  def valid_timezone?(timezone) when is_binary(timezone) and timezone != "" do
    valid_timezone_name?(timezone) and zoneinfo_exists?(timezone)
  end

  def valid_timezone?(_timezone), do: false

  defp valid_timezone_name?(timezone) do
    Regex.match?(
      ~r/^[A-Za-z]+(?:[+_-]?[A-Za-z0-9]+)*\/[A-Za-z0-9_+\-]+(?:\/[A-Za-z0-9_+\-]+)*$/,
      timezone
    ) and not String.contains?(timezone, "..")
  end

  defp zoneinfo_exists?(timezone) do
    Enum.any?(
      [
        "/usr/share/zoneinfo",
        "/var/db/timezone/zoneinfo",
        "/usr/share/lib/zoneinfo"
      ],
      fn root ->
        root
        |> Path.join(timezone)
        |> File.regular?()
      end
    )
  end

  @spec shift(DateTime.t(), String.t() | nil) :: DateTime.t()
  def shift(%DateTime{} = datetime, timezone) when is_binary(timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> shifted
      {:error, _reason} -> datetime
    end
  rescue
    _error -> datetime
  end

  def shift(%DateTime{} = datetime, _timezone), do: datetime

  @spec format(DateTime.t(), String.t(), String.t() | nil) :: String.t()
  def format(%DateTime{} = datetime, format, timezone) when is_binary(format) do
    datetime
    |> shift(timezone || installation_timezone())
    |> Calendar.strftime(format)
  end
end
