defmodule Ankole.Brain do
  @moduledoc """
  The Brain domain: the code interface of the knowledge space.

  Each read define gives one resource in the tenant of the calling process.
  Each operation define runs a generic action that owns its transaction: the
  action locks its rows, runs the write steps, and commits them together. A
  caller outside the Brain directory uses only these defines. Brain modules
  run the same actions with `Ankole.Ash.run_action/4`, and an action of
  another domain composes the `_in_tx` functions of the Brain modules.
  """
  use Ankole.Ash.Domain, extensions: [AshJsonApi.Domain]

  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.Schemas.Contradiction
  alias Ankole.Brain.Schemas.MergeSuggestion
  alias Ankole.Brain.Schemas.Object
  alias Ankole.Brain.Schemas.ObjectVersion
  alias Ankole.Brain.Schemas.SchemaSuggestion
  alias Ankole.Brain.Schemas.Source

  # The Console API (`AnkoleWeb.JSONAPI.ConsoleRouter`). An Object slug can
  # contain `/`, so an Object operation takes the slug in the query or in the
  # body, not in the path.
  json_api do
    authorize?(false)
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

    resource Ankole.Brain.Schemas.Object do
      define(:get_object, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_objects, action: :read)
      define(:create_object, args: [:attrs, :writer])
      define(:update_object, args: [:slug, :attrs, :writer])
      define(:upsert_source_projection, args: [:source, :attrs])
      define(:upsert_library_projection, args: [:source, :page])
      define(:soft_delete_object, args: [:slug])
      define(:rollback_object, args: [:slug, :version_id, :writer])
      define(:fork_library_page, args: [:slug])
      define(:restore_object, args: [:slug])
      define(:reconcile_chunks, args: [:object])
      define(:reconcile_object_links, args: [:slug])
    end

    resource Ankole.Brain.Schemas.Chunk do
      define(:get_chunk, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_chunks, action: :read)
    end

    resource Ankole.Brain.Schemas.ObjectVersion do
      define(:get_object_version, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_object_versions, action: :read)
    end

    resource Ankole.Brain.Schemas.Claim do
      define(:get_claim, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_claims, action: :read)
      define(:write_fact, args: [:attrs, :writer])
      define(:supersede_claim, args: [:claim_id, :attrs, :writer])
      define(:expire_fact, action: :expire_fact_by_id, args: [:claim_id])
      define(:deactivate_take, action: :deactivate_take_by_id, args: [:claim_id])

      define(:resolve_take,
        action: :resolve_take_by_id,
        args: [:claim_id, :resolution, :resolved_by]
      )

      define(:attach_claim_embedding, args: [:claim, :embedding, :signature])
    end

    resource Ankole.Brain.Schemas.Source do
      define(:get_source, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_sources, action: :read)
      define(:archive_source, args: [:source_id])

      define(:update_source_default_scope,
        action: :update_default_scope,
        args: [:source_id, :scope]
      )
    end

    resource Ankole.Brain.Schemas.Timeline do
      define(:get_timeline, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_timelines, action: :read)
    end

    resource Ankole.Brain.Schemas.Link do
      define(:get_link, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_links, action: :read)
    end

    resource Ankole.Brain.Schemas.Tag do
      define(:get_tag, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_tags, action: :read)
    end

    resource Ankole.Brain.Schemas.ObjectAlias do
      define(:get_object_alias, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_object_aliases, action: :read)
    end

    resource Ankole.Brain.Schemas.SlugAlias do
      define(:get_slug_alias, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_slug_aliases, action: :read)
    end

    resource Ankole.Brain.Schemas.SchemaSuggestion do
      define(:get_schema_suggestion, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_schema_suggestions, action: :read)
      define(:approve_promotion, args: [:suggestion_id, :decided_by])
      define(:reject_promotion, args: [:suggestion_id, :decided_by])
    end

    resource Ankole.Brain.Schemas.MergeSuggestion do
      define(:get_merge_suggestion, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_merge_suggestions, action: :read)
      define(:approve_merge, args: [:suggestion_id, :decided_by])
      define(:reject_merge, args: [:suggestion_id, :decided_by])
    end

    resource Ankole.Brain.Schemas.Contradiction do
      define(:get_contradiction, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_contradictions, action: :read)
      define(:decide_contradiction, action: :decide, args: [:contradiction_id, :status])
    end

    resource Ankole.Brain.Schemas.SchemaPack do
      define(:get_schema_pack, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_schema_packs, action: :read)
    end

    resource Ankole.Brain.Schemas.SchemaType do
      define(:get_schema_type, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_schema_types, action: :read)
    end

    resource Ankole.Brain.Schemas.SchemaLinkType do
      define(:get_schema_link_type, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_schema_link_types, action: :read)
    end

    resource Ankole.Brain.Schemas.SchemaCalibrationDomain do
      define(:get_schema_calibration_domain,
        action: :read,
        get_by: [:id],
        not_found_error?: false
      )

      define(:list_schema_calibration_domains, action: :read)
    end

    resource Ankole.Brain.Schemas.TakeDomainAssignment do
      define(:get_take_domain_assignment, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_take_domain_assignments, action: :read)
    end
  end
end
