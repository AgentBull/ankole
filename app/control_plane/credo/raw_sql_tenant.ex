Code.require_file("persistence_boundary.ex", __DIR__)

defmodule Ankole.Credo.RawSQLTenant do
  @moduledoc """
  Requires a tenant predicate in raw SQL that reads or changes a table.

  The SQL text must contain `tenant_id`, or its module must declare
  `@raw_sql_scope :site` for site tables, catalogs, and DDL. Physical Base
  modules use `@raw_sql_scope :tenant_schema` with the tenant-bound BaseRepo
  table helpers. SQL without a table reference (a clock, a sequence, or an
  advisory lock) needs neither.
  """
  use Credo.Check, base_priority: :high, category: :warning

  alias Ankole.Credo.PersistenceBoundary

  @impl true
  def run(source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    source_file
    |> Credo.SourceFile.ast()
    |> PersistenceBoundary.crossings(source_file.filename, [:raw_sql_tenant])
    |> Enum.map(fn occurrence ->
      format_issue(issue_meta,
        line_no: occurrence.line,
        message:
          "Bind tenant_id in raw SQL or declare a reviewed :site or :tenant_schema SQL scope"
      )
    end)
  end
end
