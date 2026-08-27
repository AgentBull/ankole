defmodule AnkoleWeb.BrainController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for the Brain knowledge space: object browsing with
  version history, claim management, take resolution, contradiction triage,
  promotion review, source management, per-principal audit, search preview,
  and the health surface.

  Console edits run the same write contracts as every other writer; the
  operating Principal enters `author_uid`.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  import Ecto.Query, warn: false

  alias Ankole.Brain.Access
  alias Ankole.Brain.Claims
  alias Ankole.Brain.Dreaming
  alias Ankole.Brain.Forget
  alias Ankole.Brain.GetPage
  alias Ankole.Brain.Health
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Promotion
  alias Ankole.Brain.Recall
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Contradiction
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.ObjectVersion
  alias Ankole.Brain.Schemas.SchemaSuggestion
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Brain.SourceLearning
  alias Ankole.Repo
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.BrainAPI

  @list_limit 100

  tags(["Brain"])
  security([%{"consoleBearer" => []}])

  # Object slugs contain `/`, which OpenAPI path templates cannot express,
  # so every object operation carries the slug as a query parameter or in
  # the request body instead of a wildcard path segment.
  @slug_parameter [slug: [in: :query, type: :string, required: true]]

  operation(:health,
    summary: "Read the Brain health snapshot",
    responses: [ok: {"Health", "application/json", BrainAPI.BrainHealthResponse}]
  )

  operation(:list_objects,
    summary: "List Brain objects by prefix or search",
    parameters: [
      prefix: [in: :query, type: :string, required: false],
      q: [in: :query, type: :string, required: false],
      deleted: [in: :query, type: :boolean, required: false]
    ],
    responses: [ok: {"Objects", "application/json", BrainAPI.BrainObjectListResponse}]
  )

  operation(:show_object,
    summary: "Read one Brain object with full admin detail",
    parameters: @slug_parameter,
    responses: [ok: {"Object", "application/json", BrainAPI.BrainObjectShowResponse}]
  )

  operation(:object_versions,
    summary: "List one object's version history",
    parameters: @slug_parameter,
    responses: [ok: {"Versions", "application/json", BrainAPI.BrainObjectVersionsResponse}]
  )

  operation(:rollback_object,
    summary: "Roll one object back to a stored version",
    request_body:
      {"Rollback", "application/json", BrainAPI.BrainObjectRollbackRequest, required: true},
    responses: [ok: {"Object", "application/json", BrainAPI.BrainObjectSummaryResponse}]
  )

  operation(:forget_object,
    summary: "Soft-delete one object with a reason",
    request_body:
      {"Forget", "application/json", BrainAPI.BrainObjectForgetRequest, required: true},
    responses: [ok: {"Object", "application/json", BrainAPI.BrainObjectSummaryResponse}]
  )

  operation(:restore_object,
    summary: "Restore one soft-deleted object inside its purge window",
    request_body:
      {"Restore", "application/json", BrainAPI.BrainObjectRestoreRequest, required: true},
    responses: [ok: {"Object", "application/json", BrainAPI.BrainObjectSummaryResponse}]
  )

  operation(:list_claims,
    summary: "List claims with filters",
    parameters: [
      object_slug: [in: :query, type: :string, required: false],
      claim_type: [in: :query, type: :string, required: false],
      status: [in: :query, type: :string, required: false]
    ],
    responses: [ok: {"Claims", "application/json", BrainAPI.BrainClaimListResponse}]
  )

  operation(:supersede_claim,
    summary: "Supersede one claim with corrected content",
    parameters: [claim_id: [in: :path, type: :string, required: true]],
    request_body:
      {"Supersede", "application/json", BrainAPI.BrainClaimSupersedeRequest, required: true},
    responses: [ok: {"Claim", "application/json", BrainAPI.BrainClaimResponse}]
  )

  operation(:forget_claim,
    summary: "Expire a fact or deactivate a take with a reason",
    parameters: [claim_id: [in: :path, type: :string, required: true]],
    request_body:
      {"Forget", "application/json", BrainAPI.BrainClaimForgetRequest, required: true},
    responses: [ok: {"Claim", "application/json", BrainAPI.BrainClaimResponse}]
  )

  operation(:resolve_take,
    summary: "Resolve one take; resolution is immutable",
    parameters: [claim_id: [in: :path, type: :string, required: true]],
    request_body:
      {"Resolve", "application/json", BrainAPI.BrainTakeResolveRequest, required: true},
    responses: [ok: {"Claim", "application/json", BrainAPI.BrainClaimResponse}]
  )

  operation(:list_contradictions,
    summary: "List contradiction findings",
    parameters: [status: [in: :query, type: :string, required: false]],
    responses: [
      ok: {"Contradictions", "application/json", BrainAPI.BrainContradictionListResponse}
    ]
  )

  operation(:decide_contradiction,
    summary: "Resolve or dismiss one contradiction",
    parameters: [contradiction_id: [in: :path, type: :string, required: true]],
    request_body:
      {"Decide", "application/json", BrainAPI.BrainContradictionDecideRequest, required: true},
    responses: [
      ok: {"Decision", "application/json", BrainAPI.BrainContradictionDecisionResponse}
    ]
  )

  operation(:list_suggestions,
    summary: "List schema promotion suggestions",
    parameters: [status: [in: :query, type: :string, required: false]],
    responses: [ok: {"Suggestions", "application/json", BrainAPI.BrainSuggestionListResponse}]
  )

  operation(:decide_suggestion,
    summary: "Approve or reject one promotion suggestion",
    parameters: [suggestion_id: [in: :path, type: :string, required: true]],
    request_body:
      {"Decide", "application/json", BrainAPI.BrainSuggestionDecideRequest, required: true},
    responses: [ok: {"Result", "application/json", BrainAPI.BrainPromotionResultResponse}]
  )

  operation(:list_sources,
    summary: "List learning sources",
    responses: [ok: {"Sources", "application/json", BrainAPI.BrainSourceListResponse}]
  )

  operation(:create_source,
    summary: "Register one file or url learning source",
    request_body:
      {"Source", "application/json", BrainAPI.BrainSourceCreateRequest, required: true},
    responses: [ok: {"Source", "application/json", BrainAPI.BrainSourceCreateResponse}]
  )

  operation(:learn_source,
    summary: "Enqueue one learning run for a source",
    parameters: [source_id: [in: :path, type: :string, required: true]],
    responses: [ok: {"Result", "application/json", BrainAPI.BrainSourceLearnResponse}]
  )

  operation(:archive_source,
    summary: "Archive one source; stored memory stays",
    parameters: [source_id: [in: :path, type: :string, required: true]],
    responses: [ok: {"Source", "application/json", BrainAPI.BrainSourceArchiveResponse}]
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
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def list_objects(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "brain", "read") do
      objects =
        Object
        |> maybe_prefix(params["prefix"])
        |> maybe_search(params["q"])
        |> maybe_deleted(params["deleted"])
        |> order_by([object], asc: object.slug)
        |> limit(@list_limit)
        |> Repo.all()
        |> Enum.map(&object_summary/1)

      json_plain(conn, %{objects: objects})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show_object(conn, %{"slug" => slug}) do
    with :ok <- ConsolePolicy.authorize(conn, "brain", "read") do
      case GetPage.get_page_admin(slug) do
        {:ok, page} -> json_plain(conn, %{object: page})
        {:ambiguous, candidates} -> json_plain(conn, %{candidates: candidates})
        {:error, :not_found} -> error(conn, :not_found)
      end
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def object_versions(conn, %{"slug" => slug}) do
    with :ok <- ConsolePolicy.authorize(conn, "brain", "read"),
         {:ok, object} <- Objects.resolve_slug(slug) do
      versions =
        ObjectVersion
        |> where([version], version.object_id == ^object.id)
        |> order_by([version], desc: version.snapshot_at)
        |> limit(@list_limit)
        |> Repo.all()
        |> Enum.map(fn version ->
          %{
            id: version.id,
            author_uid: version.author_uid,
            body: version.body,
            meta: version.meta,
            snapshot_at: version.snapshot_at
          }
        end)

      json_plain(conn, %{versions: versions})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def rollback_object(conn, %{"slug" => slug, "version_id" => version_id}) do
    with :ok <- ConsolePolicy.authorize(conn, "brain", "update"),
         {:ok, object} <-
           Objects.rollback(slug, version_id, conn.assigns.current_principal_uid) do
      json_plain(conn, %{object: object_summary(object)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def forget_object(conn, %{"slug" => slug} = params) do
    with :ok <- ConsolePolicy.authorize(conn, "brain", "update"),
         {:ok, object} <- Forget.forget_object(slug, params["reason"] || "", :admin) do
      json_plain(conn, %{object: object_summary(object)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  # Restore closes the soft-delete recovery loop: without it the purge TTL
  # would only be a delay, not a recovery window.
  def restore_object(conn, %{"slug" => slug}) do
    with :ok <- ConsolePolicy.authorize(conn, "brain", "update"),
         {:ok, object} <- Objects.restore(slug) do
      json_plain(conn, %{object: object_summary(object)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def list_claims(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "brain", "read") do
      claims =
        Claim
        |> maybe_claim_filter(params)
        |> order_by([claim], desc: claim.created_at)
        |> limit(@list_limit)
        |> Repo.all()
        |> Enum.map(&claim_detail/1)

      json_plain(conn, %{claims: claims})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def supersede_claim(conn, %{"claim_id" => claim_id} = params) do
    attrs =
      %{claim: params["claim"]}
      |> maybe_put(:kind, params["kind"])
      |> maybe_put(:confidence, params["confidence"])
      |> maybe_put(:weight, params["weight"])
      |> maybe_put(:notability, params["notability"])
      |> maybe_put(:audience_scope, params["audience_scope"])
      |> maybe_put(:provenance, params["provenance"])

    with :ok <- ConsolePolicy.authorize(conn, "brain", "update"),
         {:ok, claim} <-
           Claims.supersede_claim(claim_id, attrs, conn.assigns.current_principal_uid) do
      json_plain(conn, %{claim: claim_detail(claim)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def forget_claim(conn, %{"claim_id" => claim_id} = params) do
    with :ok <- ConsolePolicy.authorize(conn, "brain", "update"),
         {:ok, claim} <- Forget.forget_claim(claim_id, params["reason"] || "", :admin) do
      json_plain(conn, %{claim: claim_detail(claim)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def resolve_take(conn, %{"claim_id" => claim_id} = params) do
    resolution = %{
      resolved_quality: params["resolved_quality"],
      resolved_outcome: params["resolved_outcome"],
      resolved_value: params["resolved_value"],
      resolved_unit: params["resolved_unit"],
      resolution_provenance: params["resolution_provenance"]
    }

    with :ok <- ConsolePolicy.authorize(conn, "brain", "update"),
         {:ok, claim} <-
           Claims.resolve_take(claim_id, resolution, conn.assigns.current_principal_uid) do
      json_plain(conn, %{claim: claim_detail(claim)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def list_contradictions(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "brain", "read") do
      status = params["status"] || "open"

      contradictions =
        Contradiction
        |> where([contradiction], contradiction.status == ^status)
        |> order_by([contradiction], desc: contradiction.created_at)
        |> limit(@list_limit)
        |> Repo.all()
        |> Enum.map(fn contradiction ->
          %{
            id: contradiction.id,
            a_claim: claim_detail(Repo.get(Claim, contradiction.a_claim_id)),
            b_claim: claim_detail(Repo.get(Claim, contradiction.b_claim_id)),
            verdict: contradiction.verdict,
            axis: contradiction.axis,
            severity: contradiction.severity,
            confidence: contradiction.confidence,
            status: contradiction.status,
            created_at: contradiction.created_at
          }
        end)

      json_plain(conn, %{contradictions: contradictions})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def decide_contradiction(conn, %{"contradiction_id" => id} = params) do
    status = params["status"]

    with :ok <- ConsolePolicy.authorize(conn, "brain", "update"),
         true <- status in ["resolved", "dismissed"] || {:error, :invalid_status},
         {:ok, updated} <- Dreaming.decide_contradiction(id, status, params["resolution_note"]) do
      json_plain(conn, %{contradiction: %{id: updated.id, status: updated.status}})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def list_suggestions(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "brain", "read") do
      status = params["status"] || "pending"

      suggestions =
        SchemaSuggestion
        |> where([suggestion], suggestion.status == ^status)
        |> order_by([suggestion], desc: suggestion.created_at)
        |> limit(@list_limit)
        |> Repo.all()
        |> Enum.map(fn suggestion ->
          %{
            id: suggestion.id,
            kind: suggestion.kind,
            term: suggestion.term,
            target_type: suggestion.target_type,
            evidence_count: suggestion.evidence_count,
            rationale: suggestion.rationale,
            status: suggestion.status,
            created_at: suggestion.created_at
          }
        end)

      json_plain(conn, %{suggestions: suggestions})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def decide_suggestion(conn, %{"suggestion_id" => id} = params) do
    decision = params["decision"]
    operator = conn.assigns.current_principal_uid

    with :ok <- ConsolePolicy.authorize(conn, "brain", "update") do
      result =
        case decision do
          "approve" ->
            Promotion.approve(id, operator, %{
              primitive: params["primitive"],
              slug_prefix: params["slug_prefix"],
              target_type: params["target_type"],
              extractable: params["extractable"]
            })

          "reject" ->
            Promotion.reject(id, operator)

          _invalid ->
            {:error, :invalid_decision}
        end

      case result do
        {:ok, outcome} -> json_plain(conn, %{result: outcome})
        {:error, reason} -> error(conn, reason)
      end
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def list_sources(conn, _params) do
    with :ok <- ConsolePolicy.authorize(conn, "brain", "read") do
      sources =
        Source
        |> order_by([source], desc: source.updated_at)
        |> limit(@list_limit)
        |> Repo.all()
        |> Enum.map(fn source ->
          %{
            id: source.id,
            upstream_id: source.upstream_id,
            kind: source.kind,
            name: source.name,
            default_audience_scope: source.default_audience_scope,
            upstream_revision: source.upstream_revision,
            last_sync_at: source.last_sync_at,
            archived_at: source.archived_at
          }
        end)

      json_plain(conn, %{sources: sources})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def create_source(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "brain", "update"),
         {:ok, source} <-
           SourceLearning.register_source(%{
             upstream_id: params["upstream_id"],
             kind: params["kind"],
             name: params["name"],
             default_audience_scope: params["default_audience_scope"],
             config: params["config"] || %{}
           }) do
      json_plain(conn, %{source: %{id: source.id, kind: source.kind, name: source.name}})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def learn_source(conn, %{"source_id" => source_id}) do
    with :ok <- ConsolePolicy.authorize(conn, "brain", "update"),
         {:ok, result} <- SourceLearning.enqueue_learn(source_id) do
      json_plain(conn, %{result: result})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def archive_source(conn, %{"source_id" => source_id}) do
    with :ok <- ConsolePolicy.authorize(conn, "brain", "update"),
         {:ok, archived} <- SourceLearning.archive_source(source_id) do
      json_plain(conn, %{source: %{id: archived.id, archived_at: archived.archived_at}})
    else
      {:error, reason} -> error(conn, reason)
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
        {:error, reason} -> error(conn, reason)
      end
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  # Per-principal audit: everything where the Principal is holder, author,
  # or the audience.
  def principal_knowledge(conn, %{"principal_uid" => principal_uid}) do
    with :ok <- ConsolePolicy.authorize(conn, "brain", "read") do
      holder_slugs = ["people/#{principal_uid}", "agents/#{principal_uid}"]
      scope = "principal:#{principal_uid}"

      claims =
        Claim
        |> where(
          [claim],
          claim.holder in ^holder_slugs or claim.author_uid == ^principal_uid or
            claim.audience_scope == ^scope
        )
        |> order_by([claim], desc: claim.created_at)
        |> limit(@list_limit)
        |> Repo.all()
        |> Enum.map(&claim_detail/1)

      json_plain(conn, %{claims: claims})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  # Helpers

  # Brain payloads carry DateTime and Date values in many nested shapes, and
  # Torque cannot encode calendar structs, so every response passes through
  # the JSON-plain transform instead of per-field ISO conversion.
  defp json_plain(conn, payload), do: json(conn, Ankole.JSON.plain(payload))

  defp object_summary(%Object{} = object) do
    %{
      slug: object.slug,
      type: object.type,
      subtype: object.subtype,
      title: object.title,
      effective_date: object.effective_date,
      emotional_weight: object.emotional_weight,
      deleted_at: object.deleted_at,
      updated_at: object.updated_at
    }
  end

  defp claim_detail(nil), do: nil

  defp claim_detail(%Claim{} = claim) do
    %{
      id: claim.id,
      claim_type: claim.claim_type,
      claim: claim.claim,
      kind: claim.kind,
      holder: claim.holder,
      audience_scope: claim.audience_scope,
      author_uid: claim.author_uid,
      object_slug: claim.object_slug,
      signal_gateway_channel_id: claim.signal_gateway_channel_id,
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

  defp maybe_prefix(query, prefix) when is_binary(prefix) and prefix != "" do
    where(query, [object], like(object.slug, ^(prefix <> "%")))
  end

  defp maybe_prefix(query, _prefix), do: query

  defp maybe_search(query, term) when is_binary(term) and term != "" do
    pattern = "%" <> term <> "%"

    where(
      query,
      [object],
      ilike(object.title, ^pattern) or ilike(object.slug, ^pattern)
    )
  end

  defp maybe_search(query, _term), do: query

  defp maybe_deleted(query, "true"), do: where(query, [object], not is_nil(object.deleted_at))
  defp maybe_deleted(query, _other), do: where(query, [object], is_nil(object.deleted_at))

  defp maybe_claim_filter(query, params) do
    query
    |> then(fn query ->
      case params["object_slug"] do
        slug when is_binary(slug) and slug != "" ->
          where(query, [claim], claim.object_slug == ^slug)

        _missing ->
          query
      end
    end)
    |> then(fn query ->
      case params["claim_type"] do
        type when type in ["fact", "take"] -> where(query, [claim], claim.claim_type == ^type)
        _missing -> query
      end
    end)
    |> then(fn query ->
      case params["status"] do
        "current" -> Access.filter_current_claims(query)
        _all -> query
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_mode("strict"), do: :strict
  defp parse_mode(_mode), do: :relaxed

  defp required_text(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing, key}}
          text -> {:ok, text}
        end

      _value ->
        {:error, {:missing, key}}
    end
  end

  defp error(conn, :forbidden), do: render_error(conn, 403, "forbidden", "access denied")
  defp error(conn, :not_found), do: render_error(conn, 404, "not_found", "resource not found")

  defp error(conn, {:missing, key}),
    do: render_error(conn, 422, "validation_failed", "#{key} is required")

  defp error(conn, reason) do
    render_error(conn, 422, "brain_request_invalid", "brain request failed", [
      %{reason: inspect(reason)}
    ])
  end

  defp render_error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
