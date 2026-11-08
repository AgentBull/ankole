defmodule Ankole.Plugins.DatabaseConnectors.Config do
  @moduledoc "Operator budgets for database connector reads, probes, exports, and catalog refreshes."
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.{Definition, Schema}

  @key "connectors.database.limits"
  @defaults %{
    "statement_timeout_ms" => 15_000,
    "lock_timeout_ms" => 2_000,
    "max_rows" => 500,
    "max_result_bytes" => 2_000_000,
    "max_scanned_bytes" => 10_000_000_000,
    "max_export_rows" => 1_000_000,
    "probe_count" => 10,
    "catalog_tables" => 5_000,
    "profile_tables" => 100,
    "sample_rows" => 1_000
  }

  def definitions do
    [
      Definition.new!(
        key: @key,
        scope: :tenant,
        encrypted: false,
        schema: Schema.new(&validate/1),
        default_value: @defaults,
        description:
          "Database connector budgets: statement_timeout_ms, lock_timeout_ms, max_rows, max_result_bytes, max_scanned_bytes (ClickHouse), max_export_rows, probe_count, catalog_tables, profile_tables, and sample_rows."
      )
    ]
  end

  def limits do
    case AppConfigure.get_by_key(@key) do
      {:ok, limits} when is_map(limits) -> limits
      _ -> @defaults
    end
  end

  def defaults, do: @defaults

  defp validate(limits) when is_map(limits) do
    if Enum.sort(Map.keys(limits)) == Enum.sort(Map.keys(@defaults)) and
         Enum.all?(Map.values(limits), &(is_integer(&1) and &1 > 0)),
       do: {:ok, limits},
       else: {:error, :invalid_limits}
  end

  defp validate(_), do: {:error, :invalid_limits}
end
