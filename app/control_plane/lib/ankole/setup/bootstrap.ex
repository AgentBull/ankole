defmodule Ankole.Setup.Bootstrap do
  @moduledoc """
  Startup worker that refreshes the setup bootstrap activation code.
  """

  use GenServer

  alias Ankole.AuthZ
  alias Ankole.Logging
  alias Ankole.Setup.BootstrapActivationCodeText
  alias Ankole.Setup.Config

  @alphabet ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

  @type result :: %{completed: boolean(), activation_code: String.t() | nil}

  @doc """
  Starts the bootstrap worker.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Resets the activation code when setup is still open.
  """
  @spec initialize() :: {:ok, result()} | {:error, term()}
  def initialize do
    with {:ok, completed?} <- Config.completed?() do
      initialize_for_completion(completed?)
    end
  end

  @doc """
  Generates a short operator-copyable setup activation code.
  """
  @spec random_activation_code() :: String.t()
  def random_activation_code do
    bytes = :crypto.strong_rand_bytes(8)
    alphabet_size = length(@alphabet)

    bytes
    |> :binary.bin_to_list()
    |> Enum.map(fn byte -> Enum.at(@alphabet, rem(byte, alphabet_size)) end)
    |> List.to_string()
  end

  @doc """
  Prints the current bootstrap activation code to the operator log.
  """
  @spec log_current_activation_code() :: :ok | :error | {:error, term()}
  def log_current_activation_code do
    with {:ok, false} <- Config.completed?(),
         {:ok, code} <- Config.bootstrap_activation_code() do
      log_activation_code(
        "setup.bootstrap.activation_code_printed",
        BootstrapActivationCodeText.line(code),
        code
      )
    else
      {:ok, true} -> {:error, :setup_completed}
      other -> other
    end
  end

  @impl true
  def init(_opts) do
    state =
      case initialize() do
        {:ok, %{completed: true}} ->
          %{completed: true, activation_code: nil}

        {:ok, %{completed: false, activation_code: code}} ->
          log_activation_code(
            "setup.bootstrap.activation_code_reset",
            BootstrapActivationCodeText.line(code),
            code
          )

          %{completed: false, activation_code: code}

        {:error, reason} ->
          Logging.warning(
            "setup.bootstrap.initialization_skipped",
            "setup bootstrap initialization skipped",
            %{
              reason: inspect(reason)
            }
          )

          %{completed: false, activation_code: nil, error: reason}
      end

    {:ok, state}
  rescue
    error ->
      Logging.warning(
        "setup.bootstrap.initialization_failed",
        "setup bootstrap initialization failed",
        %{
          error: Exception.message(error)
        }
      )

      {:ok, %{completed: false, activation_code: nil, error: Exception.message(error)}}
  end

  defp initialize_for_completion(true) do
    with :ok <- Config.delete_bootstrap_activation_code() do
      ensure_console_admin_grants_once()
      {:ok, %{completed: true, activation_code: nil}}
    end
  end

  defp initialize_for_completion(false) do
    code = random_activation_code()

    with {:ok, ^code} <- Config.put_bootstrap_activation_code(code) do
      {:ok, %{completed: false, activation_code: code}}
    end
  end

  defp ensure_console_admin_grants_once do
    case AuthZ.ensure_console_admin_grants() do
      :ok ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "setup.bootstrap.console_admin_grant_repair_skipped",
          "console admin grant startup repair skipped",
          %{
            reason: inspect(reason)
          }
        )

        :ok
    end
  end

  defp log_activation_code(event, message, code) do
    Logging.notice(event, message, %{activation_code: code})
  end
end
