defmodule Ankole.Brain.Domain do
  @moduledoc false
  use Ankole.Ash.Domain

  resources do
    resource Ankole.Brain.Schemas.Object do
      define(:get_object, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_objects, action: :read)
      define(:create_object, action: :create)
      define(:create_projection_object, action: :create_projection)
      define(:ensure_canonical_object, action: :ensure_canonical)
      define(:edit_object, action: :edit)
      define(:project_object, action: :project)
      define(:forget_object, action: :forget)
      define(:restore_object, action: :restore)
      define(:withdraw_projection_object, action: :withdraw_projection)
      define(:fork_object, action: :fork)
      define(:retype_object, action: :retype)
      define(:refresh_hash_object, action: :refresh_hash)
      define(:stamp_chunking_object, action: :stamp_chunking)
      define(:stamp_links_object, action: :stamp_links)
      define(:stamp_timelines_object, action: :stamp_timelines)
      define(:touch_retrieved_object, action: :touch_retrieved)
      define(:purge_object, action: :purge)
      define(:merge_duplicate_object, action: :merge_duplicate)
    end

    resource Ankole.Brain.Schemas.Chunk do
      define(:get_chunk, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_chunks, action: :read)
      define(:project_chunk, action: :project)
      define(:replace_projection_chunk, action: :replace_projection)
      define(:record_embedding_chunk, action: :record_embedding)
      define(:remove_projection_chunk, action: :remove_projection)
    end

    resource Ankole.Brain.Schemas.ObjectVersion do
      define(:get_object_version, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_object_versions, action: :read)
      define(:snapshot_object_version, action: :snapshot)
    end

    resource Ankole.Brain.Schemas.Claim do
      define(:get_claim, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_claims, action: :read)
      define(:record_fact_claim, action: :record_fact)
      define(:record_take_claim, action: :record_take)
      define(:expire_fact_claim, action: :expire_fact)
      define(:deactivate_take_claim, action: :deactivate_take)
      define(:resolve_take_claim, action: :resolve_take)
      define(:supersede_claim, action: :supersede)
      define(:deduplicate_claim, action: :deduplicate)
      define(:record_grade_claim, action: :record_grade)
      define(:consolidate_claim, action: :consolidate)
      define(:record_embedding_claim, action: :record_embedding)
      define(:append_forgetting_reason_claim, action: :append_forgetting_reason)
      define(:reparent_claim, action: :reparent)
      define(:reassign_holder_claim, action: :reassign_holder)
    end

    resource Ankole.Brain.Schemas.Source do
      define(:get_source, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_sources, action: :read)
      define(:register_source, action: :register)
      define(:ensure_source, action: :ensure)
      define(:archive_source, action: :archive)
      define(:set_default_scope_source, action: :set_default_scope)
      define(:record_revision_source, action: :record_revision)
      define(:record_sync_source, action: :record_sync)
      define(:record_watermark_source, action: :record_watermark)
      define(:invalidate_extraction_source, action: :invalidate_extraction)
    end

    resource Ankole.Brain.Schemas.Timeline do
      define(:get_timeline, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_timelines, action: :read)
      define(:record_timeline, action: :record)
    end

    resource Ankole.Brain.Schemas.Link do
      define(:get_link, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_links, action: :read)
      define(:add_link, action: :add)
      define(:remove_link, action: :remove)
    end

    resource Ankole.Brain.Schemas.Tag do
      define(:get_tag, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_tags, action: :read)
      define(:add_tag, action: :add)
      define(:remove_tag, action: :remove)
    end

    resource Ankole.Brain.Schemas.ObjectAlias do
      define(:get_object_alias, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_object_aliases, action: :read)
      define(:add_object_alias, action: :add)
      define(:remove_object_alias, action: :remove)
    end

    resource Ankole.Brain.Schemas.SlugAlias do
      define(:get_slug_alias, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_slug_aliases, action: :read)
      define(:add_slug_alias, action: :add)
      define(:repoint_slug_alias, action: :repoint)
    end

    resource Ankole.Brain.Schemas.SchemaSuggestion do
      define(:get_schema_suggestion, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_schema_suggestions, action: :read)
      define(:suggest_schema_suggestion, action: :suggest)
    end

    resource Ankole.Brain.Schemas.MergeSuggestion do
      define(:get_merge_suggestion, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_merge_suggestions, action: :read)
      define(:suggest_merge_suggestion, action: :suggest)
    end

    resource Ankole.Brain.Schemas.Contradiction do
      define(:get_contradiction, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_contradictions, action: :read)
      define(:record_verdict_contradiction, action: :record_verdict)
    end

    resource Ankole.Brain.Schemas.SchemaPack do
      define(:get_schema_pack, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_schema_packs, action: :read)
      define(:install_schema_pack, action: :install)
      define(:ensure_promoted_schema_pack, action: :ensure_promoted)
    end

    resource Ankole.Brain.Schemas.SchemaType do
      define(:get_schema_type, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_schema_types, action: :read)
      define(:register_schema_type, action: :register)
      define(:add_subtypes_schema_type, action: :add_subtypes)
    end

    resource Ankole.Brain.Schemas.SchemaLinkType do
      define(:get_schema_link_type, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_schema_link_types, action: :read)
      define(:register_schema_link_type, action: :register)
    end

    resource Ankole.Brain.Schemas.SchemaCalibrationDomain do
      define(:get_schema_calibration_domain,
        action: :read,
        get_by: [:id],
        not_found_error?: false
      )

      define(:list_schema_calibration_domains, action: :read)
      define(:register_schema_calibration_domain, action: :register)
    end

    resource Ankole.Brain.Schemas.TakeDomainAssignment do
      define(:get_take_domain_assignment, action: :read, get_by: [:id], not_found_error?: false)
      define(:list_take_domain_assignments, action: :read)
      define(:assign_once_take_domain_assignment, action: :assign_once)
    end
  end
end
