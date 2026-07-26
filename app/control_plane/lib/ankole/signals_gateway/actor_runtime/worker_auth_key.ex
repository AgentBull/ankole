defmodule Ankole.SignalsGateway.ActorRuntime.WorkerAuthKey do
  @moduledoc """
  Global RuntimeFabric worker authentication key.

  The control plane persists the key in AppConfigure. Workers receive it through
  `RUNTIME_FABRIC_URL`; Rust only sees the resolved in-memory value needed for
  ZAP/PLAIN verification.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.GeneratedSecret
  alias Ankole.AppConfigure.Schema

  @key "runtime_fabric.worker_auth_key"

  @doc """
  Returns the AppConfigure definition for the global worker auth key.
  """
  @spec definition() :: Definition.t()
  def definition do
    AppConfigure.define(
      key: @key,
      encrypted: true,
      scope: :global,
      schema: Schema.non_empty_string(),
      generator: GeneratedSecret.generator(),
      # The release bootstrap generates and stores this key, and every Worker authenticates with
      # it. A Console edit would reject every running Worker, so the value stays readable but not
      # writable there.
      console_writable: false,
      description: "Global RuntimeFabric worker authentication key."
    )
  end

  @doc """
  Registers the AppConfigure key.
  """
  @spec ensure_registered() :: :ok | {:error, term()}
  def ensure_registered do
    case AppConfigure.register_definitions([definition()]) do
      :ok -> :ok
      {:error, {:duplicate_key, @key}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the persisted key, creating a generated secret value when the row is missing.
  """
  @spec ensure() :: {:ok, String.t()} | {:error, term()}
  def ensure do
    with :ok <- ensure_registered() do
      case AppConfigure.get(definition()) do
        {:ok, key} ->
          {:ok, key}

        :error ->
          with {:ok, generated} <- AppConfigure.generate(definition()) do
            AppConfigure.put_global(definition(), generated)
          end

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc """
  Bang variant for supervisor boot paths where auth setup is mandatory.
  """
  @spec ensure!() :: String.t()
  def ensure! do
    case ensure() do
      {:ok, key} ->
        key

      {:error, reason} ->
        raise ArgumentError, "failed to resolve worker auth key: #{inspect(reason)}"
    end
  end

  @doc """
  Builds the worker-facing RuntimeFabric URL for a TCP endpoint.
  """
  @spec runtime_fabric_url(String.t()) :: {:ok, String.t()} | {:error, term()}
  def runtime_fabric_url("tcp://" <> rest) do
    case ensure() do
      {:ok, key} -> runtime_fabric_url("tcp://" <> rest, key)
      {:error, _reason} = error -> error
    end
  end

  def runtime_fabric_url(_endpoint), do: {:error, :invalid_runtime_fabric_endpoint}

  @doc """
  Builds the worker-facing RuntimeFabric URL from an explicit auth key.
  """
  @spec runtime_fabric_url(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def runtime_fabric_url("tcp://" <> rest, key) when is_binary(key) and key != "" do
    {:ok, "tcp://:#{URI.encode_www_form(key)}@#{rest}"}
  end

  def runtime_fabric_url("tcp://" <> _rest, _key), do: {:error, {:invalid, :auth_key}}
  def runtime_fabric_url(_endpoint, _key), do: {:error, :invalid_runtime_fabric_endpoint}
end
