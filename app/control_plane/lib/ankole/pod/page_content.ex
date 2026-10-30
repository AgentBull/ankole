defmodule Ankole.Pod.PageContent do
  @moduledoc "Canonical page XML and the plain text derived by the kernel."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Pod, extensions: [AshJsonApi.Resource]

  json_api do
    type("pod_page_content")
    derive_filter?(false)
    derive_sort?(false)
  end

  postgres do
    table("page_contents")
    repo(Ankole.Repo)
    migrate?(false)
    foreign_key_names([{:page_id, "page_contents_tenant_id_page_id_fkey"}])
    unique_index_names([{[:page_id], "page_contents_pkey"}])
  end

  attributes do
    attribute(:page_id, Ankole.Ash.Types.UUIDv7,
      public?: true,
      primary_key?: true,
      allow_nil?: false
    )

    attribute(:content, :string, public?: true, allow_nil?: false, constraints: [trim?: false])

    attribute(:plain_text, :string,
      public?: true,
      allow_nil?: false,
      default: "",
      constraints: [trim?: false, allow_empty?: true]
    )

    attribute(:updated_by, Ankole.Ash.Types.ActorRef, allow_nil?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:contributors, {:array, Ankole.Ash.Types.ActorRef}, allow_nil?: false, default: [])
  end

  actions do
    defaults([:read])

    create :create_in_tx do
      accept([:page_id, :content, :plain_text, :updated_by, :updated_at])
      change(&record_contributor/2)
    end

    update :replace do
      accept([:content, :plain_text, :updated_by, :updated_at])
      change(&record_contributor/2)
    end

    update :attribute_edit do
      accept([:updated_by, :updated_at])
      change(&record_contributor/2)
    end

    destroy :purge do
      require_atomic?(true)
    end
  end

  defp record_contributor(changeset, _context) do
    author = Ash.Changeset.get_attribute(changeset, :updated_by)
    contributors = Ash.Changeset.get_attribute(changeset, :contributors) || []

    Ash.Changeset.force_change_attribute(
      changeset,
      :contributors,
      Enum.uniq(contributors ++ [author])
    )
  end

  @type t :: %__MODULE__{}
end
