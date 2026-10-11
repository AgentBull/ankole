defmodule Mix.Tasks.Ankole.LocalPassword.Reset do
  @moduledoc """
  Resets the local sign-in password for one email address.

  This is the rescue path when an administrator cannot sign in. It replaces
  the current password with a generated one-time password, prints it, and
  requires a new password at the next sign-in.

      mix ankole.local_password.reset admin@example.com
  """

  use Mix.Task

  @requirements ["app.config"]

  @shortdoc "Resets the local sign-in password for one email"

  @impl Mix.Task
  def run([email]), do: Ankole.Release.reset_local_password(email)

  def run(args) do
    Mix.raise("expected exactly one email argument, got: #{inspect(args)}")
  end
end
