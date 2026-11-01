defmodule Ankole.Brain do
  @moduledoc """
  The Brain domain: the Ash domain and top-level write entrypoints of the
  knowledge space.

  Each top-level operation owns its transaction through
  `Ankole.Repo.transact_top_level/2`, locks its rows, runs the write steps,
  and commits them together. A caller in an outer transaction composes the
  `_in_tx` functions of the Brain modules directly.
  """
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  alias Ankole.Brain.{Chunks, Claims, Dreaming, Links, Merge, Objects, Promotion, Sources}
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Contradiction
  alias Ankole.Brain.Schemas.MergeSuggestion
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.ObjectVersion
  alias Ankole.Brain.Schemas.SchemaSuggestion
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Repo

  defdelegate principal_page_slug(type, uid), to: Ankole.Brain.Scope

  defdelegate rename_principal_references_in_tx(old_uid, new_uid, principal_type),
    to: Ankole.Brain.PrincipalReferences,
    as: :rename_in_tx

  # The Console API (`AnkoleWeb.JSONAPI.ConsoleRouter`). An Object slug can
  # contain `/`, so an Object operation takes the slug in the query or in the
  # body, not in the path.
  json_api do
    authorize?(true)
    log_errors?(true)
    show_raised_errors?(false)

    routes do
      base_route "/brain", Ankole.Brain.ConsoleViews do
        route(:get, "/health", :health, name: "get_brain_health", wrap_in_result?: false)
        route(:post, "/dream", :dream, name: "enqueue_brain_dream", wrap_in_result?: false)

        route(:get, "/object-types", :object_types,
          name: "list_brain_object_types",
          wrap_in_result?: false
        )

        route(:get, "/objects/show", :show_object,
          name: "show_brain_object",
          query_params: [:slug],
          wrap_in_result?: false
        )

        route(:post, "/search-preview", :search_preview,
          name: "preview_brain_search",
          wrap_in_result?: false
        )

        route(:get, "/principals/:principal_uid/knowledge", :principal_knowledge,
          name: "list_brain_principal_knowledge",
          wrap_in_result?: false
        )
      end

      base_route "/brain/objects", Object do
        index(:console_list, name: "list_brain_objects", derive_sort?: false)
        route(:post, "/", :console_create, name: "create_brain_object")
        route(:patch, "/", :console_update, name: "update_brain_object")
        route(:post, "/fork", :fork_library_page, name: "fork_brain_object")
        route(:post, "/rollback", :console_rollback, name: "rollback_brain_object")
        route(:post, "/forget", :console_forget, name: "forget_brain_object")
        route(:post, "/restore", :restore_object, name: "restore_brain_object")
      end

      base_route "/brain/object-versions", ObjectVersion do
        index(:console_list, name: "list_brain_object_versions", derive_sort?: false)
      end

      base_route "/brain/claims", Claim do
        index(:console_list, name: "list_brain_claims", derive_sort?: false)
        route(:post, "/:claim_id/supersede", :console_supersede, name: "supersede_brain_claim")
        route(:post, "/:claim_id/forget", :console_forget, name: "forget_brain_claim")
        route(:post, "/:claim_id/resolve", :console_resolve, name: "resolve_brain_take")
      end

      base_route "/brain/contradictions", Contradiction do
        index(:console_list, name: "list_brain_contradictions", derive_sort?: false)
        route(:post, "/:contradiction_id/decide", :decide, name: "decide_brain_contradiction")
      end

      base_route "/brain/suggestions", SchemaSuggestion do
        index(:console_list, name: "list_brain_suggestions", derive_sort?: false)

        route(:post, "/:suggestion_id/approve", :console_approve,
          name: "approve_brain_suggestion"
        )

        route(:post, "/:suggestion_id/reject", :console_reject, name: "reject_brain_suggestion")
      end

      base_route "/brain/merge-suggestions", MergeSuggestion do
        index(:console_list, name: "list_brain_merge_suggestions", derive_sort?: false)

        route(:post, "/:suggestion_id/approve", :console_approve,
          name: "approve_brain_merge_suggestion"
        )

        route(:post, "/:suggestion_id/reject", :console_reject,
          name: "reject_brain_merge_suggestion"
        )
      end

      base_route "/brain/sources", Source do
        index(:console_list, name: "list_brain_sources", derive_sort?: false)
        route(:post, "/", :console_register, name: "create_brain_source")
        route(:patch, "/:source_id", :update_default_scope, name: "update_brain_source")
        route(:post, "/:source_id/learn", :console_learn, name: "learn_brain_source")
        route(:post, "/:source_id/archive", :archive_source, name: "archive_brain_source")
      end
    end
  end

  resources do
    resource(Ankole.Brain.ConsoleViews)
    resource(Ankole.Brain.Schemas.Object)
    resource(Ankole.Brain.Schemas.Chunk)
    resource(Ankole.Brain.Schemas.ObjectVersion)
    resource(Ankole.Brain.Schemas.Claim)
    resource(Ankole.Brain.Schemas.Source)
    resource(Ankole.Brain.Schemas.Timeline)
    resource(Ankole.Brain.Schemas.Link)
    resource(Ankole.Brain.Schemas.Tag)
    resource(Ankole.Brain.Schemas.ObjectAlias)
    resource(Ankole.Brain.Schemas.SlugAlias)
    resource(Ankole.Brain.Schemas.SchemaSuggestion)
    resource(Ankole.Brain.Schemas.MergeSuggestion)
    resource(Ankole.Brain.Schemas.Contradiction)
    resource(Ankole.Brain.Schemas.SchemaPack)
    resource(Ankole.Brain.Schemas.SchemaType)
    resource(Ankole.Brain.Schemas.SchemaLinkType)
    resource(Ankole.Brain.Schemas.SchemaCalibrationDomain)
    resource(Ankole.Brain.Schemas.TakeDomainAssignment)
  end

  def create_object(attrs, writer),
    do: Repo.transact_top_level(fn -> Objects.create_object_in_tx(attrs, writer) end)

  def update_object(slug, attrs, writer, opts \\ %{}) do
    Repo.transact_top_level(fn ->
      Objects.update_object_in_tx(slug, attrs, writer, author: opts[:author])
    end)
  end

  def upsert_source_projection(source, attrs),
    do: Repo.transact_top_level(fn -> Objects.upsert_source_projection_in_tx(source, attrs) end)

  def soft_delete_object(slug, opts \\ %{}) do
    Repo.transact_top_level(fn ->
      Objects.soft_delete_in_tx(slug, reason: opts[:reason], by: opts[:by])
    end)
  end

  def rollback_object(slug, version_id, writer, opts \\ %{}) do
    Repo.transact_top_level(fn ->
      Objects.rollback_in_tx(slug, version_id, writer, author: opts[:author])
    end)
  end

  def fork_library_page(slug),
    do: Repo.transact_top_level(fn -> Objects.fork_library_page_in_tx(slug) end)

  def restore_object(slug),
    do: Repo.transact_top_level(fn -> Objects.restore_in_tx(slug) end)

  def reconcile_chunks(object, opts \\ %{}),
    do:
      Repo.transact_top_level(fn -> Chunks.reconcile_in_tx(object, chunking: opts[:chunking]) end)

  def reconcile_object_links(slug),
    do: Repo.transact_top_level(fn -> Links.reconcile_object_links_in_tx(slug) end)

  def write_fact(attrs, writer, opts \\ %{}),
    do: Claims.write_fact(attrs, writer, opts[:options] || [])

  def supersede_claim(claim_id, attrs, writer, opts \\ %{}),
    do: Claims.supersede_claim(claim_id, attrs, writer, author: opts[:author])

  def expire_fact(claim_id),
    do: Repo.transact_top_level(fn -> Claims.expire_fact_in_tx(claim_id) end)

  def deactivate_take(claim_id),
    do: Repo.transact_top_level(fn -> Claims.deactivate_take_in_tx(claim_id) end)

  def resolve_take(claim_id, resolution, resolved_by),
    do:
      Repo.transact_top_level(fn ->
        Claims.resolve_take_in_tx(claim_id, resolution, resolved_by)
      end)

  def attach_claim_embedding(claim, embedding, signature, opts \\ %{}) do
    Repo.transact_top_level(fn ->
      Claims.attach_embedding_in_tx(
        claim,
        embedding,
        signature,
        opts[:now] || DateTime.utc_now(:microsecond)
      )
    end)
  end

  def archive_source(source_id),
    do: Repo.transact_top_level(fn -> Sources.archive_in_tx(source_id) end)

  def update_source_default_scope(source_id, scope),
    do: Repo.transact_top_level(fn -> Sources.update_default_scope_in_tx(source_id, scope) end)

  def approve_promotion(suggestion_id, decided_by, opts \\ %{}) do
    Repo.transact_top_level(fn ->
      Promotion.approve_in_tx(suggestion_id, decided_by, opts[:attrs] || %{})
    end)
  end

  def reject_promotion(suggestion_id, decided_by),
    do: Repo.transact_top_level(fn -> Promotion.reject_in_tx(suggestion_id, decided_by) end)

  def approve_merge(suggestion_id, decided_by, opts \\ %{}) do
    Repo.transact_top_level(fn ->
      Merge.approve_in_tx(suggestion_id, decided_by, opts[:attrs] || %{})
    end)
  end

  def reject_merge(suggestion_id, decided_by),
    do: Repo.transact_top_level(fn -> Merge.reject_in_tx(suggestion_id, decided_by) end)

  def decide_contradiction(contradiction_id, status, opts \\ %{}) do
    status =
      case status do
        "resolved" -> :resolved
        "dismissed" -> :dismissed
        atom when atom in [:resolved, :dismissed] -> atom
      end

    Repo.transact_top_level(fn ->
      Dreaming.decide_contradiction_in_tx(contradiction_id, status, opts[:resolution_note])
    end)
  end
end
