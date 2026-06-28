defmodule Mix.Tasks.Ankole.ActorRuntime.WorkerBootstrap do
  @moduledoc """
  Prints the v1 external agent computer worker Docker command.
  """

  use Mix.Task

  alias Ankole.ActorRuntime.WorkerBootstrap

  @shortdoc "Prints an external agent computer worker docker run command"

  @impl Mix.Task
  def run(args) do
    metadata = %{task: __MODULE__}

    :telemetry.span([:ankole, :mix_task], metadata, fn ->
      result = do_run(args)
      {result, Map.put(metadata, :result, :ok)}
    end)
  end

  defp do_run(args) do
    Mix.Task.run("app.start")

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          endpoint: :string,
          worker_id: :string,
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
    case WorkerBootstrap.docker_run_command(opts) do
      {:ok, command} ->
        Mix.shell().info(command)

      {:error, reason} ->
        Mix.raise("failed to render worker bootstrap: #{inspect(reason)}")
    end
  end
end
