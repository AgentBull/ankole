defmodule Ankole.Pod.PageChange do
  @moduledoc "An immutable document reset or editor batch, keyed by the resulting revision."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Pod.Domain,
    tenant_in_primary_key: true

  postgres do
    table("page_changes")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:page_id, "page_changes_tenant_id_page_id_fkey"}])

    unique_index_names([
      {[:revision], "page_changes_pkey"},
      {[:client_seq], "page_changes_tenant_id_page_id_client_id_client_seq_key"}
    ])

    check_constraints do
      check_constraint(:kind, "page_changes_kind_check")
      check_constraint(:changes, "page_changes_entry_shape")
    end
  end

  attributes do
    attribute(:page_id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false)
    attribute(:revision, :integer, primary_key?: true, allow_nil?: false, constraints: [min: 1])
    attribute(:kind, :atom, allow_nil?: false, constraints: [one_of: [:change, :reset]])
    attribute(:client_id, :string, constraints: [trim?: false])
    attribute(:client_seq, :integer)
    attribute(:changes, Ankole.Ash.Types.JSONList)
    attribute(:author, Ankole.Ash.Types.ActorRef, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
  end

  actions do
    defaults([:read])

    create :append do
      transaction?(false)
      change(Ankole.Ash.RequireTransaction)

      accept([
        :page_id,
        :revision,
        :kind,
        :client_id,
        :client_seq,
        :changes,
        :author,
        :created_at
      ])

      validate(Ankole.Pod.Validations.PageChangeShape)
    end

    destroy :prune do
      transaction?(false)
      require_atomic?(true)
      change(Ankole.Ash.RequireTransaction.Atomic)
    end
  end

  @type t :: %__MODULE__{}
end
