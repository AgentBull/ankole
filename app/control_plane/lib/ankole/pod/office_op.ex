defmodule Ankole.Pod.OfficeOp do
  @moduledoc """
  One committed Office operation or file reset, keyed by the resulting page revision.

  Rows that are not `compacted` hold edits that the page's current Office file
  does not contain yet. A `reset` row marks a file replaced from outside the
  operation log and is compacted from the start. `op` is the operation as the
  kernel committed it; `request_sha256` is the digest of the operation as the
  client sent it, which a retry with the same client sequence must match.
  """
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Pod,
    tenant_in_primary_key: true

  postgres do
    table("pod_office_ops")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:page_id, "pod_office_ops_tenant_id_page_id_fkey"}])

    unique_index_names([
      {[:revision], "pod_office_ops_pkey"},
      {[:client_seq], "pod_office_ops_client_seq_key"}
    ])

    check_constraints do
      check_constraint(:kind, "pod_office_ops_kind_check")
      check_constraint(:op, "pod_office_ops_entry_shape")
    end
  end

  attributes do
    attribute(:page_id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false)
    attribute(:revision, :integer, primary_key?: true, allow_nil?: false, constraints: [min: 1])
    attribute(:kind, :atom, allow_nil?: false, constraints: [one_of: [:op, :reset]])
    attribute(:compacted, :boolean, allow_nil?: false, default: false)
    attribute(:client_id, :string, constraints: [trim?: false])
    attribute(:client_seq, :integer)
    attribute(:request_sha256, :binary)
    attribute(:op, Ankole.Ash.Types.JSONMap)
    attribute(:author, Ankole.Ash.Types.ActorRef, allow_nil?: false)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
  end

  calculations do
    # The JSON size of one stored entry. It includes more fields than the
    # Channel DTO, so a replay that fits by this measure fits the message budget.
    calculate(
      :wire_bytes,
      :integer,
      expr(
        fragment(
          "octet_length(json_build_object('revision', ?, 'kind', ?, 'client_id', ?, 'client_seq', ?, 'op', ?, 'author', ?, 'created_at', ?)::text)",
          revision,
          kind,
          client_id,
          client_seq,
          op,
          author,
          created_at
        )
      )
    )
  end

  actions do
    defaults([:read])

    create :append do
      accept([
        :page_id,
        :revision,
        :kind,
        :compacted,
        :client_id,
        :client_seq,
        :request_sha256,
        :op,
        :author,
        :created_at
      ])

      for field <- [:client_id, :client_seq, :request_sha256, :op] do
        validate(attribute_does_not_equal(field, nil),
          where: [attribute_equals(:kind, :op)],
          message: "is required"
        )

        validate(attribute_equals(field, nil),
          where: [attribute_equals(:kind, :reset)],
          message: "is not part of a reset entry"
        )
      end
    end

    update :compact do
      require_atomic?(true)
      accept([])
      change(set_attribute(:compacted, true))
    end

    destroy :prune do
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
