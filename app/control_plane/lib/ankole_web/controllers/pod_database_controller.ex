defmodule AnkoleWeb.PodDatabaseController do
  @moduledoc "Browser contracts for logical tables, views, and versioned record batches."
  use AnkoleWeb, :controller
  import AnkoleWeb.PodResponse, only: [respond: 3]
  use OpenApiSpex.ControllerSpecs
  alias AnkoleWeb.Schemas.PodDatabase

  tags(["Pod content"])
  alias Ankole.Pod.Database
  alias Ankole.Pod.Serialization
  import Ankole.Pod.Serialization, only: [item: 1]

  operation(:tables,
    operation_id: "podDatabaseTables",
    summary: "podDatabaseTables",
    parameters: [page_id: [in: :path, type: :string, required: true]],
    responses: %{
      200 => {"Success", "application/json", PodDatabase.Tables},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def tables(conn, %{"page_id" => id}),
    do:
      respond(
        conn,
        Database.list_tables(uid(conn), id),
        &%{tables: Enum.map(&1.tables, fn table -> item(table) end)}
      )

  operation(:create_table,
    operation_id: "podDatabaseTableCreate",
    summary: "podDatabaseTableCreate",
    parameters: [page_id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "application/json", PodDatabase.TableCreate, required: true},
    responses: %{
      200 => {"Success", "application/json", PodDatabase.TableResult},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def create_table(conn, %{"page_id" => id}),
    do: respond(conn, Database.create_table(uid(conn), id, conn.body_params), &%{table: item(&1)})

  operation(:show,
    operation_id: "podDatabaseSchema",
    summary: "podDatabaseSchema",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: %{
      200 => {"Success", "application/json", PodDatabase.TableSchema},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def show(conn, %{"id" => id}),
    do:
      respond(conn, Database.get_table(uid(conn), id), fn result ->
        %{
          table: item(result.table),
          fields: Enum.map(result.fields, &item/1),
          views: Enum.map(result.views, &item/1),
          mode: result.mode,
          timezone: result.timezone,
          readonly_field_ids: result.readonly_field_ids,
          local_query: result.local_query,
          limits: result.limits
        }
      end)

  operation(:query,
    operation_id: "podDatabaseQuery",
    summary: "podDatabaseQuery",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "application/json", PodDatabase.RecordQuery, required: true},
    responses: %{
      200 => {"Success", "application/json", PodDatabase.Records},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def query(conn, %{"id" => id}),
    do: respond(conn, Database.query(uid(conn), id, conn.body_params), & &1)

  operation(:aggregate,
    operation_id: "podDatabaseAggregate",
    summary: "podDatabaseAggregate",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "application/json", PodDatabase.AggregateQuery, required: true},
    responses: %{
      200 => {"Success", "application/json", PodDatabase.AggregateResult},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def aggregate(conn, %{"id" => id}),
    do: respond(conn, Database.aggregate(uid(conn), id, conn.body_params), & &1)

  operation(:write,
    operation_id: "podDatabaseWrite",
    summary: "podDatabaseWrite",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "application/json", PodDatabase.RecordWrite, required: true},
    responses: %{
      200 => {"Success", "application/json", PodDatabase.WriteResult},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def write(conn, %{"id" => id}),
    do:
      respond(conn, Database.write_records(uid(conn), id, conn.body_params), fn result ->
        Map.update!(result, :records, &Enum.map(&1, fn record -> item(record) end))
      end)

  operation(:create_field,
    operation_id: "podDatabaseFieldCreate",
    summary: "podDatabaseFieldCreate",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "application/json", PodDatabase.FieldWrite, required: true},
    responses: %{
      200 => {"Success", "application/json", PodDatabase.FieldResult},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def create_field(conn, %{"id" => id}),
    do: respond(conn, Database.create_field(uid(conn), id, conn.body_params), &%{field: item(&1)})

  operation(:update_field,
    operation_id: "podDatabaseFieldUpdate",
    summary: "podDatabaseFieldUpdate",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "application/json", PodDatabase.FieldUpdate, required: true},
    responses: %{
      200 => {"Success", "application/json", PodDatabase.FieldResult},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def update_field(conn, %{"id" => id}),
    do: respond(conn, Database.update_field(uid(conn), id, conn.body_params), &%{field: item(&1)})

  operation(:delete_field,
    operation_id: "podDatabaseFieldDelete",
    summary: "podDatabaseFieldDelete",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "application/json", PodDatabase.DeleteVersion, required: true},
    responses: %{
      200 => {"Success", "application/json", PodDatabase.FieldResult},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def delete_field(conn, %{"id" => id}),
    do:
      respond(
        conn,
        Database.delete_field(
          uid(conn),
          id,
          Ankole.Attrs.get(conn.body_params, :version)
        ),
        &%{field: item(&1)}
      )

  operation(:create_view,
    operation_id: "podDatabaseViewCreate",
    summary: "podDatabaseViewCreate",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "application/json", PodDatabase.ViewWrite, required: true},
    responses: %{
      200 => {"Success", "application/json", PodDatabase.ViewResult},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def create_view(conn, %{"id" => id}),
    do: respond(conn, Database.create_view(uid(conn), id, conn.body_params), &%{view: item(&1)})

  operation(:update_view,
    operation_id: "podDatabaseViewUpdate",
    summary: "podDatabaseViewUpdate",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "application/json", PodDatabase.ViewUpdate, required: true},
    responses: %{
      200 => {"Success", "application/json", PodDatabase.ViewResult},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def update_view(conn, %{"id" => id}),
    do: respond(conn, Database.update_view(uid(conn), id, conn.body_params), &%{view: item(&1)})

  operation(:delete_view,
    operation_id: "podDatabaseViewDelete",
    summary: "podDatabaseViewDelete",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "application/json", PodDatabase.DeleteVersion, required: true},
    responses: %{
      200 => {"Success", "application/json", PodDatabase.ViewResult},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def delete_view(conn, %{"id" => id}),
    do:
      respond(
        conn,
        Database.delete_view(
          uid(conn),
          id,
          Ankole.Attrs.get(conn.body_params, :version)
        ),
        &%{view: item(&1)}
      )

  operation(:copy,
    operation_id: "podDatabaseCopy",
    summary: "podDatabaseCopy",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "application/json", PodDatabase.CopyRequest, required: true},
    responses: %{
      200 => {"Success", "application/json", PodDatabase.CopyResult},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def copy(conn, %{"id" => id}),
    do:
      respond(
        conn,
        Database.copy_table(uid(conn), id, conn.body_params),
        &%{page: Serialization.page_json(&1.page), table: item(&1.table)}
      )

  defp uid(conn), do: conn.assigns.current_principal_uid
end
