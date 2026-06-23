# Ecto Quick Reference

Quick-lookup tables for Ecto schemas, changesets, queries, migrations, Multi, Repo API, and custom types. Patterns sourced from Ecto/ecto_sql source code, test suite, and official hexdocs documentation.

## Dependencies

```elixir
# mix.exs
defp deps do
  [
    {:ecto_sql, "~> 3.12"},
    {:postgrex, ">= 0.0.0"},       # PostgreSQL adapter
    # or {:myxql, ">= 0.0.0"},     # MySQL adapter
    # or {:ecto_sqlite3, ">= 0.0.0"} # SQLite adapter
  ]
end
```

## Schema Field Types

| Ecto Type | Elixir Type | DB Type (Postgres) | Notes |
|-----------|-------------|-------------------|-------|
| `:string` | `String.t()` | `varchar` | Default type if omitted |
| `:text` | `String.t()` | `text` | Unlimited length |
| `:integer` | `integer()` | `integer` | |
| `:float` | `float()` | `float` | |
| `:decimal` | `Decimal.t()` | `numeric` | Use for money/precision |
| `:boolean` | `boolean()` | `boolean` | |
| `:binary` | `binary()` | `bytea` | Raw bytes |
| `:binary_id` | `binary()` | `uuid` | UUID stored as binary |
| `:id` | `integer()` | `bigserial` | Auto-increment PK |
| `:map` | `map()` | `jsonb` | Arbitrary JSON map |
| `{:map, inner}` | `map()` | `jsonb` | Typed map values |
| `{:array, inner}` | `list()` | `type[]` | Array of inner type |
| `:date` | `Date.t()` | `date` | |
| `:time` | `Time.t()` | `time` | |
| `:time_usec` | `Time.t()` | `time(6)` | Microsecond precision |
| `:naive_datetime` | `NaiveDateTime.t()` | `timestamp` | No timezone |
| `:naive_datetime_usec` | `NaiveDateTime.t()` | `timestamp(6)` | |
| `:utc_datetime` | `DateTime.t()` | `timestamptz` | UTC timezone |
| `:utc_datetime_usec` | `DateTime.t()` | `timestamptz(6)` | Recommended for timestamps |
| `:duration` | `Duration.t()` | `interval` | Elixir 1.17+ |
| `Ecto.Enum` | `atom()` | `varchar` or `integer` | See Enum section |

## Schema Field Options

| Option | Type | Description |
|--------|------|-------------|
| `:default` | any | Default value (set before DB) |
| `:source` | atom | Maps to different DB column name |
| `:virtual` | boolean | Not persisted to DB |
| `:redact` | boolean | Hidden in inspect/logs |
| `:load_in_query` | boolean | Exclude from default SELECT (large columns) |
| `:writable` | `:always` \| `:insert` \| `:never` | Controls changeset write access |
| `:autogenerate` | `{m, f, a}` | Auto-generate on insert |
| `:read_after_writes` | boolean | Re-read from DB after write |
| `:primary_key` | boolean | Mark as PK (composite keys) |
| `:skip_default_validation` | boolean | Skip compile-time default type check |

## Primary Key Options

```elixir
# Default: auto-increment integer
@primary_key {:id, :id, autogenerate: true}

# UUID
@primary_key {:id, :binary_id, autogenerate: true}

# No auto PK (composite keys, join tables)
@primary_key false

# Custom PK name
@primary_key {:uuid, :binary_id, autogenerate: true}
```

## Association Options

| Option | Applies To | Description |
|--------|-----------|-------------|
| `:on_replace` | all | `:raise` \| `:mark_as_invalid` \| `:nilify` \| `:update` \| `:delete` \| `:delete_if_exists` |
| `:on_delete` | has_many/has_one | `:nothing` \| `:nilify_all` \| `:delete_all` (prefer migration-level) |
| `:preload_order` | all | Default sort for preloads |
| `:where` | all | Permanent filter on association queries |
| `:defaults` | all | Default values on related struct creation |
| `:join_where` | many_to_many | Filter on join table |

## Changeset Validations

