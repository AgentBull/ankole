defmodule Mix.Tasks.Ankole.Files.ImportAgentHome do
  @moduledoc """
  Copies the files that Agents kept in their Agent Homes into their drives.

  `AGENTS_ROOT` is the directory that holds one Agent Home per Agent uid, for
  example `var/ankole-dev/agents` in development. Run it once after the
  upgrade; a second run only copies files that are not in the drive yet. A
  release runs `Ankole.Release.import_agent_home/1` instead.

      mix ankole.files.import_agent_home AGENTS_ROOT
  """

  use Mix.Task

  @shortdoc "Copies files from Agent Homes into Agent drives"

  @impl Mix.Task
  def run([agents_root]) do
    Mix.Task.run("app.config")
    Ankole.Release.import_agent_home(agents_root)
  end

  def run(_args), do: Mix.raise("Usage: mix ankole.files.import_agent_home AGENTS_ROOT")
end
