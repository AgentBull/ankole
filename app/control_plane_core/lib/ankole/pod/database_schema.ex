defmodule Ankole.Pod.Database.Schema do
  @moduledoc """
  Changes Database fields and views and converts the stored record values.

  Each change runs in a top-level transaction through `Ankole.Pod.Access.write/3`.
  The write result gives the written definition and the changed tables; the
  table rooms get the change after the commit.
  """
  import Ecto.Query
  require Ash.Query
  alias Ankole.{ActorRef, Repo}
  alias Ankole.Pod.{Access, Database, DbField, DbRecord, DbTable, DbView, Formula, Values}
  alias Ankole.Pod.Database.{Records, Write}

  def delete_table(%Ankole.AuthZ.Actor{} = actor, id, authority \\ nil) do
    authority = authority || actor.turn_authority

    Access.write(authority, fn -> delete_table_in_tx(actor, id) end,
      after_commit: fn table ->
        Database.broadcast_schema([%{id: table.id, data_version: table.data_version + 1}])
      end
    )
  end

  @doc false
  def delete_table_in_tx(%Ankole.AuthZ.Actor{} = actor, id) do
    with {:ok, write} <- Write.open(actor, id, :delete_table) do
      referenced =
        Enum.any?(Map.keys(write.tables) -- [id], fn table_id ->
          Enum.any?(fields(table_id), &(&1.type == :link and &1.config["table_id"] == id))
        end)

      if referenced,
        do: {:error, :table_referenced},
        else: Ankole.Ash.destroy(write.table, :remove)
    end
  end

  def create_field(%Ankole.AuthZ.Actor{} = actor, id, attrs, authority \\ nil) do
    authority = authority || actor.turn_authority
    write(authority, fn -> create_field_in_tx(actor, id, attrs) end)
  end

  def update_field(%Ankole.AuthZ.Actor{} = actor, id, attrs, authority \\ nil) do
    authority = authority || actor.turn_authority
    write(authority, fn -> update_field_in_tx(actor, id, attrs) end)
  end

  def delete_field(%Ankole.AuthZ.Actor{} = actor, id, version, authority \\ nil) do
    authority = authority || actor.turn_authority
    write(authority, fn -> delete_field_in_tx(actor, id, version) end)
  end

  def create_view(%Ankole.AuthZ.Actor{} = actor, id, attrs, authority \\ nil) do
    authority = authority || actor.turn_authority
    write(authority, fn -> create_view_in_tx(actor, id, attrs) end)
  end

  def update_view(%Ankole.AuthZ.Actor{} = actor, id, attrs, authority \\ nil) do
    authority = authority || actor.turn_authority
    write(authority, fn -> update_view_in_tx(actor, id, attrs) end)
  end

  def delete_view(%Ankole.AuthZ.Actor{} = actor, id, version, authority \\ nil) do
    authority = authority || actor.turn_authority
    write(authority, fn -> delete_view_in_tx(actor, id, version) end)
  end

  defp write(authority, fun) do
    with {:ok, %{written: written}} <-
           Access.write(authority, fun, after_commit: &Database.committed_schema/1),
         do: {:ok, written}
  end

  @doc false
  def create_field_in_tx(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    schema_write(actor, id, fn write ->
      table = write.table

      attrs =
        attrs
        |> atom_attrs([:name, :type, :config, :position])
        |> Map.merge(%{id: Ankole.Ecto.UUIDv7.autogenerate(), table_id: id, is_primary: false})
        |> Map.put_new_lazy(:position, fn -> next_schema_position(DbField, id) end)

      with {:ok, candidate} <-
             DbField
             |> Ankole.Ash.for_create(:create_in_tx, attrs)
             |> Ash.Changeset.apply_attributes(),
           {:ok, candidate} <- Formula.prepare(candidate, fields(id)),
           :ok <- validate_field_config(candidate, table),
           {:ok, candidate, write} <- reverse_field(candidate, write),
           {:ok, checked} <- Formula.validate_all([candidate | fields(id)]),
           {:ok, field} <-
             Ankole.Ash.create(
               DbField,
               :create_in_tx,
               Map.take(Enum.find(checked, &(&1.id == candidate.id)), [
                 :id,
                 :table_id,
                 :name,
                 :position,
                 :type,
                 :config,
                 :is_primary
               ])
             ) do
        {:ok, field, write}
      end
    end)
  end

  @doc false
  def update_field_in_tx(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    uid = Ankole.AuthZ.Actor.uid(actor)

    with {:ok, field} <- field_by_id(id) do
      schema_write(actor, field.table_id, fn write ->
        table = write.table
        definitions = fields(table.id)

        with %DbField{} = field <- Enum.find(definitions, &(&1.id == id)),
             :ok <- schema_version(field, attrs),
             {:ok, candidate} <-
               Ankole.Ash.for_update(
                 field,
                 :update_definition,
                 atom_attrs(attrs, [:name, :type, :config, :position])
               )
               |> Ash.Changeset.apply_attributes(),
             candidate <- carry_reverse(field, candidate),
             {:ok, candidate} <-
               prepare_changed_formula(field, candidate, definitions, attrs),
             :ok <- validate_field_config(candidate, table),
             {:ok, checked} <-
               Formula.validate_all(replace_definition(definitions, id, candidate)),
             checked <- Formula.refresh_sources(checked, field, candidate),
             candidate <- Enum.find(checked, &(&1.id == id)),
             {:ok, write} <-
               convert_records(
                 write,
                 field,
                 candidate,
                 Ankole.Attrs.get(attrs, :clear_invalid, false),
                 uid
               ),
             {:ok, candidate, write} <- transition_link(write, field, candidate),
             {:ok, saved} <-
               Ankole.Ash.update(
                 field,
                 :update_definition,
                 Map.take(candidate, [:name, :position, :type, :config])
               ) do
          persist_formula_metadata(checked, id, definitions)

          {:ok, saved, write}
        else
          nil -> {:error, :not_found}
          error -> error
        end
      end)
    end
  end

  @doc false
  def delete_field_in_tx(%Ankole.AuthZ.Actor{} = actor, id, version) do
    with {:ok, field} <- field_by_id(id) do
      schema_write(actor, field.table_id, fn write ->
        table = write.table
        field = Ankole.Ash.read_one!(Ash.Query.filter(DbField, id == ^id))

        cond do
          is_nil(field) -> {:error, :not_found}
          field.version != version -> {:error, {:schema_conflict, field}}
          field.is_primary -> {:error, :primary_field_required}
          Enum.any?(fields(table.id), &Formula.references?(&1, id)) -> {:error, :field_referenced}
          true -> delete_field_in_tx(field, write)
        end
      end)
    end
  end

  defp delete_field_in_tx(field, write) do
    with {:ok, write} <- detach_reverse(field, write),
         {:ok, deleted} <- Ankole.Ash.destroy(field, :remove) do
      remove_field_values(field)
      {:ok, deleted, write}
    end
  end

  @doc false
  def create_view_in_tx(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    schema_write(actor, id, fn write ->
      attrs =
        atom_attrs(attrs, [:name, :type, :config, :position])
        |> Map.put(:table_id, id)
        |> Map.put_new_lazy(:position, fn -> next_schema_position(DbView, id) end)

      with :ok <- valid_view_config(Ankole.Attrs.get(attrs, :config, %{}), fields(id)),
           {:ok, view} <- Ankole.Ash.create(DbView, :create_in_tx, attrs),
           do: {:ok, view, write}
    end)
  end

  @doc false
  def update_view_in_tx(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    with {:ok, view} <- view_by_id(id) do
      schema_write(actor, view.table_id, fn write ->
        view = Ankole.Ash.read_one!(Ash.Query.filter(DbView, id == ^id))

        with %DbView{} <- view,
             :ok <- schema_version(view, attrs),
             :ok <-
               valid_view_config(
                 Ankole.Attrs.get(attrs, :config, view.config),
                 fields(view.table_id)
               ) do
          with {:ok, saved} <-
                 Ankole.Ash.update(
                   view,
                   :update_definition,
                   atom_attrs(attrs, [:name, :type, :config, :position])
                 ),
               do: {:ok, saved, write}
        else
          nil -> {:error, :not_found}
          error -> error
        end
      end)
    end
  end

  @doc false
  def delete_view_in_tx(%Ankole.AuthZ.Actor{} = actor, id, version) do
    with {:ok, view} <- view_by_id(id) do
      schema_write(actor, view.table_id, fn write ->
        view = Ankole.Ash.read_one!(Ash.Query.filter(DbView, id == ^id))

        cond do
          is_nil(view) ->
            {:error, :not_found}

          view.version == version ->
            with({:ok, deleted} <- Ankole.Ash.destroy(view, :remove), do: {:ok, deleted, write})

          true ->
            {:error, {:schema_conflict, view}}
        end
      end)
    end
  end

  defp validate_field_config(%{type: :link} = field, table) do
    with true <-
           Enum.all?(
             ~w(multiple bidirectional),
             &(not Map.has_key?(field.config, &1) or is_boolean(field.config[&1]))
           ),
         {:ok, target_id} <- Ecto.UUID.cast(field.config["table_id"]),
         %{page_id: page_id} <- Ankole.Ash.read_one!(Ash.Query.filter(DbTable, id == ^target_id)),
         true <- page_id == table.page_id,
         :ok <- validate_reverse(field, table) do
      :ok
    else
      _ -> {:error, :cross_database_link}
    end
  end

  defp validate_field_config(%{type: :select, config: config}, _table) do
    options = config["options"] || []

    if (not Map.has_key?(config, "multiple") or is_boolean(config["multiple"])) and
         is_list(options) and
         Enum.all?(options, fn option ->
           is_map(option) and is_binary(option["id"]) and option["id"] != "" and
             is_binary(option["name"])
         end) and length(Enum.uniq_by(options, & &1["id"])) == length(options),
       do: :ok,
       else: {:error, :invalid_options}
  end

  defp validate_field_config(_field, _table), do: :ok

  defp validate_reverse(%{config: %{"reverse_field_id" => reverse_id}} = field, table) do
    with {:ok, reverse_id} <- Ecto.UUID.cast(reverse_id),
         %DbField{type: :link} = reverse <-
           Ankole.Ash.read_one!(Ash.Query.filter(DbField, id == ^reverse_id)),
         true <-
           reverse.table_id == field.config["table_id"] and reverse.config["table_id"] == table.id and
             reverse.config["reverse_field_id"] == field.id,
         do: :ok,
         else: (_ -> {:error, :invalid_reverse_field})
  end

  defp validate_reverse(_field, _table), do: :ok

  defp reverse_field(%{type: :link, config: %{"bidirectional" => true}} = field, write) do
    table = write.table
    target_id = field.config["table_id"]
    reverse_id = Ankole.Ecto.UUIDv7.autogenerate()
    position = next_schema_position(DbField, target_id)

    # A new self-link reserves its forward position before the field is inserted.
    position =
      if target_id == table.id, do: max(position, field.position <> "U"), else: position

    attrs = %{
      id: reverse_id,
      table_id: target_id,
      name:
        unique_field_name(
          target_id,
          field.config["reverse_name"] || table.name <> " " <> field.name
        ),
      type: :link,
      position: position,
      config: %{
        "table_id" => table.id,
        "reverse_field_id" => field.id,
        "multiple" => true,
        "bidirectional" => true
      }
    }

    with {:ok, _} <- Ankole.Ash.create(DbField, :create_in_tx, attrs) do
      {:ok, %{field | config: Map.put(field.config, "reverse_field_id", reverse_id)},
       Write.touch(write, target_id)}
    end
  end

  defp reverse_field(field, write), do: {:ok, field, write}

  defp unique_field_name(table_id, name) do
    names = MapSet.new(Enum.map(fields(table_id), & &1.name))

    if MapSet.member?(names, name),
      do:
        Enum.find_value(2..100_000, fn index ->
          candidate = "#{name} (#{index})"
          if not MapSet.member?(names, candidate), do: candidate
        end),
      else: name
  end

  defp carry_reverse(%{type: :link} = old, %{type: :link} = candidate) do
    if candidate.config["bidirectional"] == false do
      %{candidate | config: Map.delete(candidate.config, "reverse_field_id")}
    else
      if old.config["table_id"] == candidate.config["table_id"] and
           is_binary(old.config["reverse_field_id"]) and
           candidate.config["bidirectional"] == true,
         do: %{
           candidate
           | config: Map.put(candidate.config, "reverse_field_id", old.config["reverse_field_id"])
         },
         else: candidate
    end
  end

  defp carry_reverse(_old, candidate), do: candidate

  defp transition_link(write, old, candidate) do
    old_reverse = if old.type == :link, do: old.config["reverse_field_id"]
    new_reverse = if candidate.type == :link, do: candidate.config["reverse_field_id"]

    if old_reverse == new_reverse and not is_nil(new_reverse) do
      {:ok, candidate, write}
    else
      with {:ok, write} <- detach_reverse(old, write),
           {:ok, candidate, write} <- reverse_field(candidate, write),
           do: populate_reverse(write, candidate)
    end
  end

  defp populate_reverse(write, %{type: :link, config: %{"reverse_field_id" => id}} = candidate)
       when is_binary(id) do
    from(r in DbRecord,
      where: r.table_id == ^write.table.id,
      select: %{id: r.id, value: fragment("?->?::text", r.data, ^candidate.id)}
    )
    |> Repo.stream(max_rows: 200)
    |> Enum.reduce_while({:ok, candidate, write}, fn record, {:ok, candidate, write} ->
      case Records.maintain_links(
             write,
             [candidate],
             %{},
             %{candidate.id => record.value || []},
             record.id
           ) do
        {:ok, write} -> {:cont, {:ok, candidate, write}}
        error -> {:halt, error}
      end
    end)
  end

  defp populate_reverse(write, candidate), do: {:ok, candidate, write}

  defp detach_reverse(%{type: :link, config: %{"reverse_field_id" => id}}, write) do
    case Ankole.Ash.read_one!(Ash.Query.filter(DbField, id == ^id)) do
      nil ->
        {:ok, write}

      reverse ->
        with {:ok, _} <-
               Ankole.Ash.update(reverse, :update_definition, %{
                 config: Map.drop(reverse.config, ["reverse_field_id", "bidirectional"])
               }) do
          {:ok, Write.touch(write, reverse.table_id)}
        end
    end
  end

  defp detach_reverse(_field, write), do: {:ok, write}

  defp convert_records(write, old, candidate, clear, _uid) do
    changed =
      old.type != candidate.type or
        (old.type == :link and link_value_shape(old.config) != link_value_shape(candidate.config)) or
        (old.type == :select and
           (old.config["multiple"] == true != (candidate.config["multiple"] == true) or
              option_ids(old.config) != option_ids(candidate.config)))

    cond do
      not changed ->
        {:ok, write}

      candidate.type == :formula ->
        remove_field_values(old)
        {:ok, write}

      true ->
        convert_values(write, old, candidate, clear)
    end
  end

  defp convert_values(write, old, candidate, clear) do
    with {:ok, expr, _type, params} <-
           Formula.expression(old, fields(write.table.id), [Repo.tenant_id!(), write.table.id]) do
      {where, params} =
        if old.type == :formula or Formula.readonly?(old) do
          {"TRUE", params}
        else
          {key, params} = Formula.bind(params, old.id)
          {"jsonb_exists(r.data,#{key}::text)", params}
        end

      # Read the value and the data required for the final byte check in one
      # cursor. A conversion never materializes a table of DbRecord structs.
      Ecto.Adapters.SQL.stream(
        Repo,
        "SELECT r.id::text,to_jsonb(#{expr}),r.data FROM db_records r WHERE r.tenant_id=$1::text::uuid AND r.table_id=$2::text::uuid AND #{where}",
        params,
        max_rows: 200
      )
      |> Stream.flat_map(& &1.rows)
      |> Stream.chunk_every(200)
      |> Enum.reduce_while({:ok, write, []}, fn rows, {:ok, write, invalid} ->
        converted =
          Enum.map(rows, fn [id, value, data] ->
            {id, Values.convert(candidate, value, write.table.page_id), data}
          end)

        invalid = invalid ++ for {id, {:error, _}, _data} <- converted, do: id

        converted =
          if old.type == :select and candidate.type == :select and
               old.config["multiple"] == candidate.config["multiple"],
             do:
               Enum.filter(converted, fn {_id, result, _data} -> match?({:error, _}, result) end),
             else: converted

        converted =
          if clear == true,
            do: converted,
            else: Enum.filter(converted, fn {_id, result, _data} -> match?({:ok, _}, result) end)

        case persist_conversion(write, old, candidate, converted) do
          {:ok, write} -> {:cont, {:ok, write, invalid}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, write, []} -> {:ok, write}
        {:ok, write, _invalid} when clear == true -> {:ok, write}
        {:ok, _write, invalid} -> {:error, {:conversion_failed, invalid}}
        error -> error
      end
    end
  end

  defp persist_conversion(write, _old, _candidate, []), do: {:ok, write}

  defp persist_conversion(write, old, candidate, converted) do
    payload =
      Enum.map(converted, fn {id, result, _data} ->
        value =
          case result do
            {:ok, value} -> value
            _ -> nil
          end

        %{id: id, value: value}
      end)

    with :ok <-
           Enum.reduce_while(Enum.zip(converted, payload), :ok, fn {{_, _, data}, row}, :ok ->
             case Write.record_size(
                    Map.put(data, old.id, row.value) |> Write.clean(),
                    write.limits
                  ) do
               :ok -> {:cont, :ok}
               error -> {:halt, error}
             end
           end),
         {:ok, _} <-
           Repo.query(
             """
             UPDATE db_records r SET data=jsonb_strip_nulls((r.data-$3::text)||jsonb_build_object($3::text,source.value)),
               versions=jsonb_set(r.versions,ARRAY[$3::text],to_jsonb(COALESCE((r.versions->>$3::text)::bigint,0)+1)),
               updated_at=now(),updated_by=$5::text
             FROM jsonb_to_recordset($4::text::jsonb) AS source(id text,value jsonb)
             WHERE r.tenant_id=$1::text::uuid AND r.table_id=$2::text::uuid AND r.id=source.id::uuid
             """,
             [
               Repo.tenant_id!(),
               write.table.id,
               old.id,
               Torque.encode!(payload),
               to_string(ActorRef.from_writer(write.uid, Repo.tenant_id!(), []))
             ]
           ) do
      if old.type == :link and candidate.type == :link and
           old.config["table_id"] == candidate.config["table_id"] and
           old.config["reverse_field_id"] == candidate.config["reverse_field_id"] do
        Enum.zip(converted, payload)
        |> Enum.reduce_while({:ok, write}, fn {{id, _, before}, row}, {:ok, write} ->
          case Records.maintain_links(
                 write,
                 [old],
                 before,
                 Map.put(before, old.id, row.value) |> Write.clean(),
                 id
               ) do
            {:ok, write} -> {:cont, {:ok, write}}
            error -> {:halt, error}
          end
        end)
      else
        {:ok, write}
      end
    end
  end

  defp remove_field_values(field),
    do:
      Repo.query!(
        "UPDATE db_records SET data=data-$3::text,versions=versions-$3::text WHERE tenant_id=$1::text::uuid AND table_id=$2::text::uuid",
        [Repo.tenant_id!(), field.table_id, field.id]
      )

  defp replace_definition(definitions, id, candidate),
    do: Enum.map(definitions, fn field -> if field.id == id, do: candidate, else: field end)

  defp persist_formula_metadata(fields, changed_id, previous) do
    previous = Map.new(previous, &{&1.id, &1})

    fields
    |> Enum.filter(&(&1.id != changed_id and &1.type == :formula))
    |> Enum.each(fn field ->
      before = Map.fetch!(previous, field.id)

      if before.config != field.config do
        {:ok, _field} = Ankole.Ash.update(before, :update_definition, %{config: field.config})
      end
    end)
  end

  defp prepare_changed_formula(old, candidate, definitions, attrs) do
    if candidate.type == :formula and
         (old.type != :formula or Map.has_key?(attrs, :config) or Map.has_key?(attrs, "config")),
       do: Formula.prepare(candidate, definitions),
       else: {:ok, candidate}
  end

  defp schema_version(item, attrs),
    do:
      if(Ankole.Attrs.get(attrs, :version) == item.version,
        do: :ok,
        else: {:error, {:schema_conflict, item}}
      )

  defp valid_view_config(config, definitions) when is_map(config) do
    known = Enum.map(definitions, & &1.id)
    visible = Map.get(config, "visible_fields", [])

    if is_list(visible) and Enum.all?(visible, fn id -> id in known end) do
      refs =
        Enum.flat_map(
          ~w(group_field_id cover_field_id),
          fn key -> if config[key], do: [config[key]], else: [] end
        )

      if Enum.all?(refs, &(&1 in known)), do: :ok, else: {:error, :unknown_field}
    else
      {:error, :invalid_view}
    end
  end

  defp valid_view_config(_, _), do: {:error, :invalid_view}

  defp schema_write(%Ankole.AuthZ.Actor{} = actor, id, fun) do
    with {:ok, write} <- Write.open(actor, id, :manage_schema),
         {:ok, written, write} <- fun.(write),
         {:ok, changed} <- Write.finish(Write.touch(write, write.table.id)) do
      {:ok, %{written: written, changed: changed}}
    end
  end

  defp link_value_shape(config), do: {config["table_id"], config["multiple"] != false}

  defp option_ids(config), do: MapSet.new(config["options"] || [], & &1["id"])

  defp fields(id), do: Database.fields(id)
  defp field_by_id(id), do: fetch_schema(DbField, id)
  defp view_by_id(id), do: fetch_schema(DbView, id)

  defp fetch_schema(schema, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         item when not is_nil(item) <- Ankole.Ash.read_one!(Ash.Query.filter(schema, id == ^id)),
         do: {:ok, item},
         else: (_ -> {:error, :not_found})
  end

  defp next_schema_position(schema, table_id) do
    (schema |> Ash.Query.filter(table_id == ^table_id) |> Ankole.Ash.max!(:position) || "") <> "U"
  end

  defp atom_attrs(attrs, keys),
    do:
      Map.new(
        for key <- keys,
            Map.has_key?(attrs, key) or Map.has_key?(attrs, to_string(key)),
            do: {key, Ankole.Attrs.get(attrs, key)}
      )
end
