defmodule Ankole.Pod.Bases.Links do
  @moduledoc "Ordered links with native foreign keys and bounded peer notifications."
  Module.register_attribute(__MODULE__, :raw_sql_scope, persist: true)
  @raw_sql_scope :tenant_schema
  alias Ankole.Pod.{BaseRepo, Bases}
  alias Ankole.Pod.Bases.{Physical, Write}

  def expression(field, row) do
    {own, peer} = roles(field)

    "(SELECT jsonb_agg(edge.#{peer}_id ORDER BY edge.#{own}_ord) FROM #{BaseRepo.edge(field.config["edge_table"])} edge WHERE edge.#{own}_id=#{row}.id)"
  end

  def roles(%{config: %{"edge_role" => "src"}}), do: {"src", "dst"}
  def roles(%{config: %{"edge_role" => "dst"}}), do: {"dst", "src"}

  def create!(field) do
    if field.config["edge_role"] == "src" do
      BaseRepo.query!(
        """
        CREATE TABLE #{BaseRepo.edge(field.config["edge_table"])} (
          src_id uuid NOT NULL REFERENCES #{BaseRepo.table(field.table_id)}(id) ON DELETE CASCADE,
          dst_id uuid NOT NULL REFERENCES #{BaseRepo.table(field.config["table_id"])}(id) ON DELETE CASCADE,
          src_ord bigint NOT NULL,dst_ord bigint NOT NULL,PRIMARY KEY(src_id,dst_id)
        )
        """,
        []
      )

      BaseRepo.query!(
        "CREATE INDEX \"ix_rev_#{BaseRepo.hex(field.id)}\" ON #{BaseRepo.edge(field.config["edge_table"])} (dst_id,dst_ord)",
        []
      )
    end
  end

  def maintain(write, fields, before, after_data, id) do
    Enum.reduce_while(Enum.filter(fields, &(&1.type == :link)), {:ok, write}, fn field,
                                                                                 {:ok, write} ->
      old = Map.get(before, field.id, []) || []
      new = Map.get(after_data, field.id, []) || []

      case replace(write, field, id, old, new) do
        {:ok, write} -> {:cont, {:ok, write}}
        error -> {:halt, error}
      end
    end)
  end

  defp replace(write, _field, _id, value, value), do: {:ok, write}

  defp replace(write, field, id, old, new) do
    {own, peer} = roles(field)
    edge = BaseRepo.edge(field.config["edge_table"])
    target = field.config["table_id"]

    [[count]] =
      BaseRepo.query!(
        "SELECT count(*) FROM #{BaseRepo.table(target)} WHERE id=ANY($1::text[]::uuid[])",
        [new]
      ).rows

    with true <- count == length(new),
         :ok <- reverse_capacity(write, field, new -- old) do
      BaseRepo.query!(
        "DELETE FROM #{edge} WHERE #{own}_id=$1::text::uuid AND NOT(#{peer}_id=ANY($2::text[]::uuid[]))",
        [id, new]
      )

      BaseRepo.query!(
        """
        INSERT INTO #{edge} (#{own}_id,#{peer}_id,#{own}_ord,#{peer}_ord)
        SELECT $1::text::uuid, target.id, target.position - 1,
          COALESCE((SELECT max(#{peer}_ord)+1 FROM #{edge} WHERE #{peer}_id=target.id),0)
        FROM unnest($2::text[]::uuid[]) WITH ORDINALITY AS target(id,position)
        ON CONFLICT(src_id,dst_id) DO UPDATE SET #{own}_ord=EXCLUDED.#{own}_ord
        """,
        [id, new]
      )

      reverse_id = field.config["reverse_field_id"]

      if reverse_id do
        reverse = Enum.find(Map.fetch!(write.definitions, target), &(&1.id == reverse_id))
        affected = Enum.uniq((new -- old) ++ (old -- new))
        touch_peers(write, reverse, affected)
      else
        {:ok, write}
      end
    else
      false -> {:error, :invalid_link}
      error -> error
    end
  end

  defp reverse_capacity(_write, _field, []), do: :ok

  defp reverse_capacity(write, field, ids) do
    if reverse_id = field.config["reverse_field_id"] do
      reverse = Enum.find(write.definitions[field.config["table_id"]], &(&1.id == reverse_id))
      {_own, peer} = roles(field)
      limit = if reverse.config["multiple"] == false, do: 1, else: Bases.max_links_per_field()

      rows =
        BaseRepo.query!(
          "SELECT 1 FROM #{BaseRepo.edge(field.config["edge_table"])} WHERE #{peer}_id=ANY($1::text[]::uuid[]) GROUP BY #{peer}_id HAVING count(*) >= $2 LIMIT 1",
          [ids, limit]
        ).rows

      if rows == [], do: :ok, else: {:error, :link_cardinality}
    else
      :ok
    end
  end

  def clean_incoming(write, id) do
    write.definitions
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(&(&1.type == :link and &1.config["table_id"] == write.table.id))
    |> Enum.reduce_while({:ok, write}, fn field, {:ok, write} ->
      {own, peer} = roles(field)

      ids =
        BaseRepo.query!(
          "SELECT DISTINCT #{own}_id::text FROM #{BaseRepo.edge(field.config["edge_table"])} WHERE #{peer}_id=$1::text::uuid LIMIT #{Bases.max_links_per_field() + 1}",
          [id]
        ).rows
        |> List.flatten()

      result =
        if length(ids) > Bases.max_links_per_field(),
          do: {:ok, Write.touch(write, field.table_id, resync: true)},
          else: touch_peers(write, field, ids)

      case result do
        {:ok, write} -> {:cont, {:ok, write}}
        error -> {:halt, error}
      end
    end)
  end

  defp touch_peers(write, _field, []), do: {:ok, write}

  defp touch_peers(write, field, ids) do
    bump_field!(write, field, ids)

    with :ok <- Physical.validate_sizes(write, field.table_id, ids),
         do: {:ok, Write.touch(write, field.table_id, changed: ids)}
  end

  def bump_field!(write, field, ids) do
    author = to_string(Ankole.ActorRef.from_writer(write.uid, Ankole.Repo.tenant_id!(), []))

    BaseRepo.query!(
      """
      UPDATE #{BaseRepo.table(field.table_id)} SET
        versions=jsonb_set(versions,ARRAY[$2::text],to_jsonb(COALESCE((versions->>$2::text)::bigint,0)+1)),
        updated_by=$3,updated_at=now() WHERE id=ANY($1::text[]::uuid[])
      """,
      [ids, field.id, author]
    )
  end

  def initialize_field(write, field) do
    {own, _peer} = roles(field)

    BaseRepo.query!(
      """
      UPDATE #{BaseRepo.table(field.table_id)} r SET versions=jsonb_set(versions,ARRAY[$1::text],'1'::jsonb)
      WHERE NOT versions ? $1::text AND EXISTS(SELECT 1 FROM #{BaseRepo.edge(field.config["edge_table"])} e WHERE e.#{own}_id=r.id)
      """,
      [field.id]
    )

    Physical.validate_sizes(write, field.table_id, nil)
  end

  def remove_constraints(fields, table_ids) do
    for field <- fields, field.table_id in table_ids do
      {own, _} = roles(field)

      BaseRepo.query!(
        "ALTER TABLE #{BaseRepo.edge(field.config["edge_table"])} DROP CONSTRAINT IF EXISTS #{own}_single",
        []
      )
    end
  end

  def constrain(fields, table_ids) do
    Enum.reduce_while(fields, :ok, fn field, :ok ->
      if field.table_id in table_ids do
        {own, _} = roles(field)
        limit = if field.config["multiple"] == false, do: 1, else: Bases.max_links_per_field()

        rows =
          BaseRepo.query!(
            "SELECT 1 FROM #{BaseRepo.edge(field.config["edge_table"])} GROUP BY #{own}_id HAVING count(*) > $1 LIMIT 1",
            [limit]
          ).rows

        if rows == [] do
          if limit == 1,
            do:
              BaseRepo.query!(
                "ALTER TABLE #{BaseRepo.edge(field.config["edge_table"])} ADD CONSTRAINT #{own}_single UNIQUE(#{own}_id)",
                []
              )

          {:cont, :ok}
        else
          {:halt, {:error, :link_cardinality}}
        end
      else
        {:cont, :ok}
      end
    end)
  end
end