| Function | Purpose | Key Options |
|----------|---------|-------------|
| `validate_required/3` | Fields present and non-empty | `:message`, `:trim` |
| `validate_format/4` | Regex match | `:message` |
| `validate_inclusion/4` | Value in enumerable | `:message` |
| `validate_exclusion/4` | Value NOT in enumerable | `:message` |
| `validate_subset/4` | List subset of allowed | `:message` |
| `validate_length/3` | String/list length | `:min`, `:max`, `:is`, `:count` |
| `validate_number/3` | Numeric bounds | `:less_than`, `:greater_than`, `:equal_to`, `:less_than_or_equal_to`, `:greater_than_or_equal_to`, `:not_equal_to` |
| `validate_confirmation/3` | Field matches `field_confirmation` | `:message`, `:required` |
| `validate_acceptance/3` | Boolean true (ToS checkboxes) | `:message` |
| `validate_change/3` | Custom validator function | |
| `unsafe_validate_unique/4` | Uniqueness (race-prone, UX only) | `:repo`, `:repo_opts`, `:message` |

## Changeset Constraints (Deferred to DB)

| Function | Maps To | Purpose |
|----------|---------|---------|
| `unique_constraint/3` | Unique index violation | Unique field/combo |
| `check_constraint/3` | Check constraint violation | DB-level validation |
| `foreign_key_constraint/3` | FK violation | Referenced record must exist |
| `no_assoc_constraint/3` | FK from other table | No child records exist |
| `exclusion_constraint/3` | Exclusion constraint | Postgres range overlap |

## Changeset Functions

| Function | Purpose | Notes |
|----------|---------|-------|
| `cast/4` | External params → changeset | String keys, type casting, filtering |
| `change/2` | Internal data → changeset | Atom keys, no casting, trusts input |
| `cast_assoc/3` | Cast associated records | With `:with`, `:sort_param`, `:drop_param` |
| `cast_embed/3` | Cast embedded records | Same options as `cast_assoc` |
| `put_assoc/4` | Replace whole association | Must pass changesets/maps, not modified structs |
| `put_embed/4` | Replace whole embed | |
| `put_change/3` | Set a single field | |
| `force_change/3` | Set even if unchanged | |
| `delete_change/2` | Remove from changes | |
| `apply_action/2` | Validate and return data | `{:ok, data}` or `{:error, changeset}` |
| `apply_changes/1` | Apply without validation | Use `apply_action` for forms |
| `prepare_changes/2` | Run in transaction | Has access to `changeset.repo` |
| `optimistic_lock/3` | Concurrency control | Auto-increment version field |
| `traverse_errors/2` | Extract error messages | For `errors_on/1` helper |

## Query Operations

| Function | Keyword | Pipe | Notes |
|----------|---------|------|-------|
| `from/2` | `from u in User` | `User \|> ...` | Entry point |
| `where/3` | `where: u.age > 18` | `where([u], u.age > 18)` | Filters |
| `select/3` | `select: u.name` | `select([u], u.name)` | Choose columns |
| `select_merge/3` | `select_merge: %{n: u.name}` | | Additive select |
| `order_by/3` | `order_by: [desc: u.age]` | | Sorting |
| `group_by/3` | `group_by: u.role` | | Grouping |
| `having/3` | `having: count(u.id) > 5` | | Group filter |
| `limit/3` | `limit: 10` | | Row limit |
| `offset/3` | `offset: 20` | | Skip rows |
| `distinct/3` | `distinct: true` | | Unique rows |
| `join/5` | `join: c in assoc(p, :comments)` | | See join types |
| `preload/3` | `preload: [:comments]` | | Eager load |
| `lock/3` | `lock: "FOR UPDATE"` | | Row locking |
| `prefix/3` | `prefix: "tenant_1"` | | Schema/multi-tenancy |
| `union/2` | `union: ^other_query` | | Set operations |
| `except/2` | `except: ^other_query` | | Set difference |
| `intersect/2` | `intersect: ^other_query` | | Set intersection |
| `windows/3` | `windows: [w: [...]]` | | Window functions |

## Join Types

