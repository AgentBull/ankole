defmodule Ankole.Pod.Bases.Schema do
  @moduledoc """
  Changes Base fields and views and converts the stored record values.

  Each change runs in a top-level transaction through `Ankole.Pod.Access.write/3`.
  The write result gives the written definition and the changed tables; the
  table rooms get the change after the commit.
  """
  require Ash.Query
  alias Ankole.Pod.Access
  alias Ankole.Pod.{Bases, BaseField, BaseRepo, BaseTable, BaseView, Formula}
  alias Ankole.Pod.Bases.{DDL, Physical, Write}

  @select_option_colors ~w(brand blue teal purple green orange cyan magenta yellow red gray)

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

  def configure_table(actor, id, attrs) do
    write(actor.turn_authority, fn ->
      schema_write(actor, id, fn write ->
        with {:ok, candidate} <-
               Ankole.Ash.for_update(
                 write.table,
                 :configure,
                 atom_attrs(attrs, [:description, :unique_field_ids, :emit_changes])
               )
               |> Ash.Changeset.apply_attributes(),
             :ok <- description_size(candidate),
             :ok <- validate_unique_fields(candidate, fields(id)),
             :ok <- configure_storage(write, candidate),
             {:ok, table} <-
               Ankole.Ash.update(
                 write.table,
                 :configure,
                 Map.take(candidate, [:description, :unique_field_ids, :emit_changes])
               ) do
          {:ok, table, %{write | table: table, tables: Map.put(write.tables, id, table)}}
        end
      end)
    end)
  end

  @doc "Rejects a table or field description longer than 2 KiB of UTF-8 text."
  def description_size(%{description: description}) when byte_size(description) > 2_048,
    do: {:error, :description_size_limit}

  def description_size(_definition), do: :ok

  defp validate_unique_fields(table, definitions) do
    valid =
      for field <- definitions,
          field.type in [:text, :number, :checkbox, :datetime] or
            (field.type == :select and field.config["multiple"] != true),
          do: field.id

    keys = table.unique_field_ids

    if length(keys) == length(Enum.uniq(keys)) and Enum.all?(keys, &(&1 in valid)),
      do: :ok,
      else: {:error, :invalid_unique_fields}
  end

  defp configure_storage(write, table) do
    check = fn ->
      if table.unique_field_ids != [] and
           Ankole.Pod.Bases.Records.duplicate_keys?(table, fields(table.id)) do
        {:error, :duplicate_unique_key}
      else
        if table.storage_mode == :physical do
          BaseRepo.ensure_outbox!()

          if table.unique_field_ids != write.table.unique_field_ids,
            do: Physical.unique_index!(table)
        end

        {:ok, :ok}
      end
    end

    result =
      if table.storage_mode == :physical,
        do:
          BaseRepo.run(write.shard, check,
            ddl: true,
            deadline: write.deadline,
            timezone: write.timezone
          ),
        else: check.()

    case result do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  defp unique_field_change(table, old, candidate) do
    if old.id in table.unique_field_ids and
         (old.type != candidate.type or
            (old.type == :select and
               old.config["multiple"] == true != (candidate.config["multiple"] == true))),
       do: {:error, :unique_field_referenced},
       else: :ok
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
        |> atom_attrs([:name, :description, :type, :config, :position, :is_primary])
        |> drop_nil_key(:is_primary)
        |> strip_edge_config()
        |> Map.put_new(:is_primary, false)
        |> Map.merge(%{id: Ankole.Ecto.UUIDv7.autogenerate(), table_id: id})
        |> Map.put_new_lazy(:position, fn -> next_schema_position(BaseField, id) end)

      with true <- length(fields(id)) < 200,
           {:ok, candidate} <-
             BaseField
             |> Ankole.Ash.for_create(:create_in_tx, attrs)
             |> Ash.Changeset.apply_attributes(),
           :ok <- description_size(candidate),
           {:ok, candidate} <- Formula.prepare(candidate, fields(id)),
           :ok <- validate_field_config(candidate, table),
           {:ok, candidate, write} <- reverse_field(candidate, write),
           {:ok, checked} <- Formula.validate_all([candidate | fields(id)]),
           :ok <- maybe_demote_primary(id, candidate.is_primary),
           {:ok, field} <-
             Ankole.Ash.create(
               BaseField,
               :create_in_tx,
               Map.take(Enum.find(checked, &(&1.id == candidate.id)), [
                 :id,
                 :table_id,
                 :name,
                 :description,
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
                 attrs
                 |> atom_attrs([:name, :description, :type, :config, :position, :is_primary])
                 |> drop_nil_key(:is_primary)
                 |> strip_edge_config()
               )
               |> Ash.Changeset.apply_attributes(),
             :ok <- primary_field_change(field, candidate),
             :ok <- description_size(candidate),
             :ok <- unique_field_change(table, field, candidate),
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
             :ok <-
               sync_peer_fields(
                 table.id,
                 checked,
                 id,
                 definitions,
                 candidate.is_primary and not field.is_primary
               ),
             {:ok, saved} <-
               Ankole.Ash.update(
                 field,
                 :update_definition,
                 Map.take(candidate, [:name, :description, :position, :type, :config, :is_primary])
               ) do
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
        definitions = fields(table.id)
        field = Enum.find(definitions, &(&1.id == id))

        cond do
          is_nil(field) -> {:error, :not_found}
          field.version != version -> {:error, {:schema_conflict, field}}
          id in table.unique_field_ids -> {:error, :unique_field_referenced}
          length(definitions) <= 1 -> {:error, :primary_field_required}
          Enum.any?(definitions, &Formula.references?(&1, id)) -> {:error, :field_referenced}
          true -> delete_field_in_tx(field, write)
        end
      end)
    end
  end

  defp delete_field_in_tx(field, write) do
    with {:ok, write} <- detach_reverse(field, write),
         {:ok, deleted} <- Ankole.Ash.destroy(field, :remove),
         remaining = fields(field.table_id),
         :ok <- ensure_primary_field(remaining),
         :ok <- scrub_field_from_views(field.table_id, field.id, remaining) do
      {:ok, deleted, write}
    end
  end

  defp primary_field_change(%{is_primary: true}, %{is_primary: false}),
    do: {:error, :primary_field_required}

  defp primary_field_change(_old, _candidate), do: :ok

  defp maybe_demote_primary(_table_id, false), do: :ok

  defp maybe_demote_primary(table_id, true) do
    fields(table_id)
    |> Enum.filter(& &1.is_primary)
    |> Enum.reduce_while(:ok, fn current, :ok ->
      case Ankole.Ash.update(current, :update_definition, %{is_primary: false}) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_primary_field(remaining) do
    if Enum.any?(remaining, & &1.is_primary) do
      :ok
    else
      target = Enum.find(remaining, &(&1.type not in [:attachment, :link])) || hd(remaining)

      case Ankole.Ash.update(target, :update_definition, %{is_primary: true}) do
        {:ok, _} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  defp drop_nil_key(map, key), do: if(is_nil(map[key]), do: Map.delete(map, key), else: map)

  defp scrub_field_from_views(table_id, field_id, remaining) do
    BaseView
    |> Ash.Query.filter(table_id == ^table_id)
    |> Ankole.Ash.read!()
    |> Enum.reduce_while(:ok, fn view, :ok ->
      cleaned = scrub_view_config(view.config, view.type, field_id, remaining)

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

  defp scrub_view_config(config, view_type, field_id, remaining) when is_map(config) do
    config
    |> then(fn map ->
      case map["visible_fields"] do
        visible when is_list(visible) ->
          next = Enum.reject(visible, &(&1 == field_id))

          next =
            if view_type == :grid and visible != [] and next == [] and remaining != [],
              do: [hd(remaining).id],
              else: next

          Map.put(map, "visible_fields", next)

        _ ->
          map
      end
    end)
    |> drop_matching_field("group_field_id", field_id)
    |> drop_matching_field("cover_field_id", field_id)
    |> scrub_chart_config(field_id)
  end

  defp scrub_view_config(config, _view_type, _field_id, _remaining), do: config

  defp drop_matching_field(config, key, field_id) do
    if config[key] == field_id, do: Map.delete(config, key), else: config
  end

  defp scrub_chart_config(%{"chart" => chart} = config, field_id) when is_map(chart),
    do: Map.put(config, "chart", scrub_chart_node(chart, field_id))

  defp scrub_chart_config(config, _field_id), do: config

  defp scrub_chart_node(node, field_id) when is_map(node) do
    node =
      if Map.get(node, "field_id") == field_id do
        node
        |> Map.put("field_id", nil)
        |> Map.put("missing_field_id", field_id)
      else
        node
      end

    Map.new(node, fn {key, value} -> {key, scrub_chart_node(value, field_id)} end)
  end

  defp scrub_chart_node(node, field_id) when is_list(node),
    do: Enum.map(node, &scrub_chart_node(&1, field_id))

  defp scrub_chart_node(node, _field_id), do: node

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
         Enum.all?(options, &valid_select_option?/1) and
         length(Enum.uniq_by(options, & &1["id"])) == length(options),
       do: :ok,
       else: {:error, :invalid_options}
  end

  defp validate_field_config(_field, _table), do: :ok

  defp valid_select_option?(option) when is_map(option) do
    is_binary(option["id"]) and option["id"] != "" and is_binary(option["name"]) and
      valid_option_color?(Map.get(option, "color"))
  end

  defp valid_select_option?(_option), do: false

  defp valid_option_color?(nil), do: true
  defp valid_option_color?(color) when color in @select_option_colors, do: true

  defp valid_option_color?(color) when is_binary(color),
    do: Regex.match?(~r/\A#[0-9a-fA-F]{6}\z/, color)

  defp valid_option_color?(_color), do: false

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

  defp sync_peer_fields(table_id, checked, changed_id, previous, promote?) do
    previous_by_id = Map.new(previous, &{&1.id, &1})

    formula_updates =
      Map.new(
        for field <- checked,
            field.id != changed_id,
            field.type == :formula,
            before = Map.get(previous_by_id, field.id),
            not is_nil(before) and before.config != field.config,
            do: {field.id, field.config}
      )

    if not promote? and map_size(formula_updates) == 0 do
      :ok
    else
      fields(table_id)
      |> Enum.reject(&(&1.id == changed_id))
      |> Enum.reduce_while(:ok, fn current, :ok ->
        changes =
          %{}
          |> then(fn acc ->
            if promote? and current.is_primary, do: Map.put(acc, :is_primary, false), else: acc
          end)
          |> then(fn acc ->
            case Map.fetch(formula_updates, current.id) do
              {:ok, config} -> Map.put(acc, :config, config)
              :error -> acc
            end
          end)

        if map_size(changes) == 0 do
          {:cont, :ok}
        else
          case Ankole.Ash.update(current, :update_definition, changes) do
            {:ok, _} -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
        end
      end)
    end
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
    known = MapSet.new(definitions, & &1.id)
    visible = Map.get(config, "visible_fields", [])

    if is_list(visible) and Enum.all?(visible, &MapSet.member?(known, &1)) do
      refs =
        Enum.flat_map(
          ~w(group_field_id cover_field_id),
          fn key -> if config[key] not in [nil, ""], do: [config[key]], else: [] end
        )

      if Enum.all?(refs, &MapSet.member?(known, &1)),
        do: valid_chart_config(Map.fetch(config, "chart"), known),
        else: {:error, :unknown_field}
    else
      {:error, :invalid_view}
    end
  end

  defp valid_view_config(_, _), do: {:error, :invalid_view}

  defp valid_chart_config(:error, _known), do: :ok

  defp valid_chart_config({:ok, chart}, known) when is_map(chart) and not is_struct(chart),
    do: validate_chart_node(chart, known)

  defp valid_chart_config({:ok, _invalid}, _known), do: {:error, :invalid_view}

  defp validate_chart_node(node, known) when is_map(node) and not is_struct(node) do
    with :ok <- validate_chart_field_slot(node, known) do
      validate_chart_children(Map.values(node), known)
    end
  end

  defp validate_chart_node(node, known) when is_list(node),
    do: validate_chart_children(node, known)

  defp validate_chart_node(_node, _known), do: :ok

  defp validate_chart_children(items, known) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case validate_chart_node(item, known) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_chart_field_slot(node, known) do
    case Map.fetch(node, "field_id") do
      :error ->
        :ok

      {:ok, nil} ->
        if valid_empty_chart_slot?(node), do: :ok, else: {:error, :invalid_view}

      {:ok, id} when is_binary(id) and id != "" ->
        if MapSet.member?(known, id), do: :ok, else: {:error, :unknown_field}

      {:ok, _invalid} ->
        {:error, :invalid_view}
    end
  end

  defp valid_empty_chart_slot?(node) do
    missing = Map.get(node, "missing_field_id")
    op = Map.get(node, "operation")

    (is_binary(missing) and missing != "") or op in ["count", :count]
  end

  defp schema_write(%Ankole.AuthZ.Actor{} = actor, id, fun) do
    with {:ok, write} <- Write.open(actor, id, :manage_schema),
         {:ok, written, write} <- fun.(write),
         {:ok, changed} <- finish_schema(written, Write.touch(write, write.table.id)),
         :ok <- Ankole.Pod.SearchProjection.sync_base_in_tx(write.table.page_id),
         :ok <- Ankole.Brain.base_tables_changed_in_tx(Enum.map(changed, & &1.id)) do
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
