defmodule Mix.Tasks.Ankole.ActorRuntime.WorkerBootstrap do
  @moduledoc """
  Prints the v2 Agent Computer Docker launch contract or operator command.
  """

  use Mix.Task

  alias Ankole.ActorRuntime.WorkerBootstrap
  alias Ankole.ActorRuntime.WorkerBootstrap.Docker

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
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          endpoint: :string,
          worker_id: :string,
          image: :string,
          workspace_root: :string,
          format: :string,
          scope: :string
        ]
      )

    case invalid do
      [] ->
        build_and_print_bootstrap(opts)

      invalid ->
        Mix.raise("invalid options: #{inspect(invalid)}")
    end
  end

  defp build_and_print_bootstrap(opts) do
    scope = Keyword.get(opts, :scope, "worker")
    format = Keyword.get(opts, :format, "shell")
    spec_opts = Keyword.drop(opts, [:format, :scope])

    with :ok <- validate_output(scope, format),
         {:ok, spec} <- build_spec(scope, spec_opts) do
      print_spec(spec, format)
    else
      {:error, reason} -> Mix.raise("failed to render worker bootstrap: #{inspect(reason)}")
    end
  end

  defp validate_output("worker", format) when format in ["shell", "json"], do: :ok
  defp validate_output("container", "json"), do: :ok

  defp validate_output("container", format) do
    {:error, {:invalid_output, scope: "container", format: format}}
  end

  defp validate_output(scope, format) do
    {:error, {:invalid_output, scope: scope, format: format}}
  end

  defp build_spec("container", opts), do: WorkerBootstrap.container_spec(opts)

  defp build_spec("worker", opts) do
    start_bootstrap_dependencies()

    opts
    |> Keyword.put_new_lazy(:workspace_root, fn -> Path.expand(".ankole-worker", File.cwd!()) end)
    |> WorkerBootstrap.worker_spec()
  end

  defp print_spec(spec, "shell"), do: Mix.shell().info(Docker.shell_command(spec))

  defp print_spec(spec, "json") do
    spec
    |> stringify_keys()
    |> Ankole.JSON.encode!()
    |> Mix.shell().info()
  end

  defp stringify_keys(value) when is_struct(value),
    do: value |> Map.from_struct() |> stringify_keys()

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, map_value} -> {to_string(key), stringify_keys(map_value)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value) when value in [true, false, nil], do: value
  defp stringify_keys(value) when is_atom(value), do: Atom.to_string(value)
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
