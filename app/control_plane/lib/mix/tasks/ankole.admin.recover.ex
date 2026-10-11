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
    Ankole.Release.recover_admin(uid, operator, reason)
  end

  def run(_) do
    Mix.raise("Usage: mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified")
  end
end
