defmodule Ankole.SignalsGateway.ActorRuntime.WorkerAuthKey do
  @moduledoc """
  Global RuntimeFabric worker authentication key.

  The control plane persists the key in AppConfigure. Workers receive it as a
  separate bootstrap secret. Rust only sees the resolved in-memory value needed
  for ZAP/PLAIN verification.
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
  Returns the persisted key, creating a generated secret value when the row is missing.
  """
  @spec ensure() :: {:ok, String.t()} | {:error, term()}
  def ensure do
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
end