| Type | Keyword |
|------|---------|
| Inner | `join:` or `inner_join:` |
| Left outer | `left_join:` |
| Right outer | `right_join:` |
| Full outer | `full_join:` |
| Cross | `cross_join:` |
| Inner lateral | `inner_lateral_join:` |
| Left lateral | `left_lateral_join:` |
| Cross lateral | `cross_lateral_join:` |

## Repo API

| Function | Returns | Purpose |
|----------|---------|---------|
| `insert/2` | `{:ok, struct}` \| `{:error, changeset}` | Insert record |
| `update/2` | `{:ok, struct}` \| `{:error, changeset}` | Update record |
| `delete/2` | `{:ok, struct}` \| `{:error, changeset}` | Delete record |
| `insert_or_update/2` | `{:ok, struct}` \| `{:error, changeset}` | Upsert by PK |
| `insert!/2` | `struct` | Insert or raise |
| `update!/2` | `struct` | Update or raise |
| `delete!/2` | `struct` | Delete or raise |
| `get/3` | `struct \| nil` | By primary key |
| `get!/3` | `struct` | By PK, raises if nil |
| `get_by/3` | `struct \| nil` | By arbitrary clauses |
| `get_by!/3` | `struct` | By clauses, raises |
| `one/2` | `struct \| nil` | Single result, raises if >1 |
| `one!/2` | `struct` | Single result, raises if 0 or >1 |
| `all/2` | `[struct]` | All matching records |
| `exists?/2` | `boolean` | Existence check (efficient) |
| `reload/2` | `{:ok, struct}` \| `{:error, term}` | Re-fetch from DB |
| `aggregate/3` | `term` | `:count`, `:avg`, `:max`, `:min`, `:sum` |
| `preload/3` | `struct \| [struct]` | Load associations |
| `insert_all/3` | `{count, nil \| [map]}` | Bulk insert |
| `update_all/3` | `{count, nil \| [map]}` | Bulk update |
| `delete_all/2` | `{count, nil \| [map]}` | Bulk delete |
| `stream/2` | `Enum.t()` | Streaming — requires transaction; `:max_rows` option (default 500) |
| `transact/2` | `{:ok, result}` \| `{:error, reason}` | Transaction (**preferred**) — fn must return `{:ok, _}` or `{:error, _}` |
| `transaction/2` | `{:ok, result}` \| `{:error, reason}` | Transaction (**deprecated**) — auto-wraps return, use `Repo.rollback/1` |

## Repo insert/update Options

| Option | Purpose |
|--------|---------|
| `:on_conflict` | Upsert strategy: `:nothing`, `:raise`, `:replace_all`, `{:replace, fields}`, `{:replace_all_except, fields}`, or `Ecto.Query` |
| `:conflict_target` | Column(s) or constraint for conflict detection |
| `:returning` | Columns to return after write (Postgres) |
| `:prefix` | Schema/database prefix (multi-tenancy) |
| `:stale_error_field` | Field for optimistic lock errors |
| `:stale_error_message` | Message for optimistic lock errors |
| `:placeholders` | Reusable values in bulk inserts (Postgres) |

## Ecto.Multi Operations

| Function | Signature | Purpose |
|----------|-----------|---------|
| `insert/4` | `(multi, name, changeset_or_fun, opts)` | Insert record |
| `update/4` | `(multi, name, changeset_or_fun, opts)` | Update record |
| `delete/4` | `(multi, name, changeset_or_fun, opts)` | Delete record |
| `insert_or_update/4` | `(multi, name, changeset_or_fun, opts)` | Upsert |
| `insert_all/5` | `(multi, name, schema, entries, opts)` | Bulk insert |
| `update_all/4` | `(multi, name, queryable, opts)` | Bulk update |
| `delete_all/3` | `(multi, name, queryable)` | Bulk delete |
| `run/3` | `(multi, name, fun)` | Arbitrary function |
| `put/3` | `(multi, name, value)` | Store static value |
| `one/4` | `(multi, name, queryable, opts)` | Query single |
| `all/4` | `(multi, name, queryable, opts)` | Query all |
| `inspect/2` | `(multi, opts)` | IO.inspect pipeline |
| `merge/2` | `(multi, fun)` | Dynamic Multi |
| `to_list/1` | `(multi)` | Inspect operations (testing) |

