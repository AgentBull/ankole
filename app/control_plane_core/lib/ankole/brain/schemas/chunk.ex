defmodule Ankole.Brain.Schemas.Chunk do
  @moduledoc """
  One current retrieval position. A changed position invalidates its embedding;
  a model result can replace vector state only while its input still matches.
  """
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Brain

  postgres do
    table("brain_chunks")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(object_position: "brain_chunks_object_position_key")
    foreign_key_names([{:object_id, "brain_chunks_object_id_fkey"}])

    check_constraints do
      check_constraint(:chunk_index, "brain_chunks_index_nonnegative")
      check_constraint(:content_kind, "brain_chunks_content_kind_values")
      check_constraint(:token_count, "brain_chunks_token_count_nonnegative")
      check_constraint(:audience_scope, "brain_chunks_audience_scope_shape")
      check_constraint(:embedding, "brain_chunks_embedding_state")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:object_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:chunk_index, :integer, allow_nil?: false, constraints: [min: 0])

    attribute(:content_kind, Ankole.Ash.Types.State,
      allow_nil?: false,
      default: :body,
      constraints: [one_of: [:body, :timeline]]
    )

    attribute(:audience_scope, :string,
      allow_nil?: false,
      constraints: [trim?: false]
    )

    attribute(:chunk_text, :string,
      allow_nil?: false,
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:token_count, :integer, allow_nil?: false, constraints: [min: 0])
    attribute(:embedding, :vector)
    attribute(:embedding_signature, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:embedding_error, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:embedded_at, :utc_datetime_usec)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false, default: &DateTime.utc_now/0)
  end

  identities do
    identity(:object_position, [:object_id, :chunk_index])
  end

  actions do
    defaults([:read])

    create :project do
      accept([
        :object_id,
        :chunk_index,
        :content_kind,
        :audience_scope,
        :chunk_text,
        :token_count
      ])
    end

    update :replace_projection do
      require_atomic?(true)
      accept([:content_kind, :audience_scope, :chunk_text, :token_count])
      change(set_attribute(:embedding, nil))
      change(set_attribute(:embedding_signature, nil))
      change(set_attribute(:embedding_error, nil))
      change(set_attribute(:embedded_at, nil))
    end

    update :record_embedding do
      require_atomic?(true)
      accept([:embedding, :embedding_signature, :embedding_error, :embedded_at])

      argument(:input_text, :string,
        allow_nil?: false,
        constraints: [trim?: false, allow_empty?: true]
      )

      argument(:input_embedded_at, :utc_datetime_usec)
      argument(:input_signature, :string, constraints: [trim?: false, allow_empty?: true])

      change(
        filter(
          expr(
            chunk_text == ^arg(:input_text) and
              fragment("? IS NOT DISTINCT FROM ?", embedded_at, ^arg(:input_embedded_at)) and
              fragment("? IS NOT DISTINCT FROM ?", embedding_signature, ^arg(:input_signature))
          )
        )
      )
    end

    destroy :remove_projection do
      require_atomic?(true)
    end
  end

  relationships do
    belongs_to :object, Ankole.Brain.Schemas.Object do
      define_attribute?(false)
      attribute_type(Ankole.Ash.Types.UUIDv7)
    end
  end

  calculations do
    # Self-healing embeds never-tried rows before rows that failed before.
    calculate(:embedding_failed?, :boolean, expr(not is_nil(embedding_error)))
  end

  @type t :: %__MODULE__{}
end
