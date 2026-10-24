defmodule Mix.Tasks.Ankole.Admin.Recover do
  @moduledoc """
  Recovers site administration when no active Human administrator remains.
  With `--tenant`, recovers Pod administration when no administrator can sign in.

  Verify the target Human independently before this command. The target must
  already be active. The command cannot restore a departed Human or open setup.

      mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified
      mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified --tenant SLUG
  """
  use Mix.Task
  @shortdoc "Records an operator recovery of administrator access"

  @impl Mix.Task
  def run([uid, operator, reason, "--identity-verified"]) do
    Mix.Task.run("app.config")
    Ankole.Release.recover_admin(uid, operator, reason)
  end

  def run([uid, operator, reason, "--identity-verified", "--tenant", slug]) do
    Mix.Task.run("app.config")
    Ankole.Release.recover_admin(uid, operator, reason, slug)
  end

  def run(_) do
    Mix.raise(
      "Usage: mix ankole.admin.recover HUMAN_UID OPERATOR REASON --identity-verified [--tenant SLUG]"
    )
  end
end