## Migration Column Types

| Type | Postgres | MySQL | Notes |
|------|----------|-------|-------|
| `:string` | `varchar(255)` | `varchar(255)` | Default size |
| `:text` | `text` | `text` | Unlimited |
| `:integer` | `integer` | `int` | |
| `:bigint` | `bigint` | `bigint` | |
| `:float` | `float` | `float` | |
| `:decimal` | `numeric` | `decimal` | Use `:precision`, `:scale` |
| `:boolean` | `boolean` | `tinyint(1)` | |
| `:binary` | `bytea` | `blob` | |
| `:binary_id` | `uuid` | `binary(16)` | |
| `:map` | `jsonb` | `json` | |
| `{:array, type}` | `type[]` | N/A | Postgres only |
| `:date` | `date` | `date` | |
| `:time` | `time` | `time` | |
| `:naive_datetime` | `timestamp` | `datetime` | |
| `:utc_datetime` | `timestamptz` | `datetime` | |
| `:identity` | `bigint GENERATED` | N/A | Postgres identity column |

## Migration Reference Options

| Option | Values | Default |
|--------|--------|---------|
| `:on_delete` | `:nothing`, `:delete_all`, `:nilify_all`, `:restrict` | `:nothing` |
| `:on_update` | `:nothing`, `:update_all`, `:nilify_all`, `:restrict` | `:nothing` |
| `:type` | any column type | `:bigserial` |
| `:column` | atom | `:id` |
| `:prefix` | string | nil (cross-schema FK) |
| `:validate` | boolean | `true` (set `false` for large table migrations) |

## Migration Index Options

| Option | Purpose |
|--------|---------|
| `:unique` | Unique constraint |
| `:concurrently` | Non-blocking (requires `@disable_ddl_transaction true`) |
| `:using` | Index type: `:btree`, `:hash`, `:gin`, `:gist`, `:spgist`, `:brin` |
| `:where` | Partial index condition |
| `:include` | Covering index columns (Postgres) |
| `:nulls_distinct` | Null handling in unique indexes (Postgres 15+) |
| `:prefix` | Schema prefix |
| `:name` | Custom index name |

## Ecto.Enum

```elixir
# String-backed (default)
field :status, Ecto.Enum, values: [:draft, :published, :archived]

# Integer-backed
field :priority, Ecto.Enum, values: [low: 1, medium: 2, high: 3]

# Array of enums
field :roles, {:array, Ecto.Enum}, values: [:admin, :editor, :viewer]

# Helper functions
Ecto.Enum.values(MySchema, :status)       # [:draft, :published, :archived]
Ecto.Enum.mappings(MySchema, :status)     # [draft: "draft", ...]
Ecto.Enum.dump_values(MySchema, :status)  # ["draft", "published", "archived"]
```

## Schema Reflection

```elixir
MySchema.__schema__(:source)        # table name
MySchema.__schema__(:fields)        # non-virtual field names
MySchema.__schema__(:type, :field)  # field type
MySchema.__schema__(:associations)  # association names
MySchema.__schema__(:primary_key)   # primary key fields
MySchema.__schema__(:embeds)        # embed names
```

## Mix Tasks

```bash
# Database management
mix ecto.create               # Create database
mix ecto.drop                 # Drop database
mix ecto.reset                # Drop + create + migrate

# Migrations
mix ecto.gen.migration NAME   # Generate migration file
mix ecto.migrate              # Run pending migrations
mix ecto.rollback             # Rollback last migration
mix ecto.rollback --step 3    # Rollback 3 migrations
mix ecto.rollback --to 20230101120000  # Rollback to version
mix ecto.migrations           # Show migration status

# Code generation
mix phx.gen.schema Post posts title:string body:text
mix phx.gen.context Blog Post posts title:string
mix phx.gen.live Blog Post posts title:string
mix phx.gen.auth Accounts User users
```

## Repo Configuration

