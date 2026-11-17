defmodule Ankole.Brain.Sources do
  @moduledoc """
  Durable lifecycle for registered Brain Sources.

  Source identity, archive state, row locking, and revision writeback live
  here. Each learning path still owns its extraction and projection rules.
  A generic action on `Ankole.Brain.Schemas.Source` owns the transaction of
  an archive or a scope change.
  """

  require Ash.Query

  alias Ankole.Brain.Schemas.{Chunk, Link, Source, Timeline}
  alias Ankole.Brain.Scope
  alias Ankole.Repo

  @spec create(map()) :: {:ok, Source.t()} | {:error, term()}
  def create(attrs) when is_map(attrs), do: Ankole.Ash.create(Source, :register, attrs)

  @spec get_or_create(map()) :: {:ok, Source.t()} | {:error, term()}
  def get_or_create(attrs) when is_map(attrs), do: Ankole.Ash.create(Source, :ensure, attrs)

  @doc "Archives one Source in the caller's transaction, stopping subsequent learning runs."
  @spec archive_in_tx(Ecto.UUID.t()) :: {:ok, Source.t()} | {:error, term()}
  def archive_in_tx(source_id) do
    with :ok <- Repo.require_transaction(),
         {:ok, source} <- mark_archived(source_id) do
      {:ok, source}
    end
  end

  @doc """
  Sets the source node for OIDC Client conversations that have not entered Brain
  yet, in the caller's transaction.
  """
  def update_default_scope_in_tx(source_id, scope) do
    with :ok <- Repo.require_transaction(),
         :ok <- if(is_nil(scope), do: :ok, else: Scope.validate(scope)),
         %Source{} = source <- lock_source(source_id),
         true <- is_nil(source.archived_at),
         true <- source.kind == "oidc_client" or not is_nil(scope) do
      Ankole.Ash.update(source, :set_default_scope, %{default_source_node_id: scope})
    else
      nil -> {:error, :not_found}
      false -> {:error, {:invalid, "source_kind"}}
      {:error, _reason} = error -> error
    end
  end

  defp mark_archived(source_id) do
    case lock_source(source_id) do
      %Source{archived_at: nil} = source ->
        Ankole.Ash.update(source, :archive, %{})

      %Source{} = source ->
        {:ok, source}

      nil ->
        {:error, :not_found}
    end
  end

  @spec ensure_active(Source.t()) ::
          :ok
          | {:error, :source_archived | :source_attention_required | :source_scope_trashed}
  def ensure_active(%Source{archived_at: archived_at}) when not is_nil(archived_at),
    do: {:error, :source_archived}

  def ensure_active(%Source{attention_reason: reason}) when is_binary(reason) and reason != "",
    do: {:error, :source_attention_required}

  def ensure_active(%Source{default_source_node_id: node_id}) when is_binary(node_id) do
    case Ankole.Pod.get_page_record!(node_id, load: [:in_trash]) do
      %{in_trash: true} -> {:error, :source_scope_trashed}
      %{} -> :ok
      nil -> {:error, :source_attention_required}
    end
  end

  def ensure_active(%Source{}), do: :ok

  @doc "Checks whether any active Brain Source uses one of `node_ids` as its default scope."
  def ensure_nodes_not_default_scope_in_tx(node_ids) when is_list(node_ids) do
    sources =
      Source
      |> Ash.Query.filter(is_nil(archived_at) and default_source_node_id in ^node_ids)
      |> Ash.Query.select([:id, :name, :kind])
      |> Ankole.Ash.read!()

    case sources do
      [] ->
        :ok

      referenced ->
        {:error,
         {:brain_source_scope_in_use,
          Enum.map(referenced, &%{id: &1.id, name: &1.name, kind: &1.kind})}}
    end
  end

  @purge_batch_size 1_000

  @doc "Detaches Brain Sources whose default scope nodes are being physically purged."
  def detach_purged_defaults([]), do: :ok

  def detach_purged_defaults(node_ids) when is_list(node_ids) do
    node_ids
    |> Enum.chunk_every(@purge_batch_size)
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case Repo.transact_top_level(fn ->
             with :ok <- detach_purged_defaults_in_tx(batch), do: {:ok, :ok}
           end) do
        {:ok, :ok} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc "Detaches Brain Sources whose default scope node is being physically purged."
  def detach_purged_defaults_in_tx([]), do: Repo.require_transaction()

  def detach_purged_defaults_in_tx(node_ids) when is_list(node_ids) do
    :ok = Repo.require_transaction()

    Source
    |> Ash.Query.filter(default_source_node_id in ^node_ids)
    |> Ankole.Ash.update_where(:flag_scope_purged)
    |> case do
      {:ok, _sources} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec lock_active(Source.t()) :: {:ok, Source.t()} | {:error, term()}
  def lock_active(%Source{id: source_id}) do
    case lock_source(source_id) do
      %Source{} = source ->
        case ensure_active(source) do
          :ok -> {:ok, source}
          {:error, _reason} = error -> error
        end

      nil ->
        {:error, :not_found}
    end
  end

  @spec record_revision(Source.t(), String.t()) :: {:ok, Source.t()} | {:error, term()}
  def record_revision(%Source{} = source, revision) when is_binary(revision),
    do: Ankole.Ash.update(source, :record_revision, %{upstream_revision: revision})

  @spec extraction_watermark(Source.t()) :: non_neg_integer() | nil
  def extraction_watermark(%Source{extracted_through_seq: seq}), do: seq

  def conversation_extraction_watermark(conversation_id) do
    case Source
         |> Ash.Query.filter(kind == "conversation" and upstream_id == ^conversation_id)
         |> Ankole.Ash.read_one!() do
      %Source{} = source -> extraction_watermark(source)
      nil -> nil
    end
  end

  @doc "Rewinds learning when a previously covered public Message changes."
  def invalidate_conversation_message_in_tx(message, now) do
    conversation_id = message.conversation_id

    case Source
         |> Ash.Query.filter(kind == "conversation" and upstream_id == ^conversation_id)
         |> Ash.Query.lock(:for_update)
         |> Ankole.Ash.read_one!() do
      %Source{extracted_through_seq: seq} = source when is_integer(seq) and seq >= message.seq ->
        :ok = withdraw_conversation_projections_in_tx(conversation_id)
        :ok = Ankole.Brain.Claims.withdraw_source_claims_in_tx(source.id, now)

        {:ok, _} =
          Ankole.Ash.update(source, :invalidate_extraction, %{})

        if is_nil(source.archived_at) and Ankole.Brain.Config.enabled?() do
          {:ok, _} = Ankole.Brain.Jobs.ProcessConversationSlice.enqueue(message.conversation_id)
        end

        :ok

      _ ->
        :ok
    end
  end

  defp withdraw_conversation_projections_in_tx(conversation_id) do
    case Scope.conversation(conversation_id) do
      {:ok, root_id} ->
        {:ok, _} =
          Timeline
          |> Ash.Query.filter(source_node_id == ^root_id)
          |> Ankole.Ash.destroy_where(:remove)

        {:ok, _} =
          Chunk
          |> Ash.Query.filter(source_node_id == ^root_id)
          |> Ankole.Ash.destroy_where(:remove_projection)

        {:ok, _} =
          Link
          |> Ash.Query.filter(origin_page_id == ^root_id and link_source == "extraction")
          |> Ankole.Ash.destroy_where(:remove)

        :ok

      {:error, :not_found} ->
        :ok
    end
  end

  @doc "Records a sequence boundary while the caller holds the Source row lock."
  def record_extraction_watermark(%Source{} = source, {%DateTime{} = at, seq})
      when is_integer(seq) and seq >= 0 do
    {:ok, _} =
      Ankole.Ash.update(source, :record_watermark, %{
        extracted_through_at: at,
        extracted_through_seq: seq
      })

    :ok
  end

  defp lock_source(source_id) do
    Source
    |> Ash.Query.filter(id == ^source_id)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
  end
end
