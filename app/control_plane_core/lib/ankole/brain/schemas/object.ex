defmodule Ankole.Brain.Schemas.Object do
  @moduledoc "A current knowledge page with explicit content, ownership, and projection writes."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Brain,
    extensions: [AshJsonApi.Resource]

  # The Console API gives the summary fields. The page read model with the
  # body, the Claims, and the links stays at the v1 route
  # `GET /api/v1/brain/objects/show`.
  json_api do
    type("brain_object")
    derive_filter?(false)
    derive_sort?(false)

    default_fields([
      :slug,
      :type,
      :subtype,
      :title,
      :effective_date,
      :managed_by_source_id,
      :deleted_at,
      :updated_at
    ])
  end

  postgres do
    table("brain_objects")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(slug: "brain_objects_slug_key")
    foreign_key_names([{:managed_by_source_id, "brain_objects_managed_by_source_id_fkey"}])

    check_constraints do
      check_constraint(:slug, "brain_objects_slug_present")
      check_constraint(:type, "brain_objects_type_present")
      check_constraint(:title, "brain_objects_title_present")
      check_constraint(:meta, "brain_objects_meta_object")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:slug, :string, allow_nil?: false, public?: true, constraints: [trim?: false])
    attribute(:type, :string, allow_nil?: false, public?: true, constraints: [trim?: false])
    attribute(:subtype, :string, public?: true, constraints: [trim?: false])
    attribute(:title, :string, allow_nil?: false, public?: true, constraints: [trim?: false])

    attribute(:body, :string,
      allow_nil?: false,
      default: "",
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:meta, Ankole.Ash.Types.JSONMap, allow_nil?: false, default: %{})
    attribute(:effective_date, :date, public?: true)
    attribute(:content_hash, :string, constraints: [trim?: false])
    attribute(:chunking_signature, :string, constraints: [trim?: false])
    attribute(:last_retrieved_at, :utc_datetime_usec)
    attribute(:links_extracted_at, :utc_datetime_usec)
    attribute(:timelines_extracted_at, :utc_datetime_usec)
    attribute(:deleted_at, :utc_datetime_usec, public?: true)
    attribute(:managed_by_source_id, Ankole.Ash.Types.UUIDv7, public?: true)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
    # Projection writes must not advance the logical content clock.
    attribute(:updated_at, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      default: &DateTime.utc_now/0
    )
  end

  identities do
    identity(:slug, [:slug])
  end

  @content [
    :title,
    :body,
    :meta,
    :subtype,
    :effective_date,
    :content_hash,
    :updated_at,
    :links_extracted_at,
    :timelines_extracted_at
  ]
  @initial [
    :id,
    :slug,
    :type,
    :title,
    :body,
    :meta,
    :subtype,
    :effective_date,
    :content_hash,
    :updated_at,
    :created_at
  ]

  actions do
    defaults([:read])

    # The Console list: a slug prefix, a title or slug search, and the live
    # or the soft-deleted objects.
    read :console_list do
      argument(:prefix, :string, constraints: [trim?: false])
      argument(:search, :string)
      argument(:deleted, :boolean, default: false)
      prepare(&Ankole.Brain.Objects.console_list/2)
    end

    create :create do
      accept(@initial)
    end

    create :create_projection do
      accept([:managed_by_source_id | @initial])
      require_attributes([:managed_by_source_id])
    end

    create_if_absent :ensure_canonical do
      accept(@initial)
      upsert_identity(:slug)
    end

    update :edit do
      require_atomic?(true)
      accept(@content)
      argument(:expected_content_hash, :string, allow_nil?: false, constraints: [trim?: false])

      change(
        filter(
          expr(
            is_nil(managed_by_source_id) and is_nil(deleted_at) and
              content_hash == ^arg(:expected_content_hash)
          )
        )
      )
    end

    update :project do
      require_atomic?(true)
      accept([:type, :deleted_at | @content])
      argument(:source_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      change(filter(expr(managed_by_source_id == ^arg(:source_id))))
    end

    update :forget do
      require_atomic?(true)
      accept([:meta, :content_hash])
      change(filter(expr(is_nil(managed_by_source_id))))
      change(set_attribute(:deleted_at, &DateTime.utc_now/0))
    end

    update :restore do
      require_atomic?(true)
      accept([:meta, :content_hash])
      change(filter(expr(is_nil(managed_by_source_id))))
      change(set_attribute(:deleted_at, nil))
    end

    update :withdraw_projection do
      require_atomic?(true)
      accept([])
      argument(:source_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
      change(filter(expr(managed_by_source_id == ^arg(:source_id) and is_nil(deleted_at))))
      change(set_attribute(:deleted_at, &DateTime.utc_now/0))
    end

    update :fork do
      require_atomic?(true)
      accept([])
      change(filter(expr(not is_nil(managed_by_source_id) and type != "agent-skills")))
      change(set_attribute(:managed_by_source_id, nil))
    end

    update :retype do
      require_atomic?(true)
      accept([:slug, :type])
      change(filter(expr(is_nil(managed_by_source_id) and is_nil(deleted_at))))
      change(set_attribute(:updated_at, &DateTime.utc_now/0))
    end

    update :refresh_hash do
      require_atomic?(true)
      accept([:content_hash])
    end

    update :stamp_chunking do
      require_atomic?(true)
      accept([:chunking_signature])
    end

    update :stamp_links do
      require_atomic?(true)
      accept([])
      change(atomic_update(:links_extracted_at, expr(updated_at)))
    end

    update :stamp_timelines do
      require_atomic?(true)
      accept([])
      argument(:content_updated_at, :utc_datetime_usec, allow_nil?: false)
      change(filter(expr(updated_at == ^arg(:content_updated_at))))
      change(atomic_update(:timelines_extracted_at, expr(updated_at)))
    end

    update :touch_retrieved do
      require_atomic?(true)
      accept([])
      change(set_attribute(:last_retrieved_at, &DateTime.utc_now/0))
    end

    destroy :purge do
      require_atomic?(true)
      change(filter(expr(not is_nil(deleted_at) and is_nil(managed_by_source_id))))
    end

    destroy :merge_duplicate do
      require_atomic?(true)
      change(filter(expr(is_nil(managed_by_source_id))))
    end

    # Each operation owns its transaction. The Objects, Chunks, and Links
    # modules give the steps.
    action :create_object, :struct do
      constraints(instance_of: __MODULE__)
      argument(:attrs, :map, allow_nil?: false)
      argument(:writer, :term, allow_nil?: false)

      run(fn %{arguments: args}, _context ->
        Ankole.Errors.wrap(Ankole.Brain.Objects.create_object_in_tx(args.attrs, args.writer))
      end)
    end

    action :update_object, :struct do
      constraints(instance_of: __MODULE__)
      argument(:slug, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
      argument(:attrs, :map, allow_nil?: false)
      argument(:writer, :term, allow_nil?: false)
      argument(:author, Ankole.Ash.Types.ActorRef)

      run(fn %{arguments: args}, _context ->
        args.slug
        |> Ankole.Brain.Objects.update_object_in_tx(args.attrs, args.writer,
          author: args[:author]
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :upsert_source_projection, :struct do
      constraints(instance_of: __MODULE__)

      argument(:source, :struct,
        allow_nil?: false,
        constraints: [instance_of: Ankole.Brain.Schemas.Source]
      )

      argument(:attrs, :map, allow_nil?: false)

      run(fn %{arguments: args}, _context ->
        args.source
        |> Ankole.Brain.Objects.upsert_source_projection_in_tx(args.attrs)
        |> Ankole.Errors.wrap()
      end)
    end

    action :upsert_library_projection, :atom do
      argument(:source, :struct,
        allow_nil?: false,
        constraints: [instance_of: Ankole.Brain.Schemas.Source]
      )

      argument(:page, :map, allow_nil?: false)

      run(fn %{arguments: args}, _context ->
        args.source
        |> Ankole.Brain.Objects.upsert_library_projection_in_tx(args.page)
        |> Ankole.Errors.wrap()
      end)
    end

    action :soft_delete_object, :struct do
      constraints(instance_of: __MODULE__)
      argument(:slug, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
      argument(:reason, :string, constraints: [trim?: false, allow_empty?: true])
      argument(:by, :term)

      run(fn %{arguments: args}, _context ->
        args.slug
        |> Ankole.Brain.Objects.soft_delete_in_tx(reason: args[:reason], by: args[:by])
        |> Ankole.Errors.wrap()
      end)
    end

    action :rollback_object, :struct do
      constraints(instance_of: __MODULE__)
      argument(:slug, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
      argument(:version_id, :uuid, allow_nil?: false)
      argument(:writer, :term, allow_nil?: false)
      argument(:author, Ankole.Ash.Types.ActorRef)

      run(fn %{arguments: args}, _context ->
        args.slug
        |> Ankole.Brain.Objects.rollback_in_tx(args.version_id, args.writer,
          author: args[:author]
        )
        |> Ankole.Errors.wrap()
      end)
    end

    action :fork_library_page, :struct do
      constraints(instance_of: __MODULE__)
      argument(:slug, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])

      run(fn %{arguments: args}, _context ->
        Ankole.Brain.Console.result(Ankole.Brain.Objects.fork_library_page_in_tx(args.slug), __MODULE__)
      end)
    end

    action :restore_object, :struct do
      constraints(instance_of: __MODULE__)
      argument(:slug, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])

      run(fn %{arguments: args}, _context ->
        Ankole.Brain.Console.result(Ankole.Brain.Objects.restore_in_tx(args.slug), __MODULE__)
      end)
    end

    action :reconcile_chunks, :struct do
      constraints(instance_of: __MODULE__)
      argument(:object, :struct, allow_nil?: false, constraints: [instance_of: __MODULE__])
      argument(:chunking, :map)

      run(fn %{arguments: args}, _context ->
        args.object
        |> Ankole.Brain.Chunks.reconcile_in_tx(chunking: args[:chunking])
        |> Ankole.Errors.wrap()
      end)
    end

    action :reconcile_object_links, :struct do
      constraints(instance_of: __MODULE__)
      argument(:slug, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])

      run(fn %{arguments: args}, _context ->
        Ankole.Errors.wrap(Ankole.Brain.Links.reconcile_object_links_in_tx(args.slug))
      end)
    end

    # The Console operations. The operator is the actor of the action
    # (Ankole.Brain.Console).
    action :console_create, :struct do
      constraints(instance_of: __MODULE__)
      argument(:slug, :string, allow_nil?: false)
      argument(:type, :string, allow_nil?: false)
      argument(:subtype, :string)
      argument(:title, :string, allow_nil?: false)
      argument(:body, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
      argument(:meta, Ankole.Ash.Types.JSONMap, allow_nil?: false)
      argument(:effective_date, :date)
      argument(:tags, {:array, :string}, default: [])

      run(fn %{arguments: args}, context ->
        args
        |> Map.take([:slug, :type, :subtype, :title, :body, :meta, :effective_date, :tags])
        |> Ankole.Brain.Objects.create_object_in_tx(Ankole.Brain.Console.writer(context))
        |> Ankole.Brain.Console.result(__MODULE__)
      end)
    end

    # The content hash is a compare-and-swap token: the edit fails when the
    # object changed after the editor read it. Without tags, the tags stay.
    action :console_update, :struct do
      constraints(instance_of: __MODULE__)
      argument(:slug, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:expected_content_hash, :string, allow_nil?: false)
      argument(:subtype, :string)
      argument(:title, :string, allow_nil?: false)
      argument(:body, :string, allow_nil?: false, constraints: [trim?: false, allow_empty?: true])
      argument(:meta, Ankole.Ash.Types.JSONMap, allow_nil?: false)
      argument(:effective_date, :date)
      argument(:tags, {:array, :string})

      run(fn %{arguments: args}, context ->
        attrs =
          Map.take(args, [:expected_content_hash, :subtype, :title, :body, :meta, :effective_date])

        attrs = if args[:tags], do: Map.put(attrs, :tags, args.tags), else: attrs

        args.slug
        |> Ankole.Brain.Objects.update_object_in_tx(
          attrs,
          Ankole.Brain.Console.writer(context),
          author: Ankole.Brain.Console.actor_ref(context)
        )
        |> Ankole.Brain.Console.result(__MODULE__)
      end)
    end

    action :console_rollback, :struct do
      constraints(instance_of: __MODULE__)
      argument(:slug, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:version_id, :uuid, allow_nil?: false)

      run(fn %{arguments: args}, context ->
        args.slug
        |> Ankole.Brain.Objects.rollback_in_tx(
          args.version_id,
          Ankole.Brain.Console.writer(context),
          author: Ankole.Brain.Console.actor_ref(context)
        )
        |> Ankole.Brain.Console.result(__MODULE__)
      end)
    end

    action :console_forget, :struct do
      constraints(instance_of: __MODULE__)
      argument(:slug, :string, allow_nil?: false, constraints: [trim?: false])
      argument(:reason, :string, constraints: [trim?: false, allow_empty?: true])

      run(fn %{arguments: args}, _context ->
        args.slug
        |> Ankole.Brain.Forget.forget_object_in_tx(args[:reason] || "", :admin)
        |> Ankole.Brain.Console.result(__MODULE__)
      end)
    end

    # The pattern pages of one audience and their evidence links commit
    # together; Ankole.Brain.Patterns gives the steps.
    action :write_patterns, :integer do
      argument(:patterns, {:array, :map}, allow_nil?: false)
      argument(:existing, :map, allow_nil?: false)

      run(fn %{arguments: args}, _context ->
        args.patterns
        |> Ankole.Brain.Patterns.write_patterns_in_tx(args.existing)
        |> Ankole.Errors.wrap()
      end)
    end
  end

  relationships do
    has_many :tags, Ankole.Brain.Schemas.Tag do
      source_attribute(:slug)
      destination_attribute(:object_slug)
    end
  end

  @doc false
  def verify_content_hash(_object, nil), do: {:error, :missing_expected_content_hash}

  def verify_content_hash(%__MODULE__{content_hash: current}, expected),
    do: if(current == expected, do: :ok, else: {:error, :content_hash_conflict})

  @type t :: %__MODULE__{}
end
