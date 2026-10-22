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
  use Ankole.Ash.Domain

  resources do
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
