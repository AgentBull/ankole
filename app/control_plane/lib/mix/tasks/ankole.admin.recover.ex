defmodule Mix.Tasks.Ankole.Admin.Recover do
  @moduledoc """
  Recovers administrator access when no active Human administrator remains.

  Verify the target Human independently before this command. The target must
  already be active. The command cannot restore a departed Human or open setup.

      mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified
  """
  use Mix.Task
  @shortdoc "Records an operator recovery of administrator access"

  @impl Mix.Task
  def run([uid, operator, reason, "--identity-verified"]) do
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:ankole_kernel)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)

    case Ankole.Repo.start_link([]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, error} -> Mix.raise("Cannot start the database: #{inspect(error)}")
    end

    case Ankole.Principals.HumanAccess.recover_admin(uid, operator, reason) do
      {:ok, principal} -> Mix.shell().info("Administrator access restored for #{principal.uid}.")
      {:error, error} -> Mix.raise("Administrator recovery failed: #{inspect(error)}")
    end
  end

  def run(_) do
    Mix.raise("Usage: mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified")
  end
end
