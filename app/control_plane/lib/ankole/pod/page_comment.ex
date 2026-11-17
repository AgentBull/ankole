defmodule Ankole.Pod.PageComment do
  @moduledoc "A document comment or one-level reply, including its retained deletion and resolution facts."
  use Ankole.Ash.Resource, tenancy: :tenant, domain: Ankole.Pod

  @principal_md_mention_regex ~r/@\[[^\]]*\]\(principal:([^)\s]+)\)/

  postgres do
    table("page_comments")
    repo(Ankole.Repo)
    migrate?(false)

    foreign_key_names([
      {:page_id, "page_comments_page_fkey"},
      {:root_id, "page_comments_root_fkey"}
    ])

    unique_index_names([{[:id], "page_comments_pkey"}])

    check_constraints do
      check_constraint(:body, "page_comments_body_shape")
      check_constraint(:version, "page_comments_version")
      check_constraint(:root_id, "page_comments_root_shape")
      check_constraint(:resolved_at, "page_comments_resolution_shape")
      check_constraint(:anchor_revision, "page_comments_anchor_shape")
    end
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7,
      primary_key?: true,
      allow_nil?: false,
      default: &Ankole.Ecto.UUIDv7.autogenerate/0
    )

    attribute(:page_id, Ankole.Ash.Types.UUIDv7, allow_nil?: false)
    attribute(:root_id, Ankole.Ash.Types.UUIDv7)
    attribute(:body, :string, constraints: [trim?: false, allow_empty?: true, max_length: 20_000])
    attribute(:mentioned_uids, {:array, :string}, allow_nil?: false, default: [])
    attribute(:author, Ankole.Ash.Types.ActorRef, allow_nil?: false)
    attribute(:updated_by, Ankole.Ash.Types.ActorRef, allow_nil?: false)
    attribute(:deleted_by, Ankole.Ash.Types.ActorRef)
    attribute(:version, :integer, allow_nil?: false, default: 1, constraints: [min: 1])
    attribute(:quote, :string, constraints: [trim?: false, allow_empty?: true])
    attribute(:anchor, Ankole.Ash.Types.JSONMap)
    attribute(:anchor_revision, :integer, constraints: [min: 0])
    attribute(:resolved_at, :utc_datetime_usec)
    attribute(:resolved_by, Ankole.Ash.Types.ActorRef)
    attribute(:deleted_at, :utc_datetime_usec)
    attribute(:created_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:updated_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:activity_at, :utc_datetime_usec, allow_nil?: false)
    attribute(:activity_by, Ankole.Ash.Types.ActorRef, allow_nil?: false)
  end

  relationships do
    has_many :replies, __MODULE__ do
      destination_attribute(:root_id)
    end
  end

  actions do
    defaults([:read])

    read :list do
      pagination(keyset?: true, max_page_size: 100, countable: false, required?: false)
    end

    create :create_in_tx do
      accept([
        :id,
        :page_id,
        :root_id,
        :body,
        :author,
        :updated_by,
        :activity_at,
        :activity_by,
        :quote,
        :anchor,
        :anchor_revision,
        :created_at,
        :updated_at
      ])

      change(&sync_create_mentions/2)
    end

    update :activity_in_tx do
      require_atomic?(true)
      accept([:activity_at, :activity_by])
    end

    update :change_in_tx do
      require_atomic?(false)

      accept([
        :body,
        :quote,
        :anchor,
        :anchor_revision,
        :resolved_at,
        :resolved_by,
        :deleted_at,
        :deleted_by,
        :updated_at,
        :updated_by
      ])

      change(&prepare_change/2)
    end

    destroy :purge do
      require_atomic?(true)
    end
  end

  defp sync_create_mentions(changeset, _context) do
    body = Ash.Changeset.get_attribute(changeset, :body)
    Ash.Changeset.force_change_attribute(changeset, :mentioned_uids, mentioned_uids(body))
  end

  defp prepare_change(changeset, _context) do
    changeset =
      if Ash.Changeset.changing_attribute?(changeset, :body) do
        body = Ash.Changeset.get_attribute(changeset, :body)
        Ash.Changeset.force_change_attribute(changeset, :mentioned_uids, mentioned_uids(body))
      else
        changeset
      end

    Ash.Changeset.force_change_attribute(changeset, :version, changeset.data.version + 1)
  end

  defp mentioned_uids(body) when is_binary(body) and body != "" do
    prose = prose_without_code(body)
    xml_uids = Ankole.Pod.Pages.Mentions.principal_uids(prose)

    md_uids =
      @principal_md_mention_regex
      |> Regex.scan(prose, capture: :all_but_first)
      |> List.flatten()

    (xml_uids ++ md_uids)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp mentioned_uids(_body), do: []

  defp prose_without_code(body) do
    case Ankole.Kernel.markdown_code_ranges(body) do
      [] ->
        body

      ranges ->
        {chunks, offset} =
          Enum.reduce(ranges, {[], 0}, fn {start, length}, {acc, pos} ->
            {["\n", binary_part(body, pos, start - pos) | acc], start + length}
          end)

        [Enum.reverse(chunks), binary_part(body, offset, byte_size(body) - offset)]
        |> IO.iodata_to_binary()
    end
  end

  @type t :: %__MODULE__{}
end
