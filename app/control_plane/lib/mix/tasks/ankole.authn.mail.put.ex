defmodule Mix.Tasks.Ankole.Authn.Mail.Put do
  @moduledoc "Updates site authentication SMTP settings from a JSON file or standard input."
  use Mix.Task
  @requirements ["app.config"]
  @shortdoc "Saves site authentication SMTP settings"

  @impl true
  def run(["-"]), do: IO.read(:stdio, :eof) |> Ankole.Release.put_authn_mail()
  def run([path]), do: File.read!(path) |> Ankole.Release.put_authn_mail()
  def run(_), do: Mix.raise("Use mix ankole.authn.mail.put FILE.json, or - for standard input.")
end
