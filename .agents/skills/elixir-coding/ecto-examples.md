# Ecto Worked Examples

Complete working examples for Ecto schemas, changesets, queries, migrations, Multi, and advanced patterns. Patterns sourced from Ecto source/test suite, official hexdocs, and production repositories (changelog.com, ExNVR).

## 1. Schema with All Common Patterns

```elixir
defmodule MyApp.Blog.Post do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "posts" do
    field :title, :string
    field :body, :text
    field :slug, :string
    field :views, :integer, default: 0
    field :published, :boolean, default: false
    field :published_at, :utc_datetime_usec
    field :metadata, :map, default: %{}
    field :tags, {:array, :string}, default: []
    field :status, Ecto.Enum, values: [:draft, :published, :archived]
    field :password, :string, redact: true, virtual: true
    field :password_hash, :string, redact: true

    belongs_to :author, MyApp.Accounts.User
    has_many :comments, MyApp.Blog.Comment, on_replace: :delete, preload_order: [asc: :inserted_at]
    has_one :featured_comment, MyApp.Blog.Comment, where: [featured: true]
    many_to_many :categories, MyApp.Blog.Category, join_through: "posts_categories", on_replace: :delete

    embeds_one :seo, SEO, on_replace: :update do
      field :meta_title, :string
      field :meta_description, :string
      field :canonical_url, :string
    end

    timestamps()
  end

  @required_fields [:title, :body, :author_id]
  @optional_fields [:slug, :published, :published_at, :metadata, :tags, :status]

  def changeset(post, attrs) do
    post
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:title, min: 3, max: 200)
    |> validate_length(:body, min: 10)
    |> maybe_generate_slug()
    |> unique_constraint(:slug)
    |> cast_embed(:seo, with: &seo_changeset/2)
    |> cast_assoc(:comments, with: &MyApp.Blog.Comment.changeset/2)
    |> foreign_key_constraint(:author_id)
  end

  def publish_changeset(post) do
    change(post, status: :published, published: true, published_at: DateTime.utc_now())
  end

  defp maybe_generate_slug(changeset) do
    case get_change(changeset, :slug) do
      nil ->
        case get_change(changeset, :title) do
          nil -> changeset
          title -> put_change(changeset, :slug, Slug.slugify(title))
        end
      _slug -> changeset
    end
  end

  defp seo_changeset(seo, attrs) do
    seo
    |> cast(attrs, [:meta_title, :meta_description, :canonical_url])
    |> validate_length(:meta_title, max: 60)
    |> validate_length(:meta_description, max: 160)
  end
end
```

## 2. App-Wide Schema Base Module

Pattern from changelog.com — shared configuration and helpers across all schemas:

```elixir
defmodule MyApp.Schema do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      use Ecto.Schema
      import Ecto.Changeset
      import Ecto.Query

      @primary_key {:id, :binary_id, autogenerate: true}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end

# Usage
defmodule MyApp.Accounts.User do
  use MyApp.Schema

  schema "users" do
    field :email, :string
    field :name, :string
    timestamps()
  end
end
```

## 3. Changeset Patterns

### Multi-Step Changesets (Different Actions)

```elixir
defmodule MyApp.Accounts.User do
  use MyApp.Schema

  schema "users" do
    field :email, :string
    field :name, :string
    field :password, :string, virtual: true, redact: true
    field :hashed_password, :string, redact: true
    field :confirmed_at, :utc_datetime_usec
    field :role, Ecto.Enum, values: [:user, :admin], default: :user
    timestamps()
  end

  # Registration — strict validation
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :password])
    |> validate_required([:email, :name, :password])
    |> validate_email()
    |> validate_password()
  end

  # Profile update — less strict
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 100)
  end

  # Email change — requires reconfirmation
  def email_changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_email()
    |> put_change(:confirmed_at, nil)
  end

  # Admin-only fields
  def admin_changeset(user, attrs) do
    user
    |> cast(attrs, [:role])
    |> validate_inclusion(:role, [:user, :admin])
  end

  defp validate_email(changeset) do
    changeset
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must have the @ sign and no spaces")
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, MyApp.Repo)
    |> unique_constraint(:email)
  end

  defp validate_password(changeset) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    |> prepare_changes(&hash_password/1)
  end

  defp hash_password(changeset) do
    password = get_change(changeset, :password)
    changeset
    |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
    |> delete_change(:password)
  end
end
```

