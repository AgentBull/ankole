defmodule Ankole.SystemConfig do
  @moduledoc """
  AppConfigure definitions for installation-wide runtime semantics.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema
  alias Ankole.TimeZone

  @timezone_key "system.timezone"
  @utc_timezone "Etc/UTC"
  @zoneinfo_path_marker "/zoneinfo/"

  @doc """
  Returns the AppConfigure definition for the installation timezone.
  """
  @spec timezone_definition() :: Definition.t()
  def timezone_definition do
    AppConfigure.define(
      key: @timezone_key,
      encrypted: false,
      schema: timezone_schema(),
      default_value: default_timezone(),
      description: "Installation timezone used by control-plane scheduled semantics."
    )
  end

  @doc """
  Returns the host system timezone used when no installation override exists.
  """
  @spec default_timezone() :: String.t()
  def default_timezone do
    system_timezone_from_env() ||
      system_timezone_from_localtime() ||
      system_timezone_from_etc_timezone() ||
      @utc_timezone
  end

  @doc """
  Reads the effective installation timezone.
  """
  @spec timezone() :: {:ok, String.t()} | {:error, term()}
  def timezone do
    AppConfigure.get_by_key(@timezone_key)
  end

  @doc """
  Persists the installation timezone.
  """
  @spec put_timezone(String.t()) :: {:ok, String.t()} | {:error, term()}
  def put_timezone(timezone) when is_binary(timezone) do
    AppConfigure.put_global_by_key(@timezone_key, timezone)
  end

  defp timezone_schema do
    Schema.new(fn
      timezone when is_binary(timezone) ->
        validate_timezone(timezone)

      _value ->
        {:error, :not_timezone}
    end)
  end

  defp system_timezone_from_env do
    System.get_env("TZ")
    |> normalize_system_timezone()
  end

  defp system_timezone_from_localtime do
    case File.read_link("/etc/localtime") do
      {:ok, target} ->
        target
        |> Path.expand("/etc")
        |> timezone_from_zoneinfo_path()
        |> normalize_system_timezone()

      {:error, _reason} ->
        nil
    end
  end

  defp system_timezone_from_etc_timezone do
    case File.read("/etc/timezone") do
      {:ok, content} ->
        content
        |> String.split(["\n", "\r"], trim: true)
        |> List.first()
        |> normalize_system_timezone()

      {:error, _reason} ->
        nil
    end
  end

  defp timezone_from_zoneinfo_path(path) when is_binary(path) do
    case String.split(path, @zoneinfo_path_marker, parts: 2) do
      [_prefix, timezone] -> timezone
      _parts -> nil
    end
  end

  defp timezone_from_zoneinfo_path(_path), do: nil

  defp normalize_system_timezone(nil), do: nil

  defp normalize_system_timezone(timezone) when is_binary(timezone) do
    timezone =
      timezone
      |> String.trim()
      |> String.trim_leading(":")
      |> normalize_timezone_path()

    case validate_timezone(timezone) do
      {:ok, timezone} -> timezone
      {:error, _reason} -> nil
    end
  end

  defp normalize_timezone_path("/" <> _rest = path) do
    path
    |> Path.expand()
    |> timezone_from_zoneinfo_path()
  end

  defp normalize_timezone_path(timezone), do: timezone

  defp validate_timezone(timezone) do
    case TimeZone.validate(timezone) do
      {:ok, timezone} -> {:ok, timezone}
      {:error, :invalid_timezone} -> {:error, :not_timezone}
      {:error, {:invalid_timezone, _timezone, reason}} -> {:error, {:invalid_timezone, reason}}
    end
  end
end
