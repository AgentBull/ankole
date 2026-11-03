defmodule Ankole.Brain.Timelines do
  @moduledoc "Writes immutable events whose visibility follows their source node."

  alias Ankole.Brain.Schemas.Timeline
  alias Ankole.Brain.Scope
  alias Ankole.Repo

  @type writer :: String.t() | :system

  @doc """
  Writes one timeline event idempotently: the same subject, source, date, summary,
  and provenance keep one row.
  """
  @spec write_timeline(map(), writer(), keyword()) :: {:ok, Timeline.t()} | {:error, term()}
  def write_timeline(attrs, writer, opts \\ []) when is_map(attrs),
    do: Repo.transact_top_level(fn -> write_timeline_in_tx(attrs, writer, opts) end)

  @doc """
  Writes one timeline event in the caller's transaction.

  A subject is optional; the source node always determines visibility.
  """
  @spec write_timeline_in_tx(map(), writer(), keyword()) ::
          {:ok, Timeline.t()} | {:error, term()}
  def write_timeline_in_tx(attrs, writer, opts \\ []) when is_map(attrs) do
    with :ok <- Repo.require_transaction(),
         :ok <- validate_subject(attrs[:subject_page_id]),
         :ok <- validate_scope(attrs[:source_node_id], writer),
         :ok <- validate_text(attrs[:summary], :summary),
         :ok <- validate_text(attrs[:provenance], :provenance),
         :ok <- validate_date(attrs[:date]) do
      row = %{
        subject_page_id: attrs[:subject_page_id],
        author: Ankole.ActorRef.from_writer(writer, Repo.tenant_id!(), opts),
        date: attrs[:date],
        provenance: attrs[:provenance],
        summary: attrs[:summary],
        detail: attrs[:detail] || "",
        event_page_id: attrs[:event_page_id],
        source_node_id: attrs[:source_node_id],
        created_at: DateTime.utc_now(:microsecond)
      }

      with {:ok, timeline} <- Ankole.Ash.create(Timeline, :record, row),
           {:ok, _} <-
             Ankole.Brain.Chunks.reconcile_node_in_tx(
               timeline.subject_page_id || timeline.source_node_id
             ),
           do: {:ok, timeline}
    end
  end

  defp validate_subject(nil), do: :ok

  defp validate_subject(id) do
    case Ankole.Brain.Objects.get_by_slug(id) do
      {:ok, %{deleted_at: nil}} -> :ok
      _ -> {:error, :not_found}
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
end