### Schemaless Changesets (Forms Without DB)

```elixir
defmodule MyApp.SearchForm do
  @types %{
    query: :string,
    category: :string,
    min_price: :decimal,
    max_price: :decimal,
    sort_by: {:parameterized, Ecto.Enum, Ecto.Enum.init(values: [:relevance, :price, :date])}
  }

  def changeset(params \\ %{}) do
    {%{}, @types}
    |> Ecto.Changeset.cast(params, Map.keys(@types))
    |> Ecto.Changeset.validate_required([:query])
    |> Ecto.Changeset.validate_length(:query, min: 2)
    |> Ecto.Changeset.validate_number(:min_price, greater_than_or_equal_to: 0)
  end

  def search(params) do
    case changeset(params) |> Ecto.Changeset.apply_action(:search) do
      {:ok, filters} -> {:ok, execute_search(filters)}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
```

### Embedded Schema for Polymorphic Validation

Pattern from ExNVR — validate differently based on a parent field:

```elixir
defmodule MyApp.Device do
  use MyApp.Schema

  schema "devices" do
    field :type, Ecto.Enum, values: [:camera, :sensor, :gateway]
    embeds_one :config, Config, on_replace: :update
    timestamps()
  end

  def changeset(device, attrs) do
    device
    |> cast(attrs, [:type])
    |> validate_required([:type])
    |> cast_embed(:config, with: &config_changeset(&1, &2, get_field(device, :type)))
  end

  defp config_changeset(config, attrs, :camera) do
    config
    |> cast(attrs, [:resolution, :fps, :codec])
    |> validate_required([:resolution, :fps])
    |> validate_inclusion(:codec, ["h264", "h265"])
  end

  defp config_changeset(config, attrs, :sensor) do
    config
    |> cast(attrs, [:interval_ms, :threshold])
    |> validate_required([:interval_ms])
    |> validate_number(:interval_ms, greater_than: 0)
  end

  defp config_changeset(config, attrs, _type) do
    cast(config, attrs, [])
  end
end
```

## 4. Query Patterns

### Composable Query Building

```elixir
defmodule MyApp.Blog.PostQueries do
  import Ecto.Query

  def base, do: from(p in MyApp.Blog.Post, as: :post)

  def published(query \\ base()) do
    from [post: p] in query, where: p.status == :published
  end

  def by_author(query \\ base(), author_id) do
    from [post: p] in query, where: p.author_id == ^author_id
  end

  def with_comments(query \\ base()) do
    if has_named_binding?(query, :comments) do
      query
    else
      from [post: p] in query,
        left_join: c in assoc(p, :comments), as: :comments,
        preload: [comments: c]
    end
  end

  def search(query \\ base(), term) do
    pattern = "%#{term}%"
    from [post: p] in query,
      where: ilike(p.title, ^pattern) or ilike(p.body, ^pattern)
  end

  def order_by_recent(query \\ base()) do
    from [post: p] in query, order_by: [desc: p.published_at]
  end

  def paginate(query, page, per_page \\ 20) do
    offset = (page - 1) * per_page
    from query, limit: ^per_page, offset: ^offset
  end
end

# Usage — compose as needed
posts =
  PostQueries.published()
  |> PostQueries.by_author(user_id)
  |> PostQueries.search("elixir")
  |> PostQueries.with_comments()
  |> PostQueries.order_by_recent()
  |> PostQueries.paginate(1)
  |> Repo.all()
```

### Dynamic Queries (Data-Driven Filtering)

```elixir
defmodule MyApp.Blog.PostFilter do
  import Ecto.Query

  def filter(params) when is_map(params) do
    MyApp.Blog.Post
    |> apply_filters(params)
    |> apply_sort(params)
  end

  defp apply_filters(query, params) do
    conditions = true

    conditions =
      if params["status"] do
        dynamic([p], p.status == ^params["status"] and ^conditions)
      else
        conditions
      end

    conditions =
      if params["author_id"] do
        dynamic([p], p.author_id == ^params["author_id"] and ^conditions)
      else
        conditions
      end

    conditions =
      if params["tag"] do
        dynamic([p], ^params["tag"] in p.tags and ^conditions)
      else
        conditions
      end

    conditions =
      if params["since"] do
        dynamic([p], p.published_at >= ^params["since"] and ^conditions)
      else
        conditions
      end

    from p in query, where: ^conditions
  end

  defp apply_sort(query, %{"sort" => "oldest"}), do: from(p in query, order_by: [asc: p.published_at])
  defp apply_sort(query, %{"sort" => "popular"}), do: from(p in query, order_by: [desc: p.views])
  defp apply_sort(query, _params), do: from(p in query, order_by: [desc: p.published_at])
end
```

