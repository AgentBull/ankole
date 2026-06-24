defmodule Mix.Tasks.Ankole.ActorRuntime.WorkerBootstrap do
  @moduledoc """
  Prints the v1 external agent computer worker Docker command.
  """

  use Mix.Task

  alias Ankole.ActorRuntime.WorkerBootstrap

  @shortdoc "Prints an external agent computer worker docker run command"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          endpoint: :string,
          worker_id: :string,
          worker_instance_id: :string,
          image: :string,
          workspace_root: :string
        ]
      )

    case invalid do
      [] ->
        print_command(opts)

      invalid ->
        Mix.raise("invalid options: #{inspect(invalid)}")
    end
  end

  defp print_command(opts) do
    with {:ok, command} <- WorkerBootstrap.docker_run_command(opts) do
      Mix.shell().info(command)
    else
      {:error, reason} -> Mix.raise("failed to render worker bootstrap: #{inspect(reason)}")
    end
  end
end