```elixir
# config/dev.exs
config :my_app, MyApp.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "my_app_dev",
  stacktrace: true,                          # include stacktraces in telemetry
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# config/test.exs
config :my_app, MyApp.Repo,
  pool: Ecto.Adapters.SQL.Sandbox,           # test isolation
  pool_size: System.schedulers_online() * 2  # parallel tests

# config/runtime.exs (production)
config :my_app, MyApp.Repo,
  url: System.fetch_env!("DATABASE_URL"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
  ssl: true,
  socket_options: [:inet6]

# Migration defaults in mix.exs
def project do
  [
    ...,
    aliases: aliases()
  ]
end

defp aliases do
  [
    setup: ["deps.get", "ecto.setup"],
    "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
    "ecto.reset": ["ecto.drop", "ecto.setup"],
    test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"]
  ]
end
```

## Repo-Level Configuration

```elixir
# In mix.exs project config
config :my_app, MyApp.Repo,
  migration_primary_key: [name: :uuid, type: :binary_id],
  migration_foreign_key: [type: :binary_id],
  migration_timestamps: [type: :utc_datetime_usec],
  migration_lock: :pg_advisory_lock
```

## Telemetry Events

Ecto emits `[:my_app, :repo, :query]` for every query with these measurements (all in native time units):

| Measurement | Description |
|------------|-------------|
| `:idle_time` | Connection idle before checkout |
| `:queue_time` | Waiting for connection |
| `:query_time` | Query execution |
| `:decode_time` | Result decoding |
| `:total_time` | queue + query + decode |

Metadata: `:repo`, `:query` (SQL string), `:source` (table), `:params`, `:result`, `:stacktrace` (if enabled).

## Changeset Semantics — Validations vs Constraints

Changesets are **eagerly evaluated data structures**, not lazy. Each function in the pipeline executes immediately and returns a new `%Changeset{}`:

```elixir
user
|> cast(params, [:email, :name])           # Executes NOW — casts and filters params
|> validate_required([:email])             # Executes NOW — checks presence, adds error
|> validate_format(:email, ~r/@/)          # Executes NOW — checks format
|> unique_constraint(:email)               # DEFERRED — just registers a constraint handler
|> Repo.insert()                           # DB hit; if unique index fails, constraint fires
```

**Critical distinctions:**
- **Validations** (`validate_*`) run immediately when called. If any fail, `valid?` is `false`
- **Constraints** (`*_constraint`) are deferred — they register handlers that fire ONLY if the DB returns an error
- If `valid?` is `false`, Repo never hits the DB — constraints never execute
- `unique_constraint` is NOT a validation — it's a post-insert DB check that converts a DB error into a changeset error

**Ecto.Multi** validates static changesets BEFORE starting the transaction:
```elixir
Multi.new()
|> Multi.insert(:user, invalid_changeset)   # valid?: false
|> Repo.transact()                           # Returns {:error, :user, changeset, %{}}
# Transaction never started — the invalid changeset was caught pre-transaction
# But function-based operations skip this check (changeset doesn't exist yet)
```

## Query Expression Functions (Ecto.Query.API)

Functions available inside `from`, `where`, `select`, `order_by`, etc. Require `import Ecto.Query`.

### Comparison & Logic

| Function | Usage | Notes |
|----------|-------|-------|
| `==`, `!=`, `<`, `>`, `<=`, `>=` | `where: p.age > 18` | Standard comparisons |
| `and`, `or`, `not` | `where: p.active and not p.banned` | Boolean logic |
| `in/2` | `where: p.status in [:draft, :published]` | List, array column, or subquery |
| `is_nil/1` | `where: is_nil(p.deleted_at)` | NULL check |

### Aggregates

| Function | Usage | Notes |
|----------|-------|-------|
| `count/0` | `select: count()` | Count all rows |
| `count/1` | `select: count(p.id)` | Count non-null values |
| `count/2` | `select: count(p.category, :distinct)` | Count distinct values |
| `avg/1` | `select: avg(p.price)` | Average |
| `sum/1` | `select: sum(p.views)` | Sum |
| `min/1`, `max/1` | `select: max(p.inserted_at)` | Min/max |
| `filter/2` | `select: avg(p.value) \|> filter(p.value > 0)` | Postgres FILTER clause on aggregate |

### Fragments & Type Casting

