defmodule Ankole.Brain.Sources do
  @moduledoc """
  Durable lifecycle for registered Brain Sources.

  Source identity, archive state, row locking, and revision writeback live
  here. Each learning path still owns its extraction and projection rules.
  A generic action on `Ankole.Brain.Schemas.Source` owns the transaction of
  an archive or a scope change.
  """

  require Ash.Query

  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Brain.Scope
  alias Ankole.Repo

  @doc "Lists Sources for the Console read model."
  @spec list_for_console(keyword()) :: [Source.t()]
  def list_for_console(opts) when is_list(opts) do
    limit = Keyword.fetch!(opts, :limit)

    Source
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ankole.Ash.read!()
  end

  @spec create(map()) :: {:ok, Source.t()} | {:error, term()}
  def create(attrs) when is_map(attrs), do: Ankole.Ash.create(Source, :register, attrs)

  @spec get_or_create(map()) :: {:ok, Source.t()} | {:error, term()}
  def get_or_create(attrs) when is_map(attrs), do: Ankole.Ash.create(Source, :ensure, attrs)

  @doc "Archives one Source in the caller's transaction and withdraws its Library pages."
  @spec archive_in_tx(Ecto.UUID.t()) :: {:ok, Source.t()} | {:error, term()}
  def archive_in_tx(source_id) do
    with :ok <- Repo.require_transaction(Repo),
         {:ok, source} <- mark_archived(source_id) do
      if source.kind == "library",
        do: Objects.withdraw_library_projection(source, [])

      {:ok, source}
    end
  end

  @doc """
  Sets the audience for OIDC Client conversations that have not entered Brain
  yet, in the caller's transaction.
  """
  def update_default_scope_in_tx(source_id, scope) do
    with :ok <- Repo.require_transaction(Repo),
         :ok <- if(is_nil(scope), do: :ok, else: Scope.validate(scope)),
         {:ok, source} <- lock_active(Repo, %Source{id: source_id}),
         true <- source.kind == "oidc_client" do
      Ankole.Ash.update(source, :set_default_scope, %{default_audience_scope: scope})
    else
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

  @spec ensure_active(Source.t()) :: :ok | {:error, :source_archived}
  def ensure_active(%Source{archived_at: nil}), do: :ok
  def ensure_active(%Source{}), do: {:error, :source_archived}

  @spec lock_active(module(), Source.t()) :: {:ok, Source.t()} | {:error, term()}
  def lock_active(_repo, %Source{id: source_id}) do
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

  @spec record_revision(module(), Source.t(), String.t()) :: {:ok, Source.t()} | {:error, term()}
  def record_revision(_repo, %Source{} = source, revision) when is_binary(revision),
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
  def invalidate_conversation_message_in_tx(repo, message, now) do
    conversation_id = message.conversation_id

    case Source
         |> Ash.Query.filter(kind == "conversation" and upstream_id == ^conversation_id)
         |> Ash.Query.lock(:for_update)
         |> Ankole.Ash.read_one!() do
      %Source{extracted_through_seq: seq} = source when is_integer(seq) and seq >= message.seq ->
        :ok = Ankole.Brain.Claims.withdraw_source_claims_in_tx(repo, source.id, now)

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

  @doc "Records a sequence boundary while the caller holds the Source row lock."
  def record_extraction_watermark(_repo, %Source{} = source, {%DateTime{} = at, seq})
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
