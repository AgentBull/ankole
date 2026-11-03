defmodule Ankole.Brain.Schemas.Page do
  require Ash.Query
  @moduledoc "Read-only knowledge projection of the Page tree and content."
  use Ankole.Ash.Resource,
    tenancy: :tenant,
    domain: Ankole.Brain,
    authorizers: [Ankole.AuthZ.Authorizer],
    extensions: [Ankole.AuthZ.Extension, AshJsonApi.Resource]

  authz do
    scope(:site_console)
    allow(:console_list, resource: "site_console:brain", action: "read")
  end

  json_api do
    type("brain_object")
    derive_filter?(false)
    derive_sort?(false)
    default_fields([:slug, :title, :type, :subtype, :updated_at, :deleted_at, :pod_url])
  end

  postgres do
    table("brain_page_nodes")
    repo(Ankole.Repo)
    migrate?(false)
  end

  attributes do
    attribute(:id, Ankole.Ash.Types.UUIDv7, primary_key?: true, allow_nil?: false)
    attribute(:slug, :string, public?: true)
    attribute(:type, :string, public?: true)
    attribute(:subtype, :string, public?: true)
    attribute(:title, :string, public?: true)
    attribute(:body, :string)
    attribute(:xml, :string)
    attribute(:meta, Ankole.Ash.Types.JSONMap, default: %{})
    attribute(:upstream_state, Ankole.Ash.Types.JSONMap, default: %{})
    attribute(:revision, :integer)
    attribute(:parent_id, Ankole.Ash.Types.UUIDv7)
    attribute(:acl_anchor_id, Ankole.Ash.Types.UUIDv7)
    attribute(:is_acl_anchor, :boolean)
    attribute(:kind, :atom)
    attribute(:effective_date, :date)
    attribute(:content_hash, :string)
    attribute(:managed_by_source_id, Ankole.Ash.Types.UUIDv7)
    attribute(:deleted_at, :utc_datetime_usec, public?: true)
    attribute(:created_at, :utc_datetime_usec)
    attribute(:updated_at, :utc_datetime_usec, public?: true)
  end

  calculations do
    calculate(:pod_url, :string, __MODULE__.PodURL, public?: true)
  end

  defmodule PodURL do
    @moduledoc false
    use Ash.Resource.Calculation

    @impl true
    def load(_query, _opts, _context), do: [:title]

    @impl true
    def calculate(records, _opts, _context) do
      Enum.map(
        records,
        &AnkoleWeb.PodURL.current_tenant_url(AnkoleWeb.PodURL.page_path(&1.id, &1.title))
      )
    end
  end

  actions do
    defaults([:read])

    read :console_list do
      pagination(keyset?: true, default_limit: 100, max_page_size: 100, countable: false)
      argument(:prefix, :string)
      argument(:search, :string)
      argument(:deleted, :boolean, default: false)

      prepare(fn query, _ ->
        query =
          Ash.Query.filter(
            query,
            is_nil(deleted_at) == not (^Ash.Query.get_argument(query, :deleted))
          )

        query =
          if prefix = Ash.Query.get_argument(query, :prefix),
            do: Ash.Query.filter(query, string_starts_with(slug, ^prefix)),
            else: query

        query =
          case Ash.Query.get_argument(query, :search) do
            term when is_binary(term) and term != "" ->
              pattern = "%" <> Ankole.Repo.escape_like(term) <> "%"

              Ash.Query.filter(
                query,
                fragment("? ILIKE ?", title, ^pattern) or fragment("? ILIKE ?", slug, ^pattern)
              )

            _ ->
              query
          end

        Ash.Query.sort(query, title: :asc, id: :asc)
      end)
    end
  end

  @type t :: %__MODULE__{}
end
