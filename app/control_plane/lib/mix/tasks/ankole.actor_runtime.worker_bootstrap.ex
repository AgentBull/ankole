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
    start_bootstrap_dependencies()

    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          endpoint: :string,
          worker_id: :string,
          image: :string,
          workspace_root: :string,
          format: :string
        ]
      )

    case invalid do
      [] ->
        print_bootstrap(opts)

      invalid ->
        Mix.raise("invalid options: #{inspect(invalid)}")
    end
  end

  defp print_bootstrap(opts) do
    case Keyword.get(opts, :format, "shell") do
      "shell" -> print_command(Keyword.delete(opts, :format))
      "json" -> print_json(Keyword.delete(opts, :format))
      format -> Mix.raise("invalid --format #{inspect(format)}; expected shell or json")
    end
  end

  defp print_command(opts) do
    opts
    |> WorkerBootstrap.docker_run_command()
    |> print_result(& &1)
  end

  defp print_json(opts) do
    opts
    |> WorkerBootstrap.docker_run_spec()
    |> print_result(fn spec -> spec |> stringify_keys() |> Ankole.JSON.encode!() end)
  end

  defp print_result({:ok, value}, formatter), do: Mix.shell().info(formatter.(value))

  defp print_result({:error, reason}, _formatter) do
    Mix.raise("failed to render worker bootstrap: #{inspect(reason)}")
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, map_value} -> {to_string(key), stringify_keys(map_value)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp start_bootstrap_dependencies do
    Mix.Task.run("app.config")

    with {:ok, _apps} <- Application.ensure_all_started(:ankole_kernel),
         {:ok, _apps} <- Application.ensure_all_started(:ecto_sql),
         :ok <- start_child(Ankole.Repo),
         :ok <- start_child(Ankole.AppConfigure.Registry),
         :ok <- start_child(Ankole.AppConfigure.Cache) do
      :ok
    else
      {:error, reason} -> Mix.raise("failed to start bootstrap dependencies: #{inspect(reason)}")
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
