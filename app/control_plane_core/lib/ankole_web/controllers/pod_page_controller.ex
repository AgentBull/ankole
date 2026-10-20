defmodule AnkoleWeb.PodPageController do
  @moduledoc "Browser contracts for pages in the selected Pod."
  use AnkoleWeb, :controller
  import AnkoleWeb.PodResponse, only: [respond: 3]
  use OpenApiSpex.ControllerSpecs
  alias OpenApiSpex.Schema
  alias AnkoleWeb.Schemas.PodContent

  tags(["Pod content"])
  alias Ankole.Pod.{Access, Documents, Pages}
  import Ankole.Pod.Serialization, only: [page_json: 1, detail_json: 1, document_json: 1]

  operation(:realtime_token,
    operation_id: "podRealtimeToken",
    summary: "podRealtimeToken",
    parameters: [],
    responses: %{
      200 => {"Success", "application/json", PodContent.RealtimeToken},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def realtime_token(conn, _params) do
    respond(conn, Access.principal(uid(conn)), fn principal ->
      %{
        token: AnkoleWeb.PodSocket.token(conn),
        principal: %{uid: principal.uid, name: principal.display_name}
      }
    end)
  end

  operation(:index,
    operation_id: "podPageList",
    summary: "podPageList",
    parameters: [
      scope: [
        in: :query,
        schema: %Schema{
          type: :string,
          enum: ["all", "space", "private", "shared", "recent", "favorites", "trash"]
        },
        required: false
      ],
      query: [in: :query, schema: %Schema{type: :string}, required: false]
    ],
    responses: %{
      200 => {"Success", "application/json", PodContent.PageList},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def index(conn, params) do
    principal = uid(conn)

    result =
      with {:ok, pages} <- Pages.list(principal, params),
           pages = Enum.map(pages, &page_json/1) do
        {:ok, %{pages: pages, principal_uid: principal}}
      end

    respond(conn, result, & &1)
  end

  operation(:create,
    operation_id: "podPageCreate",
    summary: "podPageCreate",
    parameters: [],
    request_body: {"Request", "application/json", PodContent.PageCreate, required: true},
    responses: %{
      200 => {"Success", "application/json", PodContent.PageResult},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def create(conn, _params),
    do: respond(conn, Pages.create(uid(conn), conn.body_params), &%{page: page_json(&1)})

  operation(:show,
    operation_id: "podPageRead",
    summary: "podPageRead",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: %{
      200 => {"Success", "application/json", PodContent.PageDetail},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def show(conn, %{"id" => id}), do: respond(conn, Pages.get(uid(conn), id), &detail_json/1)

  operation(:update,
    operation_id: "podPageUpdate",
    summary: "podPageUpdate",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "application/json", PodContent.PageUpdate, required: true},
    responses: %{
      200 => {"Success", "application/json", PodContent.PageResult},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def update(conn, %{"id" => id}),
    do: respond(conn, Pages.update(uid(conn), id, conn.body_params), &%{page: page_json(&1)})

  operation(:move,
    operation_id: "podPageMove",
    summary: "podPageMove",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "application/json", PodContent.PageMove, required: true},
    responses: %{
      200 => {"Success", "application/json", PodContent.PageResult},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def move(conn, %{"id" => id}),
    do: respond(conn, Pages.move(uid(conn), id, conn.body_params), &%{page: page_json(&1)})

  operation(:delete,
    operation_id: "podPageDelete",
    summary: "podPageDelete",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: %{
      200 => {"Success", "application/json", PodContent.PageResult},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def delete(conn, %{"id" => id}),
    do: respond(conn, Pages.delete(uid(conn), id), &%{page: page_json(&1)})

  operation(:delete_embed,
    operation_id: "podEmbedDelete",
    summary: "podEmbedDelete",
    parameters: [
      id: [in: :path, type: :string, required: true],
      ref: [in: :path, type: :string, required: true]
    ],
    responses: %{
      200 => {"Success", "application/json", PodContent.Empty},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def delete_embed(conn, %{"id" => id, "ref" => ref}),
    do: respond(conn, Pages.delete_embed(uid(conn), id, ref), fn _result -> %{} end)

  operation(:restore,
    operation_id: "podPageRestore",
    summary: "podPageRestore",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: %{
      200 => {"Success", "application/json", PodContent.PageResult},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def restore(conn, %{"id" => id}),
    do: respond(conn, Pages.restore(uid(conn), id), &%{page: page_json(&1)})

  operation(:user_state,
    operation_id: "podPageUserState",
    summary: "podPageUserState",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "application/json", PodContent.UserStateWrite, required: true},
    responses: %{
      200 => {"Success", "application/json", PodContent.UserStateResult},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def user_state(conn, %{"id" => id}),
    do:
      respond(conn, Pages.state(uid(conn), id, conn.body_params), fn state ->
        %{user_state: Map.take(state, [:page_id, :favorited_at, :visited_at])}
      end)

  operation(:sharing,
    operation_id: "podPageSharing",
    summary: "podPageSharing",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: %{
      200 => {"Success", "application/json", PodContent.Sharing},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def sharing(conn, %{"id" => id}),
    do: respond(conn, Pages.sharing(uid(conn), id), & &1)

  operation(:subjects,
    operation_id: "podSubjects",
    summary: "podSubjects",
    parameters: [],
    responses: %{
      200 => {"Success", "application/json", PodContent.Subjects},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def subjects(conn, _params),
    do:
      respond(
        conn,
        Pages.subjects(uid(conn)),
        &%{subjects: &1}
      )

  operation(:set_sharing,
    operation_id: "podPageSharingWrite",
    summary: "podPageSharingWrite",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "application/json", PodContent.SharingWrite, required: true},
    responses: %{
      200 => {"Success", "application/json", PodContent.PageResult},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def set_sharing(conn, %{"id" => id}) do
    result =
      if is_binary(Ankole.Attrs.get(conn.body_params, :sharing_version)),
        do: Pages.set_sharing(uid(conn), id, conn.body_params),
        else: {:error, :invalid_request}

    respond(conn, result, &%{page: page_json(&1)})
  end

  operation(:write,
    operation_id: "podDocumentWrite",
    summary: "podDocumentWrite",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "application/json", PodContent.DocumentWrite, required: true},
    responses: %{
      200 => {"Success", "application/json", PodContent.DocumentResult},
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
      respond(
        conn,
        Documents.write(
          uid(conn),
          id,
          Ankole.Attrs.get(conn.body_params, :base_revision),
          Ankole.Attrs.get(conn.body_params, :xml)
        ),
        &document_json/1
      )

  operation(:reconcile_versions,
    operation_id: "podVersions",
    summary: "podVersions",
    parameters: [],
    request_body: {"Request", "application/json", PodContent.VersionsRequest, required: true},
    responses: %{
      200 => {"Success", "application/json", PodContent.Versions},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def reconcile_versions(conn, _params),
    do:
      respond(
        conn,
        Pages.reconcile_versions(
          uid(conn),
          Ankole.Attrs.get(conn.body_params, :pages, []),
          Ankole.Attrs.get(conn.body_params, :tables, [])
        ),
        & &1
      )

  operation(:space,
    operation_id: "podSpace",
    summary: "podSpace",
    parameters: [],
    responses: %{
      200 => {"Success", "application/json", PodContent.Space},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def space(conn, _params), do: respond(conn, Pages.space(uid(conn)), & &1)

  operation(:set_space,
    operation_id: "podSpaceWrite",
    summary: "podSpaceWrite",
    parameters: [],
    request_body: {"Request", "application/json", PodContent.SpaceWrite, required: true},
    responses: %{
      200 => {"Success", "application/json", PodContent.SpaceWrite},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def set_space(conn, _params),
    do: respond(conn, Pages.set_space(uid(conn), Ankole.Attrs.get(conn.body_params, :role)), & &1)

  operation(:space_agent,
    operation_id: "podSpaceAgent",
    summary: "podSpaceAgent",
    parameters: [],
    request_body: {"Request", "application/json", PodContent.SpaceAgentWrite, required: true},
    responses: %{
      200 => {"Success", "application/json", PodContent.SpaceAgentResult},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def space_agent(conn, _params),
    do:
      respond(
        conn,
        Pages.space_agent(
          uid(conn),
          Ankole.Attrs.get(conn.body_params, :principal_uid),
          Ankole.Attrs.get(conn.body_params, :role)
        ),
        & &1
      )

  operation(:remove_space_agent,
    operation_id: "podSpaceAgentDelete",
    summary: "podSpaceAgentDelete",
    parameters: [uid: [in: :path, type: :string, required: true]],
    responses: %{
      200 => {"Success", "application/json", PodContent.SpaceAgentResult},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def remove_space_agent(conn, %{"uid" => agent}),
    do: respond(conn, Pages.remove_space_agent(uid(conn), agent), & &1)

  defp uid(conn), do: conn.assigns.current_principal_uid
end
