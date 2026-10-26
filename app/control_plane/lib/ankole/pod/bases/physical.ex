defmodule Ankole.Pod.Bases.Physical do
  @moduledoc "Typed records and transaction-local counters in a tenant's Base shard."
  Module.register_attribute(__MODULE__, :raw_sql_scope, persist: true)
  @raw_sql_scope :tenant_schema
  alias Ankole.Pod.{BaseRepo, Formula, Values}
  alias Ankole.Pod.Bases.Links

  def stored?(field), do: not Formula.readonly?(field) and field.type != :link

  def sql_type(field) do
    case Formula.type(field) do
      :number -> if(field.type == :auto_number, do: "bigint", else: "numeric")
      :boolean -> "boolean"
      :datetime -> "timestamptz"
      :array -> "jsonb"
      :text -> "text"
    end
  end

  def expression(%{type: :link} = field, row), do: Links.expression(field, row)
  def expression(field, row), do: "#{row}.#{BaseRepo.column(field.id)}"

  def data_sql(fields, row \\ "r") do
    fields
    |> Enum.reject(&Formula.readonly?/1)
    |> Enum.map(fn field ->
      expr = expression(field, row)
      expr = if field.type == :datetime, do: Ankole.Pod.Query.utc_timestamp(expr), else: expr
      "jsonb_build_object('#{field.id}',#{expr})"
    end)
    |> case do
      [] -> "'{}'::jsonb"
      values -> "jsonb_strip_nulls(#{Enum.join(values, " || ")})"
    end
  end

  def fields(table, fields), do: Enum.map(fields, &Map.put(&1, :storage_mode, table.storage_mode))

  def refresh(tables) do
    Enum.reduce_while(tables, {:ok, []}, fn table, {:ok, rows} ->
      result = if table.storage_mode == :physical, do: state(table), else: {:ok, table}

      case result do
        {:ok, current} -> {:cont, {:ok, [current | rows]}}
        error -> {:halt, error}
      end
    end)
  end

  def lock_states(write) do
    peers =
      for fields <- Map.values(write.definitions),
          field <- fields,
          field.type == :link and
            (field.table_id == write.table.id or field.config["table_id"] == write.table.id),
          id <- [field.table_id, field.config["table_id"]],
          do: id

    ids = [write.table.id | Map.keys(write.changes)] ++ peers
    tables = write.tables |> Map.take(ids) |> Enum.sort_by(&elem(&1, 0))

    Enum.reduce_while(tables, {:ok, write}, fn
      {_id, %{storage_mode: :inline}}, result ->
        {:cont, result}

      {id, table}, {:ok, write} ->
        case state(table, "FOR UPDATE") do
          {:ok, current} -> {:cont, {:ok, %{write | tables: Map.put(write.tables, id, current)}}}
          error -> {:halt, error}
        end
    end)
    |> case do
      {:ok, write} -> {:ok, %{write | table: Map.fetch!(write.tables, write.table.id)}}
      error -> error
    end
  end

  def state(table, lock \\ "") do
    case BaseRepo.query(
           "SELECT schema_version,data_version,record_count,next_auto_number FROM #{BaseRepo.states()} WHERE table_id=$1::text::uuid #{lock}",
           [table.id]
         ) do
      {:ok, %{rows: [[version, data, count, next]]}} when version == table.schema_version ->
        {:ok, %{table | data_version: data, record_count: count, next_auto_number: next}}

      {:ok, _} ->
        Ankole.Logging.error(
          "pod.base.schema_mismatch",
          "Base schema requires operator repair",
          %{table_id: table.id}
        )

        {:error, :base_schema_mismatch}

      {:error, error} ->
        {:error, error}
    end
  end

  def versions(tables) do
    rows =
      BaseRepo.query!(
        "SELECT table_id::text,schema_version,data_version FROM #{BaseRepo.states()} WHERE table_id=ANY($1::text[]::uuid[])",
        [Enum.map(tables, & &1.id)]
      ).rows

    expected = Map.new(tables, &{&1.id, &1.schema_version})

    if length(rows) == length(tables) and
         Enum.all?(rows, fn [id, version, _] -> expected[id] == version end),
       do: {:ok, Enum.map(rows, fn [id, _, version] -> %{id: id, data_version: version} end)},
       else: {:error, :base_schema_mismatch}
  end

  def commit(table, change) do
    [[version, count, next]] =
      BaseRepo.query!(
        """
        UPDATE #{BaseRepo.states()} SET data_version=data_version+1,
          record_count=record_count+$2::bigint,next_auto_number=next_auto_number+$3::bigint
        WHERE table_id=$1::text::uuid RETURNING data_version,record_count,next_auto_number
        """,
        [table.id, change.delta, change.inserted]
      ).rows

    {:ok, %{table | data_version: version, record_count: count, next_auto_number: next}}
  end

  def create_table!(table, fields, records) do
    BaseRepo.ensure_schema!()
    drop!(table)

    columns =
      for field <- fields, stored?(field), do: "#{BaseRepo.column(field.id)} #{sql_type(field)}"

    BaseRepo.query!(
      """
      CREATE TABLE #{BaseRepo.table(table.id)} (
        id uuid PRIMARY KEY,versions jsonb NOT NULL DEFAULT '{}',
        created_by text NOT NULL,created_at timestamptz NOT NULL,
        updated_by text NOT NULL,updated_at timestamptz NOT NULL
        #{if columns == [], do: "", else: "," <> Enum.join(columns, ",")}
      )
      """,
      []
    )

    insert_rows!(table, fields, records)
    for field <- fields, do: index!(table, field)

    BaseRepo.query!(
      "INSERT INTO #{BaseRepo.states()} (table_id,schema_version,data_version,record_count,next_auto_number) VALUES($1::text::uuid,$2,$3,$4,$5)",
      [
        table.id,
        table.schema_version,
        table.data_version,
        table.record_count,
        table.next_auto_number
      ]
    )
  end

  def analyze(shard, ids) do
    BaseRepo.with_shard(shard, fn ->
      for id <- ids do
        case BaseRepo.query("ANALYZE #{BaseRepo.table(id)}", [], timeout: 5_000) do
          {:ok, _} ->
            :ok

          {:error, error} ->
            Ankole.Logging.warning("pod.base.analyze_failed", "Base statistics refresh failed", %{
              table_id: id,
              reason: inspect(error)
            })
        end
      end
    end)
  rescue
    error ->
      Ankole.Logging.warning("pod.base.analyze_failed", "Base statistics refresh failed", %{
        reason: Exception.message(error)
      })
  end

  def index!(table, field) do
    if stored?(field) and (field.is_primary or field.type == :auto_number) do
      collation = if Formula.type(field) == :text, do: " COLLATE \"C\"", else: ""

      BaseRepo.query!(
        "CREATE INDEX \"ix_#{BaseRepo.hex(field.id)}\" ON #{BaseRepo.table(table.id)} (#{BaseRepo.column(field.id)}#{collation})",
        []
      )
    end
  end

  def insert_rows!(_table, _fields, []), do: :ok

  def insert_rows!(table, fields, records) when is_list(records),
    do: insert_rows!(table, fields, {:json, Torque.encode!(Enum.map(records, &wire/1))})

  def insert_rows!(table, fields, {:json, payload}) do
    stored = Enum.filter(fields, &stored?/1)
    columns = Enum.map(stored, &BaseRepo.column(&1.id))
    values = Enum.map(stored, &json_value(&1, "source.data"))

    BaseRepo.query!(
      """
      INSERT INTO #{BaseRepo.table(table.id)} (id,versions,created_by,created_at,updated_by,updated_at#{comma(columns)})
      SELECT id::uuid,versions,created_by,created_at,updated_by,updated_at#{comma(values)}
      FROM jsonb_to_recordset($1::text::jsonb) AS source(
        id text,data jsonb,versions jsonb,created_by text,created_at timestamptz,updated_by text,updated_at timestamptz)
      """,
      [payload]
    )

    :ok
  end

  def save(write, record, :insert, _before_versions) do
    fields = Map.fetch!(write.definitions, record.table_id)
    table = Map.fetch!(write.tables, record.table_id)
    insert_rows!(table, fields, [record])
    {:ok, record}
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :unique_violation and
           error.postgres[:constraint] == "tbl_#{BaseRepo.hex(record.table_id)}_pkey",
         do: {:error, {:record_exists, record.id}},
         else: reraise(error, __STACKTRACE__)
  end

  def save(write, record, :update, before_versions) do
    fields = Map.fetch!(write.definitions, record.table_id)
    table = Map.fetch!(write.tables, record.table_id)

    setters =
      for field <- fields,
          stored?(field),
          record.versions[field.id] != before_versions[field.id],
          do: "#{BaseRepo.column(field.id)}=#{json_value(field, "source.data")}"

    BaseRepo.query!(
      """
      UPDATE #{BaseRepo.table(table.id)} r SET versions=source.versions,
        updated_by=source.updated_by,updated_at=source.updated_at#{comma(setters)}
      FROM jsonb_to_record($1::text::jsonb) AS source(id text,data jsonb,versions jsonb,updated_by text,updated_at timestamptz)
      WHERE r.id=source.id::uuid
      """,
      [Torque.encode!(wire(record))]
    )

    {:ok, record}
  end

  def fetch(table_id, id, fields) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, %{rows: [[record]]}} <-
           BaseRepo.query(
             """
             SELECT jsonb_build_object('id',r.id,'data',#{data_sql(fields)},'versions',r.versions,
               'created_by',r.created_by,'created_at',#{Ankole.Pod.Query.utc_timestamp("r.created_at")},
               'updated_by',r.updated_by,'updated_at',#{Ankole.Pod.Query.utc_timestamp("r.updated_at")})
             FROM #{BaseRepo.table(table_id)} r WHERE r.id=$1::text::uuid
             """,
             [id]
           ),
         do: {:ok, record_struct(table_id, record)},
         else: (
           {:error, _} = error -> error
           _ -> {:error, :not_found}
         )
  end

  def delete(record) do
    BaseRepo.query!("DELETE FROM #{BaseRepo.table(record.table_id)} WHERE id=$1::text::uuid", [
      record.id
    ])

    {:ok, record}
  end

  def drop!(table) do
    # DROP CASCADE removes foreign keys, but not their edge tables.
    edges =
      BaseRepo.query!(
        """
        SELECT DISTINCT relation.relname FROM pg_constraint constraint_row
        JOIN pg_class relation ON relation.oid=constraint_row.conrelid
        JOIN pg_namespace namespace ON namespace.oid=relation.relnamespace
        WHERE constraint_row.contype='f' AND constraint_row.confrelid=to_regclass($1)
          AND namespace.nspname=$2 AND relation.relname LIKE 'lnk_%'
        """,
        [BaseRepo.table(table.id), BaseRepo.tenant_schema!()]
      ).rows

    for [name] <- edges,
        do: BaseRepo.query!("DROP TABLE IF EXISTS #{BaseRepo.edge(name)} CASCADE", [])

    BaseRepo.query!("DROP TABLE IF EXISTS #{BaseRepo.table(table.id)} CASCADE", [])

    if BaseRepo.query!("SELECT to_regclass($1) IS NOT NULL", [BaseRepo.states()]).rows == [[true]] do
      BaseRepo.query!("DELETE FROM #{BaseRepo.states()} WHERE table_id=$1::text::uuid", [table.id])
    end
  end

  def validate_sizes(write, table_id, ids) do
    fields = Map.fetch!(write.definitions, table_id)

    Ecto.Adapters.SQL.stream(
      BaseRepo.get_dynamic_repo(),
      "SELECT data FROM (SELECT #{data_sql(fields)} AS data FROM #{BaseRepo.table(table_id)} r WHERE $1::text[] IS NULL OR r.id=ANY($1::text[]::uuid[])) records WHERE octet_length(data::text) > $2",
      [ids, write.limits["record_bytes"]],
      max_rows: 100
    )
    |> Stream.flat_map(& &1.rows)
    |> Enum.reduce_while(:ok, fn [data], :ok ->
      case Values.record_size(data, write.limits) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def json_value(field, data) do
    operator = if sql_type(field) == "jsonb", do: "->", else: "->>"
    "(#{data}#{operator}'#{field.id}')::#{sql_type(field)}"
  end

  defp comma([]), do: ""
  defp comma(values), do: "," <> Enum.join(values, ",")

  def wire(record) do
    record
    |> Map.take([:id, :data, :versions, :created_by, :created_at, :updated_by, :updated_at])
    |> Map.update!(:created_by, &to_string/1)
    |> Map.update!(:updated_by, &to_string/1)
    |> Map.update!(:created_at, &DateTime.to_iso8601/1)
    |> Map.update!(:updated_at, &DateTime.to_iso8601/1)
  end

  def record_struct(table_id, record) do
    {:ok, created, _} = DateTime.from_iso8601(record["created_at"])
    {:ok, updated, _} = DateTime.from_iso8601(record["updated_at"])
    {:ok, created_by} = Ankole.Ecto.ActorRef.cast(record["created_by"])
    {:ok, updated_by} = Ankole.Ecto.ActorRef.cast(record["updated_by"])

    struct!(Ankole.Pod.BaseRecord, %{
      id: record["id"],
      table_id: table_id,
      tenant_id: Ankole.Repo.tenant_id!(),
      data: record["data"],
      versions: record["versions"],
      created_by: created_by,
      created_at: created,
      updated_by: updated_by,
      updated_at: updated
    })
  end
end
