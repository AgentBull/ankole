defmodule Ankole.SystemConfig do
  @moduledoc """
  AppConfigure definitions for installation-wide runtime semantics.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema

  @timezone_key "system.timezone"
  @default_timezone "Etc/UTC"

  @doc """
  Returns the AppConfigure definition for the installation timezone.
  """
  @spec timezone_definition() :: Definition.t()
  def timezone_definition do
    AppConfigure.define(
      key: @timezone_key,
      encrypted: false,
      schema: timezone_schema(),
      default_value: @default_timezone,
      description: "Installation timezone used by control-plane scheduled semantics."
    )
  end

  @doc """
  Registers system-level AppConfigure keys.
  """
  @spec ensure_registered() :: :ok | {:error, term()}
  def ensure_registered do
    case AppConfigure.register_definitions([timezone_definition()]) do
      :ok -> :ok
      {:error, {:duplicate_key, @timezone_key}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reads the effective installation timezone.
  """
  @spec timezone() :: {:ok, String.t()} | {:error, term()}
  def timezone do
    with :ok <- ensure_registered(),
         {:ok, timezone} <- AppConfigure.get(timezone_definition()) do
      {:ok, timezone}
    end
  end

  @doc """
  Persists the installation timezone.
  """
  @spec put_timezone(String.t()) :: {:ok, String.t()} | {:error, term()}
  def put_timezone(timezone) when is_binary(timezone) do
    with :ok <- ensure_registered() do
      AppConfigure.put_global(timezone_definition(), timezone)
    end
  end

  defp timezone_schema do
    Schema.new(fn
      "UTC" ->
        {:ok, @default_timezone}

      timezone when is_binary(timezone) ->
        case DateTime.now(timezone) do
          {:ok, _now} -> {:ok, timezone}
          {:error, reason} -> {:error, {:invalid_timezone, reason}}
        end

      _value ->
        {:error, :not_timezone}
    end)
  end
end
