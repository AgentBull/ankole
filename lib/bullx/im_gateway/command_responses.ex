defmodule BullX.IMGateway.CommandResponses do
  @moduledoc false

  alias BullX.AIAgent.CommandCatalog

  @direct_commands ~w(root_init webauth command status)

  @spec direct_command?(String.t()) :: boolean()
  def direct_command?(name) when is_binary(name), do: name in @direct_commands
  def direct_command?(_name), do: false

  @spec status_text(keyword()) :: String.t()
  def status_text(opts \\ []) do
    opts
    |> health_result()
    |> render_status()
  end

  @spec command_list_text(keyword()) :: String.t()
  def command_list_text(opts \\ []) do
    CommandCatalog.catalog()
    |> Enum.map_join("\n", &command_line(&1, opts))
  end

  defp health_result(opts) do
    opts
    |> Keyword.get(:health_fun, &BullX.Health.ready/0)
    |> then(& &1.())
  end

  defp render_status({:ok, %{status: status, checks: checks}}),
    do: render_status(status, checks)

  defp render_status({:error, %{status: status, checks: checks}}),
    do: render_status(status, checks)

  defp render_status(_result), do: "BullX status: unknown"

  defp render_status(status, checks) when is_map(checks) do
    check_lines =
      checks
      |> Enum.map(fn {name, check} -> "#{name}: #{check_status(check)}" end)
      |> Enum.sort()

    ["BullX status: #{status}" | check_lines]
    |> Enum.join("\n")
  end

  defp check_status(%{status: status, error: error}), do: "#{status} (#{error})"
  defp check_status(%{status: status}), do: status
  defp check_status(%{"status" => status, "error" => error}), do: "#{status} (#{error})"
  defp check_status(%{"status" => status}), do: status
  defp check_status(_check), do: "unknown"

  defp command_line(command, opts) do
    slash = CommandCatalog.display_slash(command, opts)
    description = CommandCatalog.description(command, opts)

    "#{slash} - #{description}"
  end
end