### Advanced Query Patterns

```elixir
# Subquery: posts by active authors
active_author_ids = from u in User, where: u.active, select: u.id
from p in Post, where: p.author_id in subquery(active_author_ids)

# Fragment: Postgres full-text search
from p in Post,
  where: fragment("to_tsvector('english', ? || ' ' || ?) @@ plainto_tsquery('english', ?)",
    p.title, p.body, ^search_term),
  order_by: fragment("ts_rank(to_tsvector('english', ? || ' ' || ?), plainto_tsquery('english', ?)) DESC",
    p.title, p.body, ^search_term)

# Window function: rank within category
from p in Post,
  select: %{
    id: p.id,
    title: p.title,
    rank: over(row_number(), :category)
  },
  windows: [category: [partition_by: p.category_id, order_by: [desc: p.views]]]

# CTE: recursive category tree
initial = from c in Category, where: is_nil(c.parent_id)
recursive = from c in Category,
  join: ct in "category_tree", on: c.parent_id == ct.id
cte_query = initial |> union_all(^recursive)

from p in Post
|> recursive_ctes(true)
|> with_cte("category_tree", as: ^cte_query)
|> join(:inner, [p], c in "category_tree", on: c.id == p.category_id)
|> select([p, c], {p.title, c.name})

# Upsert with conflict handling
Repo.insert(
  %Post{slug: "hello", views: 1},
  on_conflict: [inc: [views: 1]],
  conflict_target: :slug,
  returning: true
)

# Upsert with query (conditional update)
on_conflict =
  from p in Post,
    update: [set: [views: fragment("EXCLUDED.views + ?", p.views)]]

Repo.insert(%Post{slug: "hello", views: 1},
  on_conflict: on_conflict,
  conflict_target: :slug
)

# Lateral join: top N per group
from a in Author, as: :author
|> join(:inner_lateral, [],
  subquery(
    from p in Post,
      where: p.author_id == parent_as(:author).id,
      order_by: [desc: p.views],
      limit: 3
  ), on: true)
|> select([a, p], {a.name, p.title, p.views})

# selected_as for reusing computed columns
from p in Post,
  select: %{
    month: selected_as(fragment("date_trunc('month', ?)", p.published_at), :month),
    total_views:
      p.views
      |> coalesce(0)
      |> sum()
      |> selected_as(:total)
  },
  group_by: selected_as(:month),
  order_by: selected_as(:total)

# Multi-tenancy with prefix
Repo.all(Post, prefix: "tenant_acme")
from(p in Post, prefix: "tenant_acme") |> Repo.all()
```

## 5. Preloading Strategies

```elixir
# Separate queries (default, best for most cases)
posts = Repo.all(Post) |> Repo.preload([:author, :comments])

# Join preload (single query, avoids round-trip)
posts = Repo.all(
  from p in Post,
    join: a in assoc(p, :author),
    preload: [author: a]
)

# Nested preloads
posts = Repo.all(Post) |> Repo.preload([:author, comments: :likes])

# Preload with custom query (filter/sort)
recent_comments = from c in Comment, order_by: [desc: c.inserted_at], limit: 5
posts = Repo.all(Post) |> Repo.preload(comments: recent_comments)

# Preload with nested custom query
published_posts = from p in Post, where: p.status == :published
authors = Repo.all(Author) |> Repo.preload(posts: {published_posts, [:comments]})

# Top-N per group via window function in preload
ranking =
  from c in Comment,
    select: %{id: c.id, rank: over(row_number(), :per_post)},
    windows: [per_post: [partition_by: c.post_id, order_by: [desc: c.likes_count]]]

top_comments =
  from c in Comment,
    join: r in subquery(ranking), on: c.id == r.id and r.rank <= 3

posts = Repo.all(Post) |> Repo.preload(comments: top_comments)
```

