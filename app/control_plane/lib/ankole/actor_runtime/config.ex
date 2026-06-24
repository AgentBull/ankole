defmodule Ankole.ActorRuntime.Config do
  @moduledoc """
  AppConfigure definitions for the actor runtime.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.GeneratedSecret
  alias Ankole.AppConfigure.Schema

  @pre_auth_token_key "actor_runtime.agent_computer_worker.pre_auth_token"

  @doc """
  Returns the installation-wide agent computer worker pre-auth token definition.
  """
  @spec pre_auth_token_definition() :: Definition.t()
  def pre_auth_token_definition do
    AppConfigure.define(
      key: @pre_auth_token_key,
      encrypted: true,
      schema: Schema.non_empty_string(),
      generator: GeneratedSecret.generator(),
      description: "Installation-wide pre-auth token used by external agent computer workers."
    )
  end

  @doc """
  Registers actor-runtime AppConfigure keys.
  """
  @spec ensure_registered() :: :ok | {:error, term()}
  def ensure_registered do
    case AppConfigure.register_definitions([pre_auth_token_definition()]) do
      :ok -> :ok
      {:error, {:duplicate_key, @pre_auth_token_key}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reads the stored worker pre-auth token.

  Reads do not generate or persist a secret. Setup and bootstrap flows must call
  `ensure_pre_auth_token/0` when they own the decision to create one.
  """
  @spec pre_auth_token() :: {:ok, String.t()} | :error | {:error, term()}
  def pre_auth_token do
    with :ok <- ensure_registered() do
      AppConfigure.get(pre_auth_token_definition())
    end
  end

  @doc """
  Generates and stores the worker pre-auth token when it is missing.
  """
  @spec ensure_pre_auth_token() :: {:ok, String.t()} | {:error, term()}
  def ensure_pre_auth_token do
    with :ok <- ensure_registered() do
      case AppConfigure.get(pre_auth_token_definition()) do
        {:ok, token} ->
          {:ok, token}

        :error ->
          with {:ok, token} <- AppConfigure.generate(pre_auth_token_definition()) do
            AppConfigure.put_global(pre_auth_token_definition(), token)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
