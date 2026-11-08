defmodule Ankole.Pod.AppletEnv do
  @moduledoc "One Applet-scoped environment variable override bound to its Pod page."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    tenant_in_primary_key: true,
    domain: Ankole.Pod

  postgres do
    table("pod_applet_envs")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:page_id, "pod_applet_envs_page_fkey"}])
    unique_index_names([{[:page_id, :name], "pod_applet_envs_pkey"}])

    check_constraints do
      check_constraint(:name, "pod_applet_envs_name_check")
    end
  end

  attributes do
    attribute(:page_id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      public?: true
    )

    attribute(:name, :string,
      primary_key?: true,
      allow_nil?: false,
      public?: true,
      constraints: [trim?: false, match: ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/]
    )

    attribute(:secret, :boolean, allow_nil?: false, public?: true)

    attribute(:value, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [trim?: false, match: ~r/\S/]
    )

    attribute(:description, :string, public?: true, constraints: [trim?: false])
    create_timestamp(:inserted_at, type: Ankole.Ash.Types.Timestamptz)
    update_timestamp(:updated_at, type: Ankole.Ash.Types.Timestamptz)
  end

  actions do
    defaults([:read])

    create :put_in_tx do
      transaction?(false)
      accept([:page_id, :name, :secret, :value, :description])
      upsert?(true)
      upsert_fields([:secret, :value, :description, :updated_at])
    end

    destroy :remove do
      transaction?(false)
      require_atomic?(true)
    end

    destroy :purge do
      require_atomic?(true)
    end
  end

  @type t :: %__MODULE__{}
end