## 6. Migration Patterns

### Standard Migration

```elixir
defmodule MyApp.Repo.Migrations.CreatePosts do
  use Ecto.Migration

  def change do
    create table("posts", primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :slug, :string, null: false
      add :body, :text
      add :status, :string, null: false, default: "draft"
      add :views, :integer, null: false, default: 0
      add :published_at, :utc_datetime_usec
      add :metadata, :map, default: %{}
      add :tags, {:array, :string}, default: []
      add :author_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index("posts", [:slug])
    create index("posts", [:author_id])
    create index("posts", [:status, :published_at])
    create index("posts", [:tags], using: :gin)
  end
end
```

### Concurrent Index (Zero-Downtime)

```elixir
defmodule MyApp.Repo.Migrations.AddPostSearchIndex do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index("posts", [:slug], concurrently: true, if_not_exists: true)
  end
end
```

### Data Migration with Reversible Steps

```elixir
defmodule MyApp.Repo.Migrations.SplitUserNames do
  use Ecto.Migration

  def up do
    alter table("users") do
      add :first_name, :string
      add :last_name, :string
    end

    flush()

    execute """
    UPDATE users SET
      first_name = split_part(name, ' ', 1),
      last_name = CASE
        WHEN position(' ' in name) > 0 THEN substring(name from position(' ' in name) + 1)
        ELSE ''
      END
    """

    alter table("users") do
      remove :name, :string  # reversible: knows type
    end
  end

  def down do
    alter table("users") do
      add :name, :string
    end

    flush()

    execute "UPDATE users SET name = first_name || ' ' || last_name"

    alter table("users") do
      remove :first_name
      remove :last_name
    end
  end
end
```

### Multi-Tenancy Schema Migration

```elixir
defmodule MyApp.Repo.Migrations.CreateTenantPosts do
  use Ecto.Migration

  def change do
    execute "CREATE SCHEMA IF NOT EXISTS tenant_default", "DROP SCHEMA IF EXISTS tenant_default CASCADE"

    create table("posts", prefix: "tenant_default") do
      add :title, :string, null: false
      timestamps()
    end
  end
end
```

## 7. Ecto.Multi Patterns

### Transfer with Audit Trail

```elixir
defmodule MyApp.Billing do
  alias Ecto.Multi
  alias MyApp.Repo

  def transfer_funds(from_account, to_account, amount) do
    Multi.new()
    |> Multi.update(:debit, fn _changes ->
      from_account
      |> Ecto.Changeset.change(balance: from_account.balance - amount)
      |> Ecto.Changeset.validate_number(:balance, greater_than_or_equal_to: 0)
    end)
    |> Multi.update(:credit, fn _changes ->
      Ecto.Changeset.change(to_account, balance: to_account.balance + amount)
    end)
    |> Multi.insert(:audit, fn %{debit: debit, credit: credit} ->
      %AuditLog{
        action: :transfer,
        from_account_id: debit.id,
        to_account_id: credit.id,
        amount: amount,
        performed_at: DateTime.utc_now()
      }
    end)
    |> Multi.run(:notify, fn _repo, %{debit: debit} ->
      Phoenix.PubSub.broadcast(MyApp.PubSub, "account:#{debit.id}", {:balance_updated, debit})
      {:ok, :notified}
    end)
    |> Repo.transact()
  end
end

# Usage
case MyApp.Billing.transfer_funds(from, to, Decimal.new("100.00")) do
  {:ok, %{debit: debit, credit: credit, audit: log}} ->
    {:ok, log}
  {:error, :debit, changeset, _} ->
    {:error, :insufficient_funds}
  {:error, step, reason, _} ->
    {:error, {step, reason}}
end
```

### Dynamic Multi with Reduce

```elixir
def update_all_prices(products, percentage_change) do
  products
  |> Enum.reduce(Multi.new(), fn product, multi ->
    changeset =
      product
      |> Ecto.Changeset.change(price: Decimal.mult(product.price, Decimal.new(percentage_change)))

    Multi.update(multi, {:product, product.id}, changeset)
  end)
  |> Repo.transact()
end
```

### Testing Multi Operations

