defmodule Mix.Tasks.Ankole.Get do
  @moduledoc """
  Reads local Ankole values without starting the full control plane.
  """

  use Mix.Task

  alias Ankole.Setup.BootstrapActivationCodeText
  alias Ankole.Setup.Config, as: SetupConfig

  @shortdoc "Reads a local Ankole value"
  @supported_keys ~w(bootstrap-activation-code)

  @impl Mix.Task
  def run(args) do
    {opts, argv, invalid} =
      OptionParser.parse(args,
        strict: [
          format: :string
        ]
      )

    case {invalid, argv} do
      {[], [key]} ->
        print_key(Keyword.get(opts, :format, "text"), key)

      {[], []} ->
        Mix.raise("missing key; expected one of: #{Enum.join(@supported_keys, ", ")}")

      {[], extra} ->
        Mix.raise("expected one key, got: #{inspect(extra)}")

      {invalid, _argv} ->
        Mix.raise("invalid options: #{inspect(invalid)}")
    end
  end

  defp print_key(format, key) when key in @supported_keys do
    start_get_dependencies()
    print_result(format, get_value(key))
  end

  defp print_key(format, key),
    do: print_result(format, {:error, {:unknown_key, key, @supported_keys}})

  defp get_value("bootstrap-activation-code") do
    with :ok <- SetupConfig.ensure_registered(),
         {:ok, completed?} <- SetupConfig.completed?() do
      value =
        case {completed?, SetupConfig.bootstrap_activation_code()} do
          {false, {:ok, code}} -> code
          _other -> nil
        end

      {:ok, %{key: "bootstrap-activation-code", value: value, completed: completed?}}
    end
  end

  defp get_value(key), do: {:error, {:unknown_key, key, @supported_keys}}

  defp print_result("text", {:ok, %{key: "bootstrap-activation-code", completed: true}}) do
    Mix.shell().info(BootstrapActivationCodeText.completed_message())
  end

  defp print_result("text", {:ok, %{key: "bootstrap-activation-code", value: code}})
       when is_binary(code) do
    Mix.shell().info(BootstrapActivationCodeText.line(code))
  end

  defp print_result("text", {:ok, %{key: "bootstrap-activation-code", value: nil}}) do
    Mix.shell().info(BootstrapActivationCodeText.missing_message())
  end

  defp print_result("json", {:ok, result}) do
    result
    |> stringify_keys()
    |> Ankole.JSON.encode!()
    |> Mix.shell().info()
  end

  defp print_result(format, {:ok, _result}) do
    Mix.raise("invalid --format #{inspect(format)}; expected text or json")
  end

  defp print_result(_format, {:error, reason}) do
    Mix.raise("failed to read Ankole value: #{inspect(reason)}")
  end

  defp start_get_dependencies do
    Mix.Task.run("app.config")

    with {:ok, _apps} <- Application.ensure_all_started(:ankole_kernel),
         {:ok, _apps} <- Application.ensure_all_started(:ecto_sql),
         :ok <- start_child(Ankole.Repo),
         :ok <- start_child(Ankole.AppConfigure.Registry),
         :ok <- start_child(Ankole.AppConfigure.Cache) do
      :ok
    else
      {:error, reason} ->
        Mix.raise("failed to start value query dependencies: #{inspect(reason)}")
    end
  end

  defp start_child(module) do
    case module.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, {module, reason}}
    end
  end

  defp stringify_keys(value) when is_map(value) do
    Map.new(value, fn {key, map_value} -> {to_string(key), stringify_keys(map_value)} end)
  end

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
