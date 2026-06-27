defmodule Ankole.ActorRuntime.WorkerAuthKey do
  @moduledoc """
  Global RuntimeFabric worker authentication key.

  The control plane persists the key in AppConfigure. Workers receive it through
  `RUNTIME_FABRIC_URL`; Rust only sees the resolved in-memory value needed for
  ZAP/PLAIN verification.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
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
      generator: &Ecto.UUID.generate/0,
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
  Returns the persisted key, creating a UUID value when the row is missing.
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
      {:ok, key} -> {:ok, "tcp://:#{URI.encode_www_form(key)}@#{rest}"}
      {:error, _reason} = error -> error
    end
  end

  def runtime_fabric_url(_endpoint), do: {:error, :invalid_runtime_fabric_endpoint}
end