| Function | Usage | Notes |
|----------|-------|-------|
| `fragment/1` | `fragment("lower(?)", p.title)` | Raw SQL — `?` for params |
| `fragment` + `splice/1` | `fragment("? IN (?)", p.id, splice(^ids))` | Variable-length params |
| `type/2` | `type(^value, :string)` | Cast to Ecto type (not DB type) |
| `type/2` column | `type(^value, p.field)` | Cast to match column's type |
| `coalesce/2` | `coalesce(p.nickname, p.name)` | First non-null; chain for 3+ args |

### Time & Date

| Function | Usage | Notes |
|----------|-------|-------|
| `ago/2` | `where: p.created_at > ago(3, "month")` | Subtract from UTC now (computed in Elixir) |
| `from_now/2` | `where: p.expires_at < from_now(1, "week")` | Add to UTC now |
| `datetime_add/3` | `datetime_add(p.start, 1, "hour")` | Add interval to datetime |
| `date_add/3` | `date_add(p.date, 7, "day")` | Add interval to date |

Interval strings: `"year"`, `"month"`, `"week"`, `"day"`, `"hour"`, `"minute"`, `"second"`, `"millisecond"`, `"microsecond"`.

### String

| Function | Usage | Notes |
|----------|-------|-------|
| `like/2` | `where: like(p.title, "Elixir%")` | Case-sensitive (case-insensitive on MySQL) |
| `ilike/2` | `where: ilike(p.title, "%elixir%")` | Case-insensitive — Postgres only |

### Named Bindings & Subqueries

| Function | Usage | Notes |
|----------|-------|-------|
| `as/1` | `from p in Post, as: :post` | Name a binding for later reference |
| `parent_as/1` | `parent_as(:post).id` | Reference parent query binding in subquery |
| `exists/1` | `where: exists(subquery)` | TRUE if subquery returns rows |
| `any/1` | `where: p.id == any(subquery)` | Compare against any subquery row |
| `all/1` | `where: p.price > all(subquery)` | Compare against all subquery rows |
| `subquery/2` | `where: p.id in subquery(q)` | Nest a query as subquery |

### Computed Columns

| Function | Usage | Notes |
|----------|-------|-------|
| `selected_as/2` | `selected_as(sum(p.views), :total)` | Create alias in `select` |
| `selected_as/1` | `order_by: selected_as(:total)` | Reference alias in `group_by`/`order_by`/`having` |

### Struct & Map Selection

| Function | Usage | Notes |
|----------|-------|-------|
| `map/2` | `select: map(p, [:title, :body])` | Return map with selected fields |
| `struct/2` | `select: struct(p, [:title])` | Return struct with selected fields |
| `merge/2` | `select: merge(p, %{custom: p.x})` | Merge map into result |
| `field/2` | `field(p, ^field_name)` | Dynamic field access |
| `json_extract_path/2` | `p.metadata["key"]` | JSON field access (sugar syntax) |

### Dynamic Queries

`dynamic/2` (macro in `Ecto.Query`) builds composable query fragments:

```elixir
import Ecto.Query

# Build conditions incrementally
conditions = dynamic([p], p.active == true)
conditions = if title, do: dynamic([p], p.title == ^title and ^conditions), else: conditions
from p in Post, where: ^conditions

# In order_by
order = [asc: dynamic([p], fragment("lower(?)", p.title))]
from p in Post, order_by: ^order

# In select (map form)
fields = %{total: dynamic([p], sum(p.views))}
from p in Post, select: ^fields, group_by: p.category_id

# In update
updates = [set: [score: dynamic([p], p.views * 2 + p.likes)]]
from p in Post, update: ^updates
```

### Window Functions

Available via `over/2` — see `Ecto.Query.WindowAPI`:

| Function | Notes |
|----------|-------|
| `row_number/0` | Row number within partition |
| `rank/0`, `dense_rank/0` | Ranking with/without gaps |
| `ntile/1` | Divide into N buckets |
| `lag/1-3`, `lead/1-3` | Previous/next row values |
| `first_value/1`, `last_value/1` | First/last in window |
| `nth_value/2` | Nth value in window |
| `percent_rank/0`, `cume_dist/0` | Statistical ranking |

