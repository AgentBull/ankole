defmodule AnkoleWeb.BrainController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for the Brain read models: the health surface, the object
  page, the installed object types, the per-principal audit, the search
  preview, and the Dreaming trigger.

  These views combine many Brain resources, so no single resource gives
  them. The Brain resource routes are in the JSON:API at `/api/v2/brain`
  (`Ankole.Brain`).
  """

  use AnkoleWeb, :controller

  action_fallback(:fallback)
  use OpenAPISpex.ControllerSpecs

  alias Ankole.Brain.Claims
  alias Ankole.Brain.GetPage
  alias Ankole.Brain.Health
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Recall
  alias Ankole.Brain.Schemas.Claim
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.BrainAPI

  @list_limit 100

  tags(["Brain"])
  security([%{"consoleSession" => []}])

  # Object slugs contain `/`, which OpenAPI path templates cannot express,
  # so the object page takes the slug as a query parameter instead of a
  # wildcard path segment.
  @slug_parameter [slug: [in: :query, type: :string, required: true]]

  operation(:health,
    summary: "Read the Brain health snapshot",
    responses: [ok: {"Health", "application/json", BrainAPI.BrainHealthResponse}]
  )

  operation(:dream,
    summary: "Enqueue a Dreaming round without changing its schedule",
    responses: [ok: {"Result", "application/json", BrainAPI.BrainDreamResponse}]
  )

  operation(:object_types,
    summary: "List installed Brain object types",
    responses: [ok: {"Types", "application/json", BrainAPI.BrainObjectTypesResponse}]
  )

  operation(:show_object,
    summary: "Read one Brain object with full admin detail",
    parameters: @slug_parameter,
    responses: [ok: {"Object", "application/json", BrainAPI.BrainObjectShowResponse}]
  )

  operation(:search_preview,
    summary: "Run recall as any Principal for diagnosis",
    request_body:
      {"Preview", "application/json", BrainAPI.BrainSearchPreviewRequest, required: true},
    responses: [ok: {"Result", "application/json", BrainAPI.BrainSearchPreviewResponse}]
  )

  operation(:principal_knowledge,
    summary: "Audit all knowledge related to one Principal",
    parameters: [principal_uid: [in: :path, type: :string, required: true]],
    responses: [ok: {"Claims", "application/json", BrainAPI.BrainClaimListResponse}]
  )

  def health(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "brain", "read") do
      json_plain(conn, %{health: Health.snapshot()})
    end
  end

  def dream(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "brain", "update"),
         {:ok, result} <- Ankole.Brain.Jobs.Dreaming.enqueue() do
      json_plain(conn, %{result: result})
    end
  end

  def object_types(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "brain", "read") do
      json_plain(conn, %{types: Objects.installed_type_names()})
    end
  end

  def show_object(conn, %{"slug" => slug}) do
    with :ok <- ConsolePolicy.authorize(conn, "brain", "read") do
      case GetPage.get_page_admin(slug) do
        {:ok, page} -> json_plain(conn, %{object: page})
        {:ambiguous, candidates} -> json_plain(conn, %{candidates: candidates})
        {:error, :not_found} -> {:error, :not_found}
      end
    end
  end

  # Search preview executes recall as any Principal to diagnose knowledge
  # boundaries and disclosure behavior.
  def search_preview(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "brain", "read"),
         {:ok, principal_uid} <- required_text(params, "principal_uid"),
         {:ok, query} <- required_text(params, "query") do
      disclosure = %{
        mode: parse_mode(params["disclosure_mode"]),
        asker_uid: params["asker_uid"],
        present_uids: List.wrap(params["present_uids"] || [])
      }

      case Recall.recall(principal_uid, %{query: query}, disclosure: disclosure) do
        {:ok, result} -> json_plain(conn, %{result: result})
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Per-principal audit: everything where the Principal is holder, author,
  # or the audience.
  def principal_knowledge(conn, %{"principal_uid" => principal_uid}) do
    with :ok <- ConsolePolicy.authorize(conn, "brain", "read") do
      claims =
        principal_uid
        |> Claims.list_for_principal_audit(limit: @list_limit)
        |> Enum.map(&claim_detail/1)

      json_plain(conn, %{claims: claims})
    end
  end

  # Brain payloads carry DateTime and Date values in many nested shapes, and
  # Torque cannot encode calendar structs, so every response passes through
  # the JSON-plain transform instead of per-field ISO conversion.
  defp json_plain(conn, payload), do: json(conn, Ankole.JSON.plain(payload))

  defp claim_detail(nil), do: nil

  defp claim_detail(%Claim{} = claim) do
    %{
      id: claim.id,
      claim_type: claim.claim_type,
      claim: claim.claim,
      kind: claim.kind,
      holder: claim.holder,
      audience_scope: claim.audience_scope,
      author: claim.author && Map.from_struct(claim.author),
      object_slug: claim.object_slug,
      conversation_id: claim.conversation_id,
      notability: claim.notability,
      confidence: claim.confidence,
      valid_from: claim.valid_from,
      valid_until: claim.valid_until,
      expired_at: claim.expired_at,
      weight: claim.weight,
      active: claim.active,
      since_date: claim.since_date,
      until_date: claim.until_date,
      graded_quality: claim.graded_quality,
      graded_confidence: claim.graded_confidence,
      resolved_quality: claim.resolved_quality,
      resolved_outcome: claim.resolved_outcome,
      resolved_at: claim.resolved_at,
      superseded_by: claim.superseded_by,
      provenance: claim.provenance,
      created_at: claim.created_at
    }
  end

  defp parse_mode("strict"), do: :strict
  defp parse_mode(_mode), do: :relaxed

  defp required_text(params, key),
    do: Ankole.Attrs.required_text(map_value(params, key), {:missing, key})

  defp map_value(map, key) when is_map(map) and is_binary(key),
    do: Ankole.Attrs.get_string_first(map, key)

  defp fallback(conn, failure), do: ConsoleErrors.fallback(conn, failure, &error/2)

  defp error(conn, :not_found), do: ConsoleErrors.not_found(conn, "resource not found")

  defp error(conn, {:missing, key}),
    do:
      ConsoleErrors.render(conn, 422, "validation_failed", "#{key} is required", [
        %{path: key, kind: "missing"}
      ])

  defp error(conn, :brain_disabled),
    do: ConsoleErrors.render(conn, 422, "brain_disabled", "Brain is disabled")

  defp error(conn, reason) do
    ConsoleErrors.unexpected(
      conn,
      "brain.api.unexpected_error",
      reason,
      "brain_request_invalid",
      "brain request failed"
    )
  end
end
