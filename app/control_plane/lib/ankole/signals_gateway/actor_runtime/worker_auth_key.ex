defmodule Ankole.SignalsGateway.ActorRuntime.WorkerAuthKey do
  @moduledoc """
  The installation's RuntimeFabric key, kept in AppConfigure.

  It stays in the control plane and keys the opaque Lark profile names
  (`TurnRuntimeEnv`). A Worker proves its Agent with the random credential of
  its own generation (`AgentWorkers.authenticate/2`), not with this key, and
  a file relay URL carries a random token of its session.
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
      # The control plane generates and stores this key when it first starts. A Console edit
      # would rename every Lark profile, so its users would have to authorize again; the value
      # stays readable but not writable there.
      console_writable: false,
      description: "Installation key that names Lark profiles."
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