```elixir
test "transfer creates audit log" do
  multi = MyApp.Billing.build_transfer_multi(from, to, amount)

  # Inspect operations without running
  operations = Ecto.Multi.to_list(multi)
  assert {:debit, {:update, _, []}} = Enum.find(operations, &match?({:debit, _}, &1))
  assert {:credit, {:update, _, []}} = Enum.find(operations, &match?({:credit, _}, &1))
  assert {:audit, {:insert, _, []}} = Enum.find(operations, &match?({:audit, _}, &1))
end
```

## 8. Custom Ecto Type

```elixir
defmodule MyApp.Types.Money do
  use Ecto.Type

  # Stored as integer cents in DB, exposed as {currency, Decimal} in Elixir
  def type, do: :integer

  def cast({currency, %Decimal{} = amount}) when currency in [:usd, :eur, :nok] do
    {:ok, {currency, amount}}
  end
  def cast(_), do: :error

  def load(cents) when is_integer(cents) do
    {:ok, {:usd, Decimal.div(Decimal.new(cents), 100)}}
  end

  def dump({_currency, %Decimal{} = amount}) do
    {:ok,
     amount
     |> Decimal.mult(100)
     |> Decimal.round(0)
     |> Decimal.to_integer()}
  end
  def dump(_), do: :error

  def equal?({c, a}, {c, b}), do: Decimal.equal?(a, b)
  def equal?(_, _), do: false
end

# Usage in schema
field :price, MyApp.Types.Money
```

## 9. Context Module Pattern

```elixir
defmodule MyApp.Blog do
  @moduledoc "The Blog context — public API for blog operations."

  alias MyApp.Repo
  alias MyApp.Blog.{Post, PostQueries, Comment}

  # List with optional filtering
  def list_posts(params \\ %{}) do
    params
    |> PostQueries.filter()
    |> Repo.all()
    |> Repo.preload([:author])
  end

  # Get with preloads
  def get_post!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload([:author, comments: :user])
  end

  # Create
  def create_post(attrs) do
    %Post{}
    |> Post.changeset(attrs)
    |> Repo.insert()
    |> tap_ok(&broadcast({:post_created, &1}))
  end

  # Update
  def update_post(%Post{} = post, attrs) do
    post
    |> Post.changeset(attrs)
    |> Repo.update()
    |> tap_ok(&broadcast({:post_updated, &1}))
  end

  # Delete
  def delete_post(%Post{} = post) do
    Repo.delete(post)
  end

  # Publish (domain-specific action)
  def publish_post(%Post{} = post) do
    post
    |> Post.publish_changeset()
    |> Repo.update()
    |> tap_ok(&broadcast({:post_published, &1}))
  end

  # Change tracking for forms
  def change_post(%Post{} = post, attrs \\ %{}) do
    Post.changeset(post, attrs)
  end

  # PubSub integration
  def subscribe do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "blog")
  end

  defp broadcast({:ok, record} = result, _) do
    # Only called on success via tap_ok
    result
  end

  defp tap_ok({:ok, record} = result, fun) do
    fun.(record)
    result
  end
  defp tap_ok(error, _fun), do: error

  defp broadcast(event) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, "blog", event)
  end
end
```

## 10. Soft Delete with prepare_query

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres

  @impl true
  def prepare_query(_operation, query, opts) do
    cond do
      opts[:include_deleted] || opts[:schema_migration] ->
        {query, opts}
      true ->
        query = from(x in query, where: is_nil(x.deleted_at))
        {query, opts}
    end
  end
end

# Normal queries auto-filter deleted records
Repo.all(Post)                            # WHERE deleted_at IS NULL
Repo.all(Post, include_deleted: true)     # No filter — see everything

# Soft delete
def soft_delete(record) do
  record
  |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
  |> Repo.update()
end
```

## 11. Multi-Tenancy with Prefix

```elixir
defmodule MyApp.Tenancy do
  @doc "Run a query scoped to a tenant's schema."
  def scope(queryable, tenant_id) do
    queryable
    |> Ecto.Queryable.to_query()
    |> Map.put(:prefix, "tenant_#{tenant_id}")
  end

  def insert(changeset, tenant_id) do
    MyApp.Repo.insert(changeset, prefix: "tenant_#{tenant_id}")
  end

  def all(queryable, tenant_id) do
    MyApp.Repo.all(queryable, prefix: "tenant_#{tenant_id}")
  end

  # Create schema for new tenant
  def create_tenant_schema(tenant_id) do
    prefix = "tenant_#{tenant_id}"
    MyApp.Repo.query!("CREATE SCHEMA IF NOT EXISTS \"#{prefix}\"")
    # Run migrations for this schema
    Ecto.Migrator.run(MyApp.Repo, :up, all: true, prefix: prefix)
  end
