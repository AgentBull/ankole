defmodule Ankole.Pod.Bases.Schema do
  @moduledoc """
  Changes Base fields and views and converts the stored record values.

  Each change runs in a top-level transaction through `Ankole.Pod.Access.write/3`.
  The write result gives the written definition and the changed tables; the
  table rooms get the change after the commit.
  """
  require Ash.Query
  alias Ankole.Pod.{Access, Bases, BaseField, BaseRepo, BaseTable, BaseView, Formula}
  alias Ankole.Pod.Bases.{DDL, Physical, Write}

  def delete_table(%Ankole.AuthZ.Actor{} = actor, id, authority \\ nil),
    do: Ankole.Pod.Bases.Delete.table(actor, id, authority || actor.turn_authority)

  def rename_table(%Ankole.AuthZ.Actor{} = actor, id, name, authority \\ nil) do
    write(authority || actor.turn_authority, fn ->
      schema_write(actor, id, fn write ->
        with {:ok, table} <- Ankole.Ash.update(write.table, :rename, %{name: name}),
             do: {:ok, table, write}
      end)
    end)
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
           Access.write(authority, fun, timeout: 60_000, after_commit: &Bases.committed_schema/1),
         do: {:ok, written}
  end

  @doc false
  def create_field_in_tx(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    schema_write(actor, id, fn write ->
      table = write.table

      attrs =
        attrs
        |> atom_attrs([:name, :type, :config, :position])
        |> strip_edge_config()
        |> Map.merge(%{id: Ankole.Ecto.UUIDv7.autogenerate(), table_id: id, is_primary: false})
        |> Map.put_new_lazy(:position, fn -> next_schema_position(BaseField, id) end)

      with true <- length(fields(id)) < 200,
           {:ok, candidate} <-
             BaseField
             |> Ankole.Ash.for_create(:create_in_tx, attrs)
             |> Ash.Changeset.apply_attributes(),
           {:ok, candidate} <- Formula.prepare(candidate, fields(id)),
           :ok <- validate_field_config(candidate, table),
           {:ok, candidate, write} <- reverse_field(candidate, write),
           {:ok, checked} <- Formula.validate_all([candidate | fields(id)]),
           {:ok, field} <-
             Ankole.Ash.create(
               BaseField,
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
      else
        false -> {:error, :field_limit}
        error -> error
      end
    end)
  end

  @doc false
  def update_field_in_tx(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    with {:ok, field} <- field_by_id(id) do
      schema_write(actor, field.table_id, fn write ->
        table = write.table
        definitions = fields(table.id)

        with %BaseField{} = field <- Enum.find(definitions, &(&1.id == id)),
             :ok <- schema_version(field, attrs),
             {:ok, candidate} <-
               Ankole.Ash.for_update(
                 field,
                 :update_definition,
                 strip_edge_config(atom_attrs(attrs, [:name, :type, :config, :position]))
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
             write <-
               prepare_conversion(
                 write,
                 field,
                 candidate,
                 Ankole.Attrs.get(attrs, :clear_invalid, false)
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
        field = Ankole.Ash.read_one!(Ash.Query.filter(BaseField, id == ^id))

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
         :ok <- scrub_field_from_views(field.table_id, field.id),
         {:ok, deleted} <- Ankole.Ash.destroy(field, :remove) do
      {:ok, deleted, write}
    end
  end

  defp scrub_field_from_views(table_id, field_id) do
    BaseView
    |> Ash.Query.filter(table_id == ^table_id)
    |> Ankole.Ash.read!()
    |> Enum.reduce_while(:ok, fn view, :ok ->
      cleaned = scrub_view_config(view.config, field_id)

      if cleaned == view.config do
        {:cont, :ok}
      else
        case Ankole.Ash.update(view, :update_definition, %{config: cleaned}) do
          {:ok, _} -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end
    end)
  end

  defp scrub_view_config(config, field_id) when is_map(config) do
    config
    |> then(fn map ->
      case map["visible_fields"] do
        visible when is_list(visible) ->
          Map.put(map, "visible_fields", Enum.reject(visible, &(&1 == field_id)))

        _ ->
          map
      end
    end)
    |> drop_matching_field("group_field_id", field_id)
    |> drop_matching_field("cover_field_id", field_id)
  end

  defp scrub_view_config(config, _field_id), do: config

  defp drop_matching_field(config, key, field_id) do
    if config[key] == field_id, do: Map.delete(config, key), else: config
  end

  @doc false
  def create_view_in_tx(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    schema_write(actor, id, fn write ->
      attrs =
        atom_attrs(attrs, [:name, :type, :config, :position])
        |> Map.put(:table_id, id)
        |> Map.put_new_lazy(:position, fn -> next_schema_position(BaseView, id) end)

      with :ok <- valid_view_config(Ankole.Attrs.get(attrs, :config, %{}), fields(id)),
           {:ok, view} <- Ankole.Ash.create(BaseView, :create_in_tx, attrs),
           do: {:ok, view, write}
    end)
  end

  @doc false
  def update_view_in_tx(%Ankole.AuthZ.Actor{} = actor, id, attrs) do
    with {:ok, view} <- view_by_id(id) do
      schema_write(actor, view.table_id, fn write ->
        view = Ankole.Ash.read_one!(Ash.Query.filter(BaseView, id == ^id))

        with %BaseView{} <- view,
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
        view = Ankole.Ash.read_one!(Ash.Query.filter(BaseView, id == ^id))

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
         %{page_id: page_id} <-
           Ankole.Ash.read_one!(
             Ash.Query.filter(BaseTable, id == ^target_id and is_nil(deleting_at))
           ),
         true <- page_id == table.page_id,
         :ok <- validate_reverse(field, table) do
      :ok
    else
      _ -> {:error, :cross_base_link}
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
         %BaseField{type: :link} = reverse <-
           Ankole.Ash.read_one!(Ash.Query.filter(BaseField, id == ^reverse_id)),
         true <-
           reverse.table_id == field.config["table_id"] and reverse.config["table_id"] == table.id and
             reverse.config["reverse_field_id"] == field.id,
         do: :ok,
         else: (_ -> {:error, :invalid_reverse_field})
  end

  defp validate_reverse(_field, _table), do: :ok

  defp reverse_field(%{type: :link, config: %{"bidirectional" => true}} = field, write) do
    table = write.table
    field = edge_metadata(field)
    target_id = field.config["table_id"]
    reverse_id = Ankole.Ecto.UUIDv7.autogenerate()
    position = next_schema_position(BaseField, target_id)

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
        "edge_table" => field.config["edge_table"],
        "edge_role" => "dst",
        "table_id" => table.id,
        "reverse_field_id" => field.id,
        "multiple" => true,
        "bidirectional" => true
      }
    }

    with true <- length(fields(target_id)) + if(target_id == table.id, do: 2, else: 1) <= 200,
         {:ok, _} <- Ankole.Ash.create(BaseField, :create_in_tx, attrs) do
      {:ok, %{field | config: Map.put(field.config, "reverse_field_id", reverse_id)},
       Write.touch(write, target_id)}
    else
      false -> {:error, :field_limit}
      error -> error
    end
  end

  defp reverse_field(field, write), do: {:ok, edge_metadata(field), write}

  defp edge_metadata(%{type: :link} = field) do
    %{
      field
      | config:
          field.config
          |> Map.put_new("edge_table", "lnk_" <> Ankole.Pod.BaseRepo.hex(field.id))
          |> Map.put_new("edge_role", "src")
    }
  end

  defp edge_metadata(field), do: field

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
    candidate =
      if old.config["table_id"] == candidate.config["table_id"],
        do: %{
          candidate
          | config: Map.merge(candidate.config, Map.take(old.config, ["edge_table", "edge_role"]))
        },
        else: %{candidate | config: Map.drop(candidate.config, ["edge_table", "edge_role"])}

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
      own_edge = "lnk_" <> Ankole.Pod.BaseRepo.hex(candidate.id)

      split_reverse =
        candidate.type == :link and old_reverse != nil and old.config["edge_table"] == own_edge

      candidate =
        if candidate.type == :link and old_reverse != nil and not split_reverse,
          do: %{
            candidate
            | config:
                candidate.config |> Map.put("edge_table", own_edge) |> Map.put("edge_role", "src")
          },
          else: candidate

      with {:ok, write} <- detach_reverse(old, write, split_reverse),
           {:ok, candidate, write} <- reverse_field(candidate, write),
           do: {:ok, candidate, write}
    end
  end

  defp detach_reverse(field, write, split \\ false)

  defp detach_reverse(%{type: :link, config: %{"reverse_field_id" => id}}, write, split) do
    case Ankole.Ash.read_one!(Ash.Query.filter(BaseField, id == ^id)) do
      nil ->
        {:ok, write}

      reverse ->
        config = Map.drop(reverse.config, ["reverse_field_id", "bidirectional"])

        config =
          if split,
            do:
              config
              |> Map.put("edge_table", "lnk_" <> Ankole.Pod.BaseRepo.hex(reverse.id))
              |> Map.put("edge_role", "src"),
            else: config

        with {:ok, _} <-
               Ankole.Ash.update(reverse, :update_definition, %{
                 config: config
               }) do
          {:ok, Write.touch(write, reverse.table_id)}
        end
    end
  end

  defp detach_reverse(_field, write, _split), do: {:ok, write}

  defp prepare_conversion(write, old, candidate, clear) do
    changed =
      old.type != candidate.type or
        (old.type == :link and link_value_shape(old.config) != link_value_shape(candidate.config)) or
        (old.type == :select and
           (old.config["multiple"] == true != (candidate.config["multiple"] == true) or
              option_ids(old.config) != option_ids(candidate.config)))

    if changed do
      conversion = %{old: old, candidate: candidate, clear: clear == true}
      %{write | conversions: Map.put(write.conversions, old.id, conversion)}
    else
      write
    end
  end

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
          fn key -> if config[key] not in [nil, ""], do: [config[key]], else: [] end
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
         {:ok, changed} <- finish_schema(written, Write.touch(write, write.table.id)) do
      analyze =
        for {_, %{old: old, candidate: candidate}} <- write.conversions,
            old.type != candidate.type,
            {:ok, table} = Bases.fetch_table(old.table_id),
            table.storage_mode == :physical,
            do: old.table_id

      {:ok,
       %{
         written: written,
         changed: changed,
         analyze: %{shard: write.shard, ids: Enum.uniq(analyze)}
       }}
    end
  end

  defp finish_schema(%BaseField{}, write), do: DDL.finish(write)

  defp finish_schema(%type{}, %{table: %{storage_mode: :inline}} = write)
       when type in [BaseView, BaseTable],
       do: Write.finish(write)

  defp finish_schema(%type{}, write) when type in [BaseView, BaseTable] do
    BaseRepo.run(
      write.shard,
      fn ->
        with {:ok, locked} <- Physical.lock_states(write), do: Write.finish(locked)
      end,
      deadline: write.deadline,
      timezone: write.timezone
    )
  end

  defp link_value_shape(config), do: {config["table_id"], config["multiple"] != false}

  defp option_ids(config), do: MapSet.new(config["options"] || [], & &1["id"])

  defp fields(id), do: Bases.fields(id)
  defp field_by_id(id), do: fetch_schema(BaseField, id)
  defp view_by_id(id), do: fetch_schema(BaseView, id)

  defp fetch_schema(schema, id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         item when not is_nil(item) <- Ankole.Ash.read_one!(Ash.Query.filter(schema, id == ^id)),
         do: {:ok, item},
         else: (_ -> {:error, :not_found})
  end

  defp next_schema_position(schema, table_id) do
    (schema |> Ash.Query.filter(table_id == ^table_id) |> Ankole.Ash.max!(:position) || "") <> "U"
  end

  defp strip_edge_config(attrs) do
    if is_map(attrs[:config]),
      do: Map.update!(attrs, :config, &Map.drop(&1, ["edge_table", "edge_role"])),
      else: attrs
  end

  defp atom_attrs(attrs, keys),
    do:
      Map.new(
        for key <- keys,
            Map.has_key?(attrs, key) or Map.has_key?(attrs, to_string(key)),
            do: {key, Ankole.Attrs.get(attrs, key)}
      )
end
