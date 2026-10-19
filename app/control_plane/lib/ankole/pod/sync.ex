defmodule Ankole.Pod.Sync do
  @moduledoc "One-way external data bindings, executed by their existing AutomationJob."

  import Ecto.Query

  alias Ankole.AutomationJobs.Schemas.{Job, Run}

  alias Ankole.Pod.{
    Access,
    Config,
    Database,
    DbField,
    DbRecord,
    DbSyncBinding,
    DbTable,
    Values
  }

  alias Ankole.Pod.Database.{Records, Write}
  alias Ankole.Principals.WorkAccess
  alias Ankole.Repo

  def list(uid, table_id) do
    with {:ok, _table} <- Database.table_access(uid, table_id, "page_view") do
      {:ok, Repo.all(from b in DbSyncBinding, where: b.table_id == ^table_id)}
    end
  end

  def create(uid, table_id, attrs, authority \\ nil) do
    Repo.assert_outside_transaction!()

    result =
      Access.write_transaction(authority, fn repo ->
        with {:ok, job} <- own_job(uid, Ankole.Attrs.get(attrs, :automation_job_id), true),
             :ok <- WorkAccess.check_attrs_in_tx(repo, Map.from_struct(job)),
             {:ok, write} <- Write.open(uid, table_id),
             :ok <- field_map(table_id, Ankole.Attrs.get(attrs, :field_map)),
             {:ok, binding} <-
               %DbSyncBinding{}
               |> DbSyncBinding.changeset(%{
                 table_id: table_id,
                 connector: Ankole.Attrs.get(attrs, :connector),
                 source: Ankole.Attrs.get(attrs, :source),
                 field_map: Ankole.Attrs.get(attrs, :field_map),
                 automation_job_id: job.id,
                 status: :active,
                 created_by: Ankole.ActorRef.from_writer(uid, Repo.tenant_id!(), []),
                 created_at: DateTime.utc_now()
               })
               |> repo.insert(),
             {:ok, changed} <- Write.finish(Write.touch(write, table_id)) do
          {:ok, {binding, changed}}
        end
      end)

    case result do
      {:ok, {binding, changed}} ->
        Database.broadcast_schema(changed)
        {:ok, binding}

      error ->
        error
    end
  end

  @doc false
  def release_agent_bindings_in_tx(repo, uid) do
    # Use the same Job -> Binding -> Table order as a running sync attempt.
    job_ids =
      repo.all(from j in Job, where: j.agent_uid == ^uid, order_by: j.id, lock: "FOR UPDATE")
      |> Enum.map(& &1.id)

    bindings =
      repo.all(
        from b in DbSyncBinding,
          where: b.automation_job_id in ^job_ids,
          order_by: b.id,
          lock: "FOR UPDATE"
      )

    table_ids = Enum.map(bindings, & &1.table_id) |> Enum.uniq()

    tables =
      repo.all(from t in DbTable, where: t.id in ^table_ids, order_by: t.id, lock: "FOR UPDATE")
      |> Map.new(&{&1.id, &1})

    binding_ids = Enum.map(bindings, & &1.id)
    repo.delete_all(from b in DbSyncBinding, where: b.id in ^binding_ids)

    write = Enum.reduce(table_ids, %Write{tables: tables}, &Write.touch(&2, &1))
    Write.finish(write)
  end

  @doc false
  def broadcast_released_bindings(changed), do: Database.broadcast_schema(changed)

  def set_status(uid, id, status, authority \\ nil)

  def set_status(uid, id, status, authority) when status in ["active", "paused"] do
    Access.write_transaction(authority, fn repo ->
      with {:ok, id} <- Ecto.UUID.cast(id),
           %DbSyncBinding{} = binding <- repo.get(DbSyncBinding, id),
           {:ok, _table} <- Database.table_access(uid, binding.table_id, "page_edit") do
        binding |> DbSyncBinding.changeset(%{status: status}) |> repo.update()
      else
        nil -> {:error, :not_found}
        :error -> {:error, :not_found}
        error -> error
      end
    end)
  end

  def set_status(_uid, _id, _status, _authority), do: {:error, :invalid_sync_status}

  @doc false
  def source_batch_bytes(uid, binding_id) do
    Repo.transact(fn repo ->
      with {:ok, binding_id} <- Ecto.UUID.cast(binding_id),
           %DbSyncBinding{status: :active} = binding <- repo.get(DbSyncBinding, binding_id),
           {:ok, _} <- Database.table_access(uid, binding.table_id, "page_edit"),
           {:ok, job} <- own_job(uid, binding.automation_job_id),
           :ok <- WorkAccess.check_attrs_in_tx(repo, Map.from_struct(job)),
           {:ok, limits} <- Config.limits() do
        # The source keys may be longer than stored UUID keys. Include their
        # actual JSON encoding and the worst-case escaping of each external ID.
        key_bytes =
          byte_size(Torque.encode!(Map.new(binding.field_map, fn {key, _id} -> {key, nil} end)))

        {:ok, 2 + 200 * (limits["record_bytes"] + key_bytes + 1024 * 6 + 128)}
      else
        :error -> {:error, :not_found}
        nil -> {:error, :not_found}
        {:error, _} = error -> error
        _ -> {:error, :sync_attempt_not_authorized}
      end
    end)
  end

  def apply_attempt(uid, binding_id, run_id, attempt_id, rows, cursor) do
    Repo.assert_outside_transaction!()

    result =
      Repo.transact(fn repo ->
        with %Run{} = snapshot <- repo.get(Run, run_id),
             %Job{} = job <-
               repo.one(
                 from j in Job, where: j.id == ^snapshot.automation_job_id, lock: "FOR UPDATE"
               ),
             %Run{status: "running", attempt_id: ^attempt_id} <-
               repo.one(from r in Run, where: r.id == ^run_id, lock: "FOR UPDATE"),
             true <- job.agent_uid == uid and job.status == "active",
             :ok <- WorkAccess.check_attrs_in_tx(repo, Map.from_struct(job)),
             %DbSyncBinding{status: :active, automation_job_id: job_id} = binding <-
               repo.one(from b in DbSyncBinding, where: b.id == ^binding_id, lock: "FOR UPDATE"),
             true <- job_id == job.id,
             {:ok, table} <- Database.table_access(uid, binding.table_id, "page_edit"),
             {:ok, records} <- map_rows(binding, rows),
             {:ok, written} <- write_records(repo, uid, table.id, binding, records),
             {:ok, _binding} <- update_cursor(repo, binding, cursor) do
          {:ok, Map.put(written, :table_id, table.id)}
        else
          {:error, _reason} = error -> error
          _ -> {:error, :sync_attempt_not_authorized}
        end
      end)

    case result do
      {:ok, %{table_id: id} = written} ->
        Database.broadcast_result(id, written)
        {:ok, written}

      error ->
        error
    end
  end

  defp own_job(uid, id, lock \\ false) do
    id =
      case id do
        value when is_integer(value) ->
          value

        value when is_binary(value) ->
          case Integer.parse(value) do
            {value, ""} -> value
            _ -> nil
          end

        _ ->
          nil
      end

    job =
      if id do
        query = from j in Job, where: j.id == ^id
        query = if lock, do: from(j in query, lock: "FOR UPDATE"), else: query
        Repo.one(query)
      end

    case job do
      %Job{agent_uid: ^uid, status: "active"} = job -> {:ok, job}
      _ -> {:error, :invalid_sync_job}
    end
  end

  defp field_map(table_id, map) when is_map(map) and map_size(map) > 0 do
    fields = Repo.all(from f in DbField, where: f.table_id == ^table_id)
    mapped = Map.values(map)

    editable =
      MapSet.new(
        Enum.reject(
          fields,
          &(&1.type in [
              :formula,
              :auto_number,
              :created_at,
              :updated_at,
              :created_by,
              :updated_by
            ])
        ),
        & &1.id
      )

    if Enum.all?(Map.keys(map), &(is_binary(&1) and &1 != "")) and
         length(Enum.uniq(mapped)) == length(mapped) and
         Enum.all?(mapped, &MapSet.member?(editable, &1)),
       do: :ok,
       else: {:error, :invalid_field_map}
  end

  defp field_map(_table_id, _map), do: {:error, :invalid_field_map}

  defp map_rows(binding, rows) when is_list(rows) and length(rows) <= 200 do
    Enum.reduce_while(rows, {:ok, []}, fn
      row, {:ok, acc} when is_map(row) ->
        id = Ankole.Attrs.get(row, :external_id)
        values = Ankole.Attrs.get(row, :data)

        if is_binary(id) and byte_size(id) in 1..1024 and is_map(values) do
          data =
            Map.new(binding.field_map, fn {source, field_id} ->
              {field_id, Map.get(values, source)}
            end)

          {:cont, {:ok, [%{external_id: id, data: data} | acc]}}
        else
          {:halt, {:error, :invalid_external_record}}
        end

      _row, _acc ->
        {:halt, {:error, :invalid_external_record}}
    end)
    |> case do
      {:ok, records} ->
        if length(Enum.uniq_by(records, & &1.external_id)) == length(records),
          do: {:ok, Enum.reverse(records)},
          else: {:error, :duplicate_external_id}

      error ->
        error
    end
  end

  defp map_rows(_binding, _rows), do: {:error, :sync_batch_too_large}

  defp update_cursor(_repo, binding, :unchanged), do: {:ok, binding}

  defp update_cursor(repo, binding, cursor) when is_map(cursor) or is_nil(cursor),
    do: binding |> Ecto.Changeset.change(cursor: cursor) |> repo.update()

  defp update_cursor(_repo, _binding, _cursor), do: {:error, :invalid_sync_cursor}

  defp write_records(repo, uid, id, binding, records) do
    with {:ok, write} <- Write.open(uid, id),
         true <- binding.table_id == id and binding.status == :active,
         definitions <- Database.fields(id),
         mapped <- Map.values(binding.field_map),
         write <- Write.allow(write, id, mapped),
         existing <-
           Repo.all(
             from r in DbRecord,
               where: r.table_id == ^id and r.external_id in ^Enum.map(records, & &1.external_id)
           )
           |> Map.new(&{&1.external_id, &1}),
         {:ok, payload, inserted} <- sync_payload(records, existing, write, definitions, mapped),
         author <- to_string(Ankole.ActorRef.from_writer(uid, Repo.tenant_id!(), [])),
         {:ok, returned} <-
           repo.query(
             """
             MERGE INTO db_records AS target
             USING jsonb_to_recordset($3::text::jsonb) AS source(id text, external_id text, data jsonb, versions jsonb, auto_values jsonb)
             ON target.tenant_id=$1::text::uuid AND target.table_id=$2::text::uuid AND target.external_id=source.external_id
             WHEN MATCHED THEN UPDATE SET data=(target.data-$5::text[]) || source.data,
               versions=target.versions || source.versions,updated_by=$4::text,updated_at=now()
             WHEN NOT MATCHED THEN INSERT (tenant_id,table_id,id,external_id,data,versions,created_by,created_at,updated_by,updated_at)
               VALUES ($1::text::uuid,$2::text::uuid,source.id::uuid,source.external_id,source.data || source.auto_values,source.versions,$4::text,now(),$4::text,now())
             RETURNING target.id::text
             """,
             [Repo.tenant_id!(), id, Torque.encode!(payload), author, mapped]
           ),
         ids <- Enum.map(returned.rows, &hd/1),
         write <- Write.touch(write, id, changed: ids, delta: inserted, inserted: inserted),
         {:ok, write} <- sync_links(write, definitions, records, existing),
         {:ok, changes} <- Write.finish(write),
         {:ok, projected} <- Records.project(write.table, definitions, ids) do
      {:ok, Write.result(changes, id) |> Map.put(:records, projected)}
    else
      false -> {:error, :invalid_sync_binding}
      error -> error
    end
  end

  defp sync_payload(records, existing, write, definitions, mapped) do
    table = write.table

    Enum.reduce_while(records, {:ok, [], 0}, fn attrs, {:ok, payload, inserted} ->
      before = existing[attrs.external_id]

      with true <- Enum.all?(Map.keys(attrs.data), &(&1 in mapped)),
           {:ok, patch} <- Values.patch(attrs.data, definitions, table.page_id),
           autos <-
             Map.new(
               for field <- definitions,
                   field.type == :auto_number and is_nil(before),
                   do: {field.id, table.next_auto_number + inserted}
             ),
           merged <-
             Map.merge(if(before, do: before.data, else: %{}), Map.merge(patch, autos))
             |> Write.clean(),
           :ok <- Write.writable(write, table.id, Map.keys(attrs.data)),
           :ok <- Write.record_size(merged, write.limits) do
        versions =
          Map.new(Map.keys(patch) ++ Map.keys(autos), fn key ->
            {key, if(before, do: Map.get(before.versions, key, 0) + 1, else: 1)}
          end)

        row = %{
          id: if(before, do: before.id, else: Ankole.Ecto.UUIDv7.autogenerate()),
          external_id: attrs.external_id,
          data: Write.clean(patch),
          versions: versions,
          auto_values: autos
        }

        {:cont, {:ok, [row | payload], inserted + if(before, do: 0, else: 1)}}
      else
        false -> {:halt, {:error, :invalid_sync_field}}
        error -> {:halt, error}
      end
    end)
  end

  defp sync_links(write, definitions, records, existing) do
    links = Enum.filter(definitions, &(&1.type == :link and &1.config["reverse_field_id"]))
    records = if links == [], do: [], else: records

    Enum.reduce_while(records, {:ok, write}, fn attrs, {:ok, write} ->
      after_record =
        Repo.get_by!(DbRecord, table_id: write.table.id, external_id: attrs.external_id)

      before = existing[attrs.external_id]

      case Records.maintain_links(
             write,
             links,
             if(before, do: before.data, else: %{}),
             after_record.data,
             after_record.id
           ) do
        {:ok, write} -> {:cont, {:ok, write}}
        error -> {:halt, error}
      end
    end)
  end
end
