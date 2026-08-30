defmodule Ankole.Brain.Sources do
  @moduledoc """
  Durable lifecycle for registered Brain Sources.

  Source identity, archive state, row locking, and revision writeback live
  here. Each learning path still owns its extraction and projection rules.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.LibraryKnowledge
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Repo

  @doc "Lists Sources for the Console read model."
  @spec list_for_console(keyword()) :: [Source.t()]
  def list_for_console(opts) when is_list(opts) do
    limit = Keyword.fetch!(opts, :limit)

    Source
    |> order_by([source], desc: source.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec create(map()) :: {:ok, Source.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    %Source{}
    |> Source.changeset(attrs)
    |> Repo.insert()
  end

  @spec get_or_create(map()) :: {:ok, Source.t()} | {:error, term()}
  def get_or_create(attrs) when is_map(attrs) do
    changeset = Source.changeset(%Source{}, attrs)

    with {:ok, normalized} <- Ecto.Changeset.apply_action(changeset, :validate) do
      case Repo.get_by(Source, kind: normalized.kind, upstream_id: normalized.upstream_id) do
        %Source{} = source ->
          {:ok, source}

        nil ->
          case Repo.insert(changeset) do
            {:ok, source} ->
              {:ok, source}

            {:error, reason} ->
              case Repo.get_by(Source,
                     kind: normalized.kind,
                     upstream_id: normalized.upstream_id
                   ) do
                %Source{} = source -> {:ok, source}
                nil -> {:error, reason}
              end
          end
      end
    end
  end

  @spec archive(Ecto.UUID.t()) :: {:ok, Source.t()} | {:error, term()}
  def archive(source_id) do
    with {:ok, source} <- mark_archived(source_id) do
      :ok = maybe_withdraw_library(source)
      {:ok, source}
    end
  end

  defp mark_archived(source_id) do
    case Repo.get(Source, source_id) do
      %Source{archived_at: nil} = source ->
        source
        |> Source.changeset(%{archived_at: DateTime.utc_now(:microsecond)})
        |> Repo.update()

      %Source{} = source ->
        {:ok, source}

      nil ->
        {:error, :not_found}
    end
  end

  defp maybe_withdraw_library(%Source{kind: "library"} = source),
    do: LibraryKnowledge.withdraw_archived_source(source)

  defp maybe_withdraw_library(%Source{}), do: :ok

  @spec ensure_active(Source.t()) :: :ok | {:error, :source_archived}
  def ensure_active(%Source{archived_at: nil}), do: :ok
  def ensure_active(%Source{}), do: {:error, :source_archived}

  @spec lock_active(module(), Source.t()) :: {:ok, Source.t()} | {:error, term()}
  def lock_active(repo, %Source{id: source_id}) do
    Source
    |> where([source], source.id == ^source_id)
    |> lock("FOR UPDATE")
    |> repo.one()
    |> case do
      %Source{} = source ->
        case ensure_active(source) do
          :ok -> {:ok, source}
          {:error, _reason} = error -> error
        end

      nil ->
        {:error, :not_found}
    end
  end

  @spec record_revision(module(), Source.t(), String.t()) ::
          {:ok, Source.t()} | {:error, Ecto.Changeset.t()}
  def record_revision(repo, %Source{} = source, revision) when is_binary(revision) do
    source
    |> Source.changeset(%{
      upstream_revision: revision,
      last_sync_at: DateTime.utc_now(:microsecond)
    })
    |> repo.update()
  end
end
