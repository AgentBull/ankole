defmodule Mix.Tasks.Ankole.Setup.BootstrapActivationCode do
  @moduledoc """
  Prints the current setup bootstrap activation code.
  """

  use Mix.Task

  alias Ankole.Setup.BootstrapActivationCodeText
  alias Ankole.Setup.Config, as: SetupConfig

  @shortdoc "Prints the setup bootstrap activation code"

  @impl Mix.Task
  def run([]) do
    start_dependencies()

    case current_text() do
      {:ok, text} ->
        Mix.shell().info(text)

      {:error, reason} ->
        Mix.raise("failed to read the bootstrap activation code: #{inspect(reason)}")
    end
  end

  def run(args) do
    Mix.raise("expected no arguments, got: #{inspect(args)}")
  end

  defp current_text do
    case SetupConfig.completed?() do
      {:ok, true} ->
        {:ok, BootstrapActivationCodeText.completed_message()}

      {:ok, false} ->
        current_open_setup_text()

      {:error, _reason} = error ->
        error
    end
  end

  defp current_open_setup_text do
    case SetupConfig.bootstrap_activation_code() do
      {:ok, code} -> {:ok, BootstrapActivationCodeText.line(code)}
      :error -> {:ok, BootstrapActivationCodeText.missing_message()}
      {:error, _reason} = error -> error
    end
  end

  defp start_dependencies do
    Mix.Task.run("app.config")

    with {:ok, _apps} <- Application.ensure_all_started(:ankole_kernel),
         {:ok, _apps} <- Application.ensure_all_started(:ecto_sql),
         :ok <- start_child(Ankole.Repo),
         :ok <- start_child(Ankole.AppConfigure.Registry),
         :ok <- start_child(Ankole.AppConfigure.Cache) do
      :ok
    else
      {:error, reason} ->
        Mix.raise("failed to start bootstrap activation code dependencies: #{inspect(reason)}")
    end
  end

  defp start_child(module) do
    case module.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, {module, reason}}
    end
  end
end
