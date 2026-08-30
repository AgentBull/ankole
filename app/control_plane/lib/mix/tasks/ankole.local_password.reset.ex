defmodule Mix.Tasks.Ankole.LocalPassword.Reset do
  @moduledoc """
  Resets the local sign-in password for one email address.

  This is the rescue path when an administrator cannot sign in. It replaces
  the current password with a generated one-time password, prints it, and
  requires a new password at the next sign-in.

      mix ankole.local_password.reset admin@example.com
  """

  use Mix.Task

  alias Ankole.IdentityProviders.LocalPassword
  alias Ankole.Principals.LocalPasswordResetText

  @shortdoc "Resets the local sign-in password for one email"

  @impl Mix.Task
  def run([email]) do
    start_dependencies()

    case LocalPassword.reset_local_password_by_email(email) do
      {:ok, %{initial_password: initial_password}} ->
        Mix.shell().info(LocalPasswordResetText.success(initial_password))
        warn_when_provider_disabled()

      {:error, :not_found} ->
        Mix.raise(LocalPasswordResetText.no_account_message(email))

      {:error, reason} ->
        Mix.raise("failed to reset the local password: #{inspect(reason)}")
    end
  end

  def run(args) do
    Mix.raise("expected exactly one email argument, got: #{inspect(args)}")
  end

  defp warn_when_provider_disabled do
    case LocalPassword.enabled?() do
      true -> :ok
      false -> Mix.shell().info(LocalPasswordResetText.provider_disabled_warning())
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
        Mix.raise("failed to start local password reset dependencies: #{inspect(reason)}")
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
