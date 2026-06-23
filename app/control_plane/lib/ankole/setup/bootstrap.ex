defmodule Ankole.Setup.Bootstrap do
  @moduledoc """
  Startup worker that refreshes the setup bootstrap activation code.
  """

  use GenServer

  require Logger

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
    with :ok <- Config.ensure_registered(),
         {:ok, completed?} <- Config.completed?() do
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

  @impl true
  def init(_opts) do
    state =
      case initialize() do
        {:ok, %{completed: true}} ->
          %{completed: true, activation_code: nil}

        {:ok, %{completed: false, activation_code: code}} ->
          Logger.info("Ankole setup bootstrap activation code reset: #{code}")
          %{completed: false, activation_code: code}

        {:error, reason} ->
          Logger.warning("Ankole setup bootstrap initialization skipped: #{inspect(reason)}")
          %{completed: false, activation_code: nil, error: reason}
      end

    {:ok, state}
  rescue
    error ->
      Logger.warning("Ankole setup bootstrap initialization failed: #{Exception.message(error)}")
      {:ok, %{completed: false, activation_code: nil, error: Exception.message(error)}}
  end

  defp initialize_for_completion(true) do
    with :ok <- Config.delete_bootstrap_activation_code() do
      {:ok, %{completed: true, activation_code: nil}}
    end
  end

  defp initialize_for_completion(false) do
    code = random_activation_code()

    with {:ok, ^code} <- Config.put_bootstrap_activation_code(code) do
      {:ok, %{completed: false, activation_code: code}}
    end
  end
end
