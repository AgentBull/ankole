defmodule Ankole.Files.Vfs.Exports do
  @moduledoc "Materializes immutable exports outside the table transaction's object-store boundary."
  require Ash.Query
  alias Ankole.{Files, Repo}
  alias Ankole.Files.Schemas.VfsExport

  def materialize(scope, %{export: export} = entry) do
    now = DateTime.utc_now(:microsecond)

    cached =
      VfsExport
      |> Ash.Query.filter(snapshot_key == ^export.key and expires_at > ^now)
      |> Ash.Query.limit(1)
      |> Ankole.Ash.read_one!()

    with {:ok, snapshot} <- if(cached, do: {:ok, cached}, else: generate(scope, entry)),
         {:ok, object} <- Files.fetch_object(snapshot.object_id) do
      {:ok,
       %{
         entry
         | etag: "\"export:#{snapshot.snapshot_key}\"",
           size: object.size,
           content: {:object, object.id, object.size},
           stat_on_lookup: true
       }}
    end
  end

  def materialize(_scope, entry), do: {:ok, entry}

  def expire_in_tx do
    now = DateTime.utc_now(:microsecond)
    VfsExport |> Ash.Query.filter(expires_at <= ^now) |> Ankole.Ash.destroy_where(:remove)
  end

  defp generate(scope, entry) do
    path = Files.temp_path()

    try do
      with {:ok, key} <-
             Repo.transact_top_level(fn ->
               Ankole.Files.Vfs.Base.export_in_tx(scope, entry, path)
             end),
           {:ok, stored} <- Files.store({:file, path}) do
        Repo.transact_top_level(fn ->
          with {:ok, object} <- Files.complete_object_in_tx(stored),
               do:
                 Ankole.Ash.create(VfsExport, :create_in_tx, %{
                   snapshot_key: key,
                   object_id: object.id,
                   expires_at: DateTime.add(DateTime.utc_now(:microsecond), 15, :minute)
                 })
        end)
      end
    after
      File.rm(path)
    end
  end
end