end
```

## 12. Streaming Large Datasets

```elixir
defmodule MyApp.Reports do
  alias MyApp.Repo

  def export_all_posts_csv do
    Repo.transact(fn ->
      Post
      |> order_by(:id)
      |> Repo.stream(max_rows: 500)
      |> Stream.map(&post_to_csv_row/1)
      |> Stream.into(File.stream!("/tmp/posts.csv"))
      |> Stream.run()

      {:ok, "/tmp/posts.csv"}
    end)
  end

  defp post_to_csv_row(post) do
    [post.id, post.title, post.status, to_string(post.published_at)]
    |> Enum.join(",")
    |> Kernel.<>("\n")
  end
end
```

## 13. Testing Ecto Code

```elixir
defmodule MyApp.Blog.PostTest do
  use MyApp.DataCase, async: true

  alias MyApp.Blog
  alias MyApp.Blog.Post

  describe "changeset/2" do
    test "valid attributes" do
      attrs = %{title: "Hello World", body: "Long enough body text", author_id: Ecto.UUID.generate()}
      changeset = Post.changeset(%Post{}, attrs)
      assert changeset.valid?
    end

    test "requires title" do
      changeset = Post.changeset(%Post{}, %{body: "some body"})
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates title length" do
      changeset = Post.changeset(%Post{}, %{title: "ab", body: "long enough", author_id: Ecto.UUID.generate()})
      assert %{title: ["should be at least 3 character(s)"]} = errors_on(changeset)
    end
  end

  describe "create_post/1" do
    test "creates post with valid data" do
      user = insert(:user)
      attrs = %{title: "Test Post", body: "Test body content", author_id: user.id}

      assert {:ok, %Post{} = post} = Blog.create_post(attrs)
      assert post.title == "Test Post"
      assert post.status == :draft
    end

    test "returns error changeset with invalid data" do
      assert {:error, %Ecto.Changeset{}} = Blog.create_post(%{})
    end

    test "enforces unique slug" do
      user = insert(:user)
      attrs = %{title: "Same Title", body: "Body text here", author_id: user.id}

      assert {:ok, _} = Blog.create_post(attrs)
      assert {:error, changeset} = Blog.create_post(attrs)
      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "list_posts/1" do
    test "filters by status" do
      published = insert(:post, status: :published)
      _draft = insert(:post, status: :draft)

      posts = Blog.list_posts(%{"status" => "published"})
      assert [%Post{id: id}] = posts
      assert id == published.id
    end
  end
end
```

## 14. Optimistic Locking

```elixir
defmodule MyApp.Inventory.Product do
  use MyApp.Schema

  schema "products" do
    field :name, :string
    field :stock, :integer, default: 0
    field :lock_version, :integer, default: 1
    timestamps()
  end

  def changeset(product, attrs) do
    product
    |> cast(attrs, [:name, :stock])
    |> validate_required([:name])
    |> validate_number(:stock, greater_than_or_equal_to: 0)
    |> optimistic_lock(:lock_version)
  end
end

# Usage — retries on conflict
def decrement_stock(product, quantity) do
  changeset = Product.changeset(product, %{stock: product.stock - quantity})

  case Repo.update(changeset) do
    {:ok, product} -> {:ok, product}
    {:error, %{errors: [lock_version: _]}} ->
      # Someone else updated — reload and retry
      product
      |> Repo.reload!()
      |> decrement_stock(quantity)
    {:error, changeset} -> {:error, changeset}
  end
end
```

## Related Files

- **[SKILL.md](SKILL.md)** — Ecto rules (15), key patterns, BAD/GOOD pairs
- **[ecto-reference.md](ecto-reference.md)** — Quick-lookup tables: field types, changeset API, Query.API functions, Repo API, migrations, Multi, custom type callbacks, association helpers
- **[testing-reference.md](testing-reference.md)** — Ecto testing patterns, sandbox setup, DataCase
- **[production.md](production.md)** — Production Repo configuration, telemetry
