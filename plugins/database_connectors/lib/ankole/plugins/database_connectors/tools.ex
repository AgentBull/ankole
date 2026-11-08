defmodule Ankole.Plugins.DatabaseConnectors.Tools do
  @moduledoc "The six read-only ToolSpecs that every database toolkit declares."
  alias Ankole.Connectors.ToolSpec

  @nullable_string %{"type" => ["string", "null"]}
  @nullable_integer %{"type" => ["integer", "null"]}
  @param %{"type" => ["string", "number", "integer", "boolean", "null"]}

  @column %{
    "type" => "object",
    "properties" => %{"name" => %{"type" => "string"}, "type" => %{"type" => "string"}},
    "required" => ["name", "type"]
  }

  @envelope %{
    "type" => "object",
    "properties" => %{
      "columns" => %{"type" => "array", "items" => @column},
      "rows" => %{"type" => "array", "items" => %{"type" => "array"}},
      "row_count" => %{"type" => "integer"},
      "truncated" => %{"type" => "boolean"},
      "elapsed_ms" => %{"type" => "integer"},
      "sql" => %{"type" => "string"},
      "data_timestamp" => %{"type" => "string"},
      "warnings" => %{"type" => "array", "items" => %{"type" => "string"}},
      "file" => %{
        "type" => ["object", "null"],
        "properties" => %{
          "file_ref" => %{"type" => "string"},
          "size" => %{"type" => "integer"},
          "content_type" => %{"type" => "string"},
          "row_count" => %{"type" => "integer"},
          "truncated" => %{"type" => "boolean"}
        }
      }
    },
    "required" => ~w(columns rows row_count truncated elapsed_ms sql data_timestamp warnings)
  }

  @destination %{
    "type" => "object",
    "description" =>
      "Save every result row, up to the operator's export budget, as a CSV file in the Pod. Requires a route that permits writes.",
    "properties" => %{
      "page_id" => %{"type" => "string"},
      "role" => %{"type" => "string", "enum" => ["file", "asset", "attachment"]},
      "name" => %{"type" => "string"},
      "base_object_id" => @nullable_string
    },
    "required" => ["page_id", "role", "name"],
    "additionalProperties" => false
  }

  @table_summary %{
    "schema" => %{"type" => "string"},
    "table" => %{"type" => "string"},
    "kind" => %{"type" => "string"},
    "comment" => @nullable_string,
    "row_estimate" => @nullable_integer,
    "query_count" => @nullable_integer
  }

  def tools(toolkit) do
    Enum.map(definitions(toolkit), &ToolSpec.compile/1)
  end

  defp definitions(toolkit) do
    [
      tool(
        toolkit,
        "search_catalog",
        "Search the cached catalog of tables, views, and columns by name and comment. A blank query lists the most frequently queried tables.",
        object(
          %{
            "query" => %{"type" => "string"},
            "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 50}
          },
          []
        ),
        object(
          %{
            "tables" => %{
              "type" => "array",
              "items" =>
                object(
                  Map.put(@table_summary, "columns", %{
                    "type" => "array",
                    "items" => %{"type" => "string"}
                  }),
                  ["schema", "table", "kind", "columns"]
                )
            },
            "complete" => %{
              "type" => "boolean",
              "description" =>
                "False when the cache holds only the first tables up to the operator's catalog budget; a table missing here may still exist, so query the database's own catalog for it."
            }
          },
          ["tables", "complete"]
        )
      ),
      tool(
        toolkit,
        "describe_table",
        "Read a cached table's columns, types, comments, key properties, and masked value profiles. sparse_order_key marks a ClickHouse sorting or primary key, which is not unique.",
        object(%{"table" => %{"type" => "string"}, "schema" => @nullable_string}, ["table"]),
        object(
          Map.merge(@table_summary, %{
            "primary_key" => %{"type" => "array", "items" => %{"type" => "string"}},
            "sparse_order_key" => %{"type" => "array", "items" => %{"type" => "string"}},
            "fetched_at" => %{"type" => "string"},
            "columns" => %{
              "type" => "array",
              "items" =>
                object(
                  %{
                    "name" => %{"type" => "string"},
                    "type" => %{"type" => "string"},
                    "nullable" => %{"type" => "boolean"},
                    "comment" => @nullable_string,
                    "primary_key" => %{"type" => "boolean"},
                    "unique" => %{"type" => "boolean"},
                    "sparse_order_key" => %{"type" => "boolean"},
                    "foreign_key" => %{"type" => ["object", "null"]},
                    "sensitive" => %{"type" => "boolean"},
                    "profile" => %{"type" => ["object", "null"]}
                  },
                  ["name", "type", "nullable", "sensitive"]
                )
            }
          }),
          ["schema", "table", "columns"]
        )
      ),
      tool(
        toolkit,
        "probe_values",
        "Check real column values before concluding that a filter has no data: distinct lists the most frequent values, match finds case- and whitespace-insensitive matches for a value, and range reads the minimum, maximum, and non-null count. Sensitive columns return counts only.",
        object(
          %{
            "table" => %{"type" => "string"},
            "schema" => @nullable_string,
            "probes" => %{
              "type" => "array",
              "minItems" => 1,
              "items" =>
                object(
                  %{
                    "column" => %{"type" => "string"},
                    "kind" => %{"type" => "string", "enum" => ["distinct", "match", "range"]},
                    "value" => @nullable_string
                  },
                  ["column", "kind"]
                )
            }
          },
          ["table", "probes"]
        ),
        object(
          %{
            "results" => %{
              "type" => "array",
              "items" =>
                object(
                  %{
                    "column" => %{"type" => "string"},
                    "kind" => %{"type" => "string"},
                    "masked" => %{"type" => "boolean"},
                    "values" => %{
                      "type" => "array",
                      "items" =>
                        object(%{"value" => @param, "count" => %{"type" => "integer"}}, [
                          "count"
                        ])
                    },
                    "exact_count" => @nullable_integer,
                    "min" => @param,
                    "max" => @param,
                    "row_count" => @nullable_integer,
                    "non_null_count" => @nullable_integer
                  },
                  ["column", "kind", "masked"]
                )
            }
          },
          ["results"]
        )
      ),
      tool(
        toolkit,
        "explain",
        "Show the database's estimated execution plan for one read-only query without running it.",
        object(
          %{"sql" => %{"type" => "string"}, "params" => %{"type" => "array", "items" => @param}},
          ["sql"]
        ),
        object(%{"plan" => %{}, "sql" => %{"type" => "string"}}, ["plan", "sql"])
      ),
      tool(
        toolkit,
        "query",
        "Run one read-only SELECT or WITH query in a read-only session. The result is an evidence envelope: column types, at most max_rows rows, truncated when more rows exist, elapsed time, the executed SQL, the data timestamp, and warnings such as fanout_risk. Pass export to save every row to a Pod CSV file.",
        object(
          %{
            "sql" => %{"type" => "string"},
            "params" => %{"type" => "array", "items" => @param},
            "max_rows" => %{"type" => "integer", "minimum" => 1},
            "export" => @destination
          },
          ["sql"]
        ),
        @envelope
      ),
      tool(
        toolkit,
        "metric_query",
        "Run a published Brain metric by its slug and immutable revision with typed parameters. Ankole compiles the metric's SQL deterministically, so the result matches every other caller of that revision.",
        object(
          %{
            "metric_slug" => %{"type" => "string"},
            "revision" => %{"type" => "integer", "minimum" => 1},
            "params" => %{"type" => "object"}
          },
          ["metric_slug", "revision"]
        ),
        %{"type" => "object"}
      )
    ]
  end

  defp tool(toolkit, name, description, input, output) do
    %ToolSpec{
      toolkit: toolkit,
      name: name,
      description: description,
      input_schema: input,
      output_schema: output,
      operation: name,
      annotations: ToolSpec.annotations(true),
      subject_policy: :any_principal,
      upstream_auth: :app_token
    }
  end

  defp object(properties, required),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
end
