defmodule Ankole.Pod.Applets.Bindings do
  @moduledoc "Resolves every logical table slot against one effective table and its current fields."
  require Ash.Query
  alias Ankole.{Files, Repo}
  alias Ankole.Pod.{Access, AppletBinding, BaseField, BaseTable, Pages}

  @types ~w(text number select datetime checkbox user attachment auto_number link formula created_at updated_at created_by updated_by)
  @max_bytes 65_536

  def parse_manifest(nil), do: {:ok, %{"tables" => %{}}}

  def parse_manifest(bytes) when is_binary(bytes) and byte_size(bytes) <= @max_bytes do
    with {:ok, %{"tables" => tables} = manifest} when is_map(tables) <- Torque.decode(bytes),
         true <- Map.keys(manifest) == ["tables"],
         true <- Enum.all?(tables, &valid_slot?/1),
         do: {:ok, manifest},
         else: (_ -> {:error, :invalid_bindings_manifest})
  end

  def parse_manifest(_), do: {:error, :invalid_bindings_manifest}

  defp valid_slot?({key, spec}) when is_binary(key) and key != "" and is_map(spec) do
    Enum.all?(Map.keys(spec), &(&1 in ~w(tableId required description fields))) and
      optional_uuid?(spec["tableId"]) and optional_boolean?(spec["required"]) and
      optional_string?(spec["description"]) and is_map(spec["fields"] || %{}) and
      Enum.all?(spec["fields"] || %{}, &valid_field?/1)
  end

  defp valid_slot?(_), do: false

  defp valid_field?({key, spec}) when is_binary(key) and key != "" and is_map(spec) do
    Enum.all?(Map.keys(spec), &(&1 in ~w(fieldId type description))) and
      optional_uuid?(spec["fieldId"]) and optional_string?(spec["description"]) and
      (is_nil(spec["type"]) or spec["type"] in @types)
  end

  defp valid_field?(_), do: false
  defp optional_uuid?(nil), do: true
  defp optional_uuid?(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp optional_boolean?(value), do: is_nil(value) or is_boolean(value)
  defp optional_string?(value), do: is_nil(value) or is_binary(value)

  def from_object(page_id, nil), do: resolve(page_id, %{"tables" => %{}})

  def from_object(page_id, object_id) do
    with {:ok, bytes} <- Files.read_object(object_id),
         {:ok, manifest} <- parse_manifest(bytes),
         do: resolve(page_id, manifest)
  end

  def manifest(page_id) do
    case Ankole.Pod.Files.fetch_file(page_id, "applet.bindings.json") do
      {:ok, file} ->
        with {:ok, bytes} <- Files.read_object(file.object_id), do: parse_manifest(bytes)

      {:error, :not_found} ->
        parse_manifest(nil)

      error ->
        error
    end
  end

  @doc false
  def snapshot_in_tx(%{type: :applet, id: page_id}) do
    case Ankole.Pod.Files.fetch_file(page_id, "applet.bindings.json") do
      {:ok, file} -> {:applet, file.object_id, overrides(page_id)}
      _ -> {:applet, nil, %{}}
    end
  end

  def snapshot_in_tx(_page), do: :not_applet

  @doc false
  def detail_from_snapshot(_page, :not_applet),
    do: {:ok, %{bindings: %{}, bindings_digest: digest(%{})}}

  def detail_from_snapshot(_page, {:applet, nil, _overrides}),
    do: {:ok, %{bindings: %{}, bindings_digest: digest(%{})}}

  def detail_from_snapshot(%{id: page_id}, {:applet, object_id, override_rows}) do
    manifest =
      with {:ok, bytes} <- Files.read_object(object_id),
           {:ok, parsed} <- parse_manifest(bytes) do
        parsed
      else
        _ -> %{"tables" => %{}}
      end

    resolve(page_id, manifest, override_rows)
  end

  @doc "Returns runtime descriptors and their deterministic digest for a parsed source manifest."
  def resolve(page_id, manifest, override_rows \\ nil)

  def resolve(_page_id, %{"tables" => tables}, _override_rows) when map_size(tables) == 0 do
    {:ok, %{bindings: %{}, bindings_digest: digest(%{})}}
  end

  def resolve(page_id, %{"tables" => tables}, override_rows) do
    override_rows = override_rows || overrides(page_id)
    {live_tables, fields_by_table} = preload_bound_tables(tables, override_rows)

    bindings =
      Map.new(tables, fn {slot, spec} ->
        {slot, resolve_slot(spec, override_rows[slot], live_tables, fields_by_table)}
      end)

    {:ok, %{bindings: bindings, bindings_digest: digest(bindings)}}
  end

  defp preload_bound_tables(tables, override_rows) do
    candidate_ids =
      tables
      |> Enum.flat_map(fn {slot, spec} ->
        override = Map.get(override_rows, slot)
        raw_id = (override && override.table_id) || spec["tableId"]

        with true <- is_binary(raw_id),
             {:ok, id} <- Ecto.UUID.cast(raw_id) do
          [id]
        else
          _ -> []
        end
      end)
      |> Enum.uniq()

    if candidate_ids == [] do
      {%{}, %{}}
    else
      loaded =
        BaseTable
        |> Ash.Query.filter(id in ^candidate_ids and is_nil(deleting_at))
        |> Ankole.Ash.read!()

      live_page_ids =
        loaded
        |> Enum.map(& &1.page_id)
        |> Enum.uniq()
        |> Enum.filter(&Ankole.Pod.page_live?/1)
        |> MapSet.new()

      live_tables =
        for table <- loaded,
            MapSet.member?(live_page_ids, table.page_id),
            into: %{},
            do: {table.id, table}

      live_table_ids = Map.keys(live_tables)

      fields_by_table =
        if live_table_ids == [] do
          %{}
        else
          BaseField
          |> Ash.Query.filter(table_id in ^live_table_ids)
          |> Ash.Query.sort(:position)
          |> Ankole.Ash.read!()
          |> Enum.group_by(& &1.table_id)
        end

      {live_tables, fields_by_table}
    end
  end

  defp resolve_slot(spec, override, live_tables, fields_by_table) do
    table_id = (override && override.table_id) || spec["tableId"]
    declared = spec["fields"] || %{}

    base = %{
      tableId: table_id,
      required: spec["required"] == true,
      description: spec["description"]
    }

    if is_binary(table_id) and Map.has_key?(live_tables, table_id) do
      fields = Map.get(fields_by_table, table_id, [])

      mapped =
        Map.new(declared, fn {key, field} ->
          explicit = override && override.field_overrides[key]

          id =
            cond do
              is_binary(explicit) -> explicit
              table_id == spec["tableId"] -> field["fieldId"]
              true -> unique_named_field(fields, key, field["type"])
            end

          match = Enum.find(fields, &(&1.id == id and matching_type?(&1, field["type"])))
          {key, match && match.id}
        end)

      missing =
        mapped
        |> Enum.filter(fn {_key, id} -> is_nil(id) end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()

      Map.merge(base, %{
        fields: mapped,
        missing: missing,
        status: if(missing == [], do: "ready", else: "missing_fields")
      })
    else
      Map.merge(base, %{
        tableId: nil,
        fields: Map.new(declared, fn {key, _} -> {key, nil} end),
        missing: Enum.sort(Map.keys(declared)),
        status: "missing_table"
      })
    end
  end

  defp unique_named_field(fields, name, type) do
    case Enum.filter(fields, &(&1.name == name and matching_type?(&1, type))) do
      [field] -> field.id
      _ -> nil
    end
  end

  defp matching_type?(_field, nil), do: true
  defp matching_type?(field, type), do: to_string(field.type) == type

  def digest(bindings) do
    bindings
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {slot, value} ->
      [
        slot,
        [
          value.tableId,
          value.fields |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(fn {key, id} -> [key, id] end)
        ]
      ]
    end)
    |> Torque.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def detail(%{type: :applet, id: page_id}) do
    with {:ok, manifest} <- manifest(page_id), do: resolve(page_id, manifest)
  end

  def detail(_), do: {:ok, %{bindings: %{}, bindings_digest: digest(%{})}}

  def list(actor, page_id) do
    snapshot =
      Repo.transact_top_level(fn ->
        with {:ok, page} <- Pages.lock(page_id, :share),
             {:ok, _} <- Access.authorize(actor, page, "node_edit", trash: false),
             :ok <- require_applet(page) do
          object_id =
            case Ankole.Pod.Files.fetch_file(page_id, "applet.bindings.json") do
              {:ok, file} -> file.object_id
              {:error, :not_found} -> nil
            end

          {:ok, {object_id, overrides(page_id)}}
        end
      end)

    with {:ok, {object_id, override_rows}} <- snapshot,
         {:ok, manifest} <- read_manifest_object(object_id),
         {:ok, resolved} <- resolve(page_id, manifest, override_rows) do
      {:ok,
       Map.merge(resolved, %{
         manifest: manifest,
         overrides:
           Map.new(override_rows, fn {key, row} ->
             {key, Map.take(row, [:table_id, :field_overrides])}
           end)
       })}
    end
  end

  defp read_manifest_object(nil), do: parse_manifest(nil)

  defp read_manifest_object(object_id) do
    with {:ok, bytes} <- Files.read_object(object_id), do: parse_manifest(bytes)
  end

  def put(actor, page_id, slot, attrs) do
    Access.write(
      actor.turn_authority,
      fn ->
        with {:ok, page} <- Pages.lock(page_id),
             {:ok, _} <- Access.authorize(actor, page, "node_edit", trash: false),
             :ok <- require_applet(page),
             {:ok, manifest} <- manifest(page_id),
             true <- Map.has_key?(manifest["tables"], slot),
             table_id = Ankole.Attrs.get(attrs, :table_id),
             fields = Ankole.Attrs.get(attrs, :field_overrides, %{}),
             true <-
               optional_uuid?(table_id) and is_map(fields) and
                 Enum.all?(fields, fn {key, id} ->
                   is_binary(key) and is_binary(id) and optional_uuid?(id)
                 end),
             :ok <- authorize_bound_table(actor, table_id),
             {:ok, _} <-
               Ankole.Ash.create(AppletBinding, :put_in_tx, %{
                 page_id: page_id,
                 slot_key: slot,
                 table_id: table_id,
                 field_overrides: fields,
                 updated_by: Ankole.AuthZ.Actor.uid(actor)
               }),
             {:ok, resolved} <- resolve(page_id, manifest) do
          {:ok, Map.put(resolved, :page_id, page_id)}
        else
          false -> {:error, :invalid_binding}
          error -> error
        end
      end,
      after_commit: &Ankole.Pod.Files.committed/1
    )
  end

  def delete(actor, page_id, slot) do
    Access.write(
      actor.turn_authority,
      fn ->
        with {:ok, page} <- Pages.lock(page_id),
             {:ok, _} <- Access.authorize(actor, page, "node_edit", trash: false),
             :ok <- require_applet(page),
             {:ok, _} <-
               Ankole.Ash.destroy_where(
                 Ash.Query.filter(AppletBinding, page_id == ^page_id and slot_key == ^slot),
                 :remove
               ),
             {:ok, resolved} <- detail(page) do
          {:ok, Map.put(resolved, :page_id, page_id)}
        end
      end,
      after_commit: &Ankole.Pod.Files.committed/1
    )
  end

  defp authorize_bound_table(_actor, nil), do: :ok

  defp authorize_bound_table(actor, table_id) do
    with {:ok, _table} <- Ankole.Pod.Bases.table_access(actor, table_id, :read), do: :ok
  end

  defp require_applet(%{type: :applet}), do: :ok
  defp require_applet(_), do: {:error, :invalid_page_type}

  defp overrides(page_id),
    do:
      AppletBinding
      |> Ash.Query.filter(page_id == ^page_id)
      |> Ankole.Ash.read!()
      |> Map.new(&{&1.slot_key, &1})
end