```elixir
from p in Post,
  select: %{title: p.title, rank: over(row_number(), :by_cat)},
  windows: [by_cat: [partition_by: p.category_id, order_by: [desc: p.views]]]
```

### Query Helper Functions

| Function | Usage | Notes |
|----------|-------|-------|
| `has_named_binding?/2` | `has_named_binding?(query, :comments)` | Check if binding exists (avoid duplicate joins) |
| `with_named_binding/3` | `with_named_binding(query, :comments, fn q, b -> ...)` | Add binding only if not present |
| `values/2` | `values([%{id: 1}, %{id: 2}], %{id: :integer})` | Constant table (Postgres VALUES) |

## Association Helpers (Ecto module)

| Function | Signature | Purpose |
|----------|-----------|---------|
| `Ecto.assoc/2` | `Ecto.assoc(struct_or_structs, assoc)` | Returns query for associated records |
| `Ecto.assoc/2` nested | `Ecto.assoc(posts, [:comments, :author])` | Traverse through associations |
| `Ecto.build_assoc/3` | `Ecto.build_assoc(struct, assoc, attrs \\ %{})` | Build struct with FK pre-filled |

```elixir
# Query for a post's comments
Repo.all(Ecto.assoc(post, :comments))

# Build associated struct
comment = Ecto.build_assoc(post, :comments, body: "Great post!")
# => %Comment{post_id: post.id, body: "Great post!"}

# Traverse nested associations (all authors who commented on these posts)
Repo.all(Ecto.assoc(posts, [:comments, :author]))
```

## Custom Ecto Type Callbacks

### Basic Type (`use Ecto.Type`)

| Callback | Returns | Required |
|----------|---------|----------|
| `type/0` | Ecto primitive (`:string`, `:integer`, etc.) | Yes |
| `cast/1` | `{:ok, value}` \| `:error` \| `{:error, keyword()}` | Yes |
| `load/1` | `{:ok, value}` \| `:error` | Yes |
| `dump/1` | `{:ok, value}` \| `:error` | Yes |
| `equal?/2` | `boolean` | No (defaults to `==`) |
| `embed_as/1` | `:self` \| `:dump` | No (defaults to `:self`) |
| `autogenerate/0` | `term` | No |

Data flow: **user input** →`cast`→ **Elixir value** →`dump`→ **DB value** →`load`→ **Elixir value**

### Parameterized Type (`use Ecto.ParameterizedType`)

For types that need configuration (like `Ecto.Enum`). Same callbacks but with extra `params` argument:

| Callback | Signature | Required |
|----------|-----------|----------|
| `init/1` | `init(opts) :: params` | Yes |
| `type/1` | `type(params)` | Yes |
| `cast/2` | `cast(value, params)` | Yes |
| `load/3` | `load(value, loader_fn, params)` | Yes |
| `dump/3` | `dump(value, dumper_fn, params)` | Yes |

Key difference: `load/3` and `dump/3` receive loader/dumper functions for composite types, and are called for `nil` values (unlike basic types).

## Schemaless Changesets

For forms/validation without a database-backed schema:

```elixir
types = %{query: :string, min_price: :decimal, sort: {:parameterized, Ecto.Enum, Ecto.Enum.init(values: [:relevance, :price])}}

{%{}, types}
|> Ecto.Changeset.cast(params, Map.keys(types))
|> Ecto.Changeset.validate_required([:query])
|> Ecto.Changeset.apply_action(:validate)
```

**Limitation:** `unsafe_validate_unique/4` does NOT work with schemaless changesets.

## Related Files

- **[SKILL.md](SKILL.md)** — Ecto rules (15), key patterns, BAD/GOOD pairs (N+1, TOCTOU, god changeset)
- **[ecto-examples.md](ecto-examples.md)** — Complete worked examples: schemas, multi-step changesets, composable queries, dynamic filters, preloading strategies, migrations, Multi patterns, custom types, soft delete, multi-tenancy, streaming, optimistic locking
- **[testing-reference.md](testing-reference.md)** — Ecto sandbox setup, DataCase, factory patterns
- **[production.md](production.md)** — Repo configuration, telemetry, connection pooling
