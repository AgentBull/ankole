defmodule Ankole.Brain.Timelines do
  @moduledoc """
  Timeline event writes. Each row owns its audience scope; the host object's
  chunk projection compiles visible rows, so a write reconciles the host's
  chunks in the same transaction.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.Timeline
  alias Ankole.Brain.Scope
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Repo

  @type writer :: String.t() | :system

  @doc """
  Writes one timeline event idempotently: the same object, date, summary,
  and provenance keep one row.
  """
  @spec write_timeline(map(), writer(), keyword()) :: {:ok, Timeline.t()} | {:error, term()}
  def write_timeline(attrs, writer, opts \\ []) when is_map(attrs) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, object} <- Objects.get_by_slug(attrs[:object_slug], repo: repo),
         :ok <- validate_scope(attrs[:audience_scope], writer),
         :ok <- validate_text(attrs[:summary], :summary),
         :ok <- validate_text(attrs[:provenance], :provenance),
         :ok <- validate_date(attrs[:date]) do
      repo.transact(fn repo ->
        with {:ok, object} <- Objects.lock_object_in_tx(repo, object.slug) do
          row = %Timeline{
            id: UUIDv7.autogenerate(),
            object_slug: object.slug,
            author_uid: author_uid(writer, opts),
            date: attrs[:date],
            provenance: attrs[:provenance],
            summary: attrs[:summary],
            detail: attrs[:detail] || "",
            event_object_slug: attrs[:event_object_slug],
            audience_scope: attrs[:audience_scope],
            created_at: DateTime.utc_now(:microsecond)
          }

          case repo.insert_all(Timeline, [Map.take(row, Timeline.__schema__(:fields))],
                 on_conflict: :nothing,
                 conflict_target: [:object_slug, :date, :summary, :provenance],
                 returning: true
               ) do
            {0, []} ->
              existing =
                repo.get_by!(Timeline,
                  object_slug: object.slug,
                  date: attrs[:date],
                  summary: attrs[:summary],
                  provenance: attrs[:provenance]
                )

              {:ok, existing}

            {1, [timeline]} ->
              with {:ok, _object} <- Objects.reconcile_chunks(object, repo: repo) do
                {:ok, timeline}
              end
          end
        end
      end)
    end
  end

  defp validate_scope(scope, :system), do: Scope.validate(scope)

  defp validate_scope(scope, writer_uid) when is_binary(writer_uid),
    do: Scope.validate_writable(scope, writer_uid)

  defp validate_text(value, _field) when is_binary(value) do
    if String.trim(value) == "", do: {:error, :blank_text}, else: :ok
  end

  defp validate_text(_value, field), do: {:error, {:missing, field}}

  defp validate_date(%Date{}), do: :ok
  defp validate_date(_value), do: {:error, :missing_date}

  defp author_uid(:system, opts), do: Keyword.get(opts, :author_uid)
  defp author_uid(writer, _opts) when is_binary(writer), do: writer
end
