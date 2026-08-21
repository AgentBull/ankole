defmodule Ankole.Setup.Config do
  @moduledoc """
  AppConfigure-backed state for first-run setup.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema

  @completed_key "setup.completed"
  @bootstrap_activation_code_key "setup.bootstrap_activation_code"
  @activation_code_pattern ~r/\A[A-Z0-9]{8}\z/

  @doc """
  Returns the AppConfigure definition that closes the setup surface.
  """
  @spec completed_definition() :: Definition.t()
  def completed_definition do
    AppConfigure.define(
      key: @completed_key,
      encrypted: false,
      schema: Schema.boolean(),
      default_value: false,
      console_writable: false,
      description: "Whether the Ankole installation setup has completed."
    )
  end

  @doc """
  Returns the AppConfigure definition for the current bootstrap activation code.
  """
  @spec bootstrap_activation_code_definition() :: Definition.t()
  def bootstrap_activation_code_definition do
    AppConfigure.define(
      key: @bootstrap_activation_code_key,
      encrypted: false,
      schema: activation_code_schema(),
      console_writable: false,
      description: "Current bootstrap activation code for the first-run setup session gate."
    )
  end

  @doc """
  Returns whether setup has completed.
  """
  @spec completed?() :: {:ok, boolean()} | {:error, term()}
  def completed? do
    with {:ok, completed} <- AppConfigure.get(completed_definition()) do
      {:ok, completed == true}
    end
  end

  @doc """
  Persists the setup completion flag.
  """
  @spec put_completed(boolean()) :: {:ok, boolean()} | {:error, term()}
  def put_completed(completed) when is_boolean(completed) do
    AppConfigure.put_global(completed_definition(), completed)
  end

  @doc """
  Reads the current bootstrap activation code.
  """
  @spec bootstrap_activation_code() :: {:ok, String.t()} | :error | {:error, term()}
  def bootstrap_activation_code do
    AppConfigure.get(bootstrap_activation_code_definition())
  end

  @doc """
  Persists a new bootstrap activation code.
  """
  @spec put_bootstrap_activation_code(String.t()) :: {:ok, String.t()} | {:error, term()}
  def put_bootstrap_activation_code(code) when is_binary(code) do
    AppConfigure.put_global(bootstrap_activation_code_definition(), code)
  end

  @doc """
  Deletes the bootstrap activation code.
  """
  @spec delete_bootstrap_activation_code() :: :ok | {:error, term()}
  def delete_bootstrap_activation_code do
    AppConfigure.delete_global(bootstrap_activation_code_definition())
  end

  defp activation_code_schema do
    Schema.new(fn
      value when is_binary(value) ->
        case Regex.match?(@activation_code_pattern, value) do
          true -> {:ok, value}
          false -> {:error, :invalid_activation_code}
        end

      _value ->
        {:error, :invalid_activation_code}
    end)
  end
end
