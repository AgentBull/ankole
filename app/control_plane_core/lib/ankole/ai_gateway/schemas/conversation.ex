defmodule Ankole.AIGateway.Schemas.Conversation do
  @moduledoc "Durable subject-local conversation identity; response rows own continuation and liveness."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.AIGateway.Domain

  postgres do
    table("ai_gateway_conversations")
    repo(Ankole.Repo)
    migrate?(false)
    identity_index_names(active_key: "ai_gateway_conversations_active_key_index")
    identity_wheres_to_sql(active_key: "ended_at IS NULL")
    foreign_key_names(subject_uid: "ai_gateway_conversations_subject_uid_fkey")

    check_constraints do
      check_constraint(:metadata, "ai_gateway_conversations_metadata_object")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:subject_uid, Ankole.Ash.Types.PrincipalKey, allow_nil?: false)
    attribute(:conversation_key, :string, allow_nil?: false, constraints: [trim?: false])
    attribute(:ended_at, :utc_datetime_usec)

    attribute(:metadata, Ankole.Ash.Types.JSONMap,
      allow_nil?: false,
      default: %{},
      constraints: [allow_datetime?: true]
    )

    create_timestamp(:inserted_at, type: :utc_datetime_usec)
    update_timestamp(:updated_at, type: :utc_datetime_usec)
  end

  identities do
    identity(:active_key, [:subject_uid, :conversation_key],
      all_tenants?: true,
      where: expr(is_nil(ended_at))
    )
  end

  validations do
    validate(
      fn changeset, _context ->
        case Ash.Changeset.get_attribute(changeset, :conversation_key) do
          value when is_binary(value) ->
            if String.trim(value) == "",
              do: {:error, field: :conversation_key, message: "is required"},
              else: :ok

          _missing ->
            :ok
        end
      end,
      on: [:create]
    )
  end

  actions do
    defaults([:read])

    create :open do
      transaction?(false)
      accept([:subject_uid, :conversation_key, :metadata])
    end

    create_if_absent :ensure, upsert_fields: [:metadata] do
      transaction?(false)
      accept([:subject_uid, :conversation_key, :metadata])
      upsert_identity(:active_key)
    end

    atomic_in_tx_update :touch do
      accept([])
      change(set_attribute(:updated_at, &DateTime.utc_now/0))
    end

    in_tx_update :finish do
      accept([:ended_at])
      validate(present(:ended_at))
      change(filter(expr(is_nil(ended_at))))
    end
  end

  @type t :: %__MODULE__{}
end
