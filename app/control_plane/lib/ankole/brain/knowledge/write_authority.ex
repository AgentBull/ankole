defmodule Ankole.Brain.Knowledge.WriteAuthority do
  @moduledoc "Explicit evidence and mutation authority for one Knowledge write batch."

  alias Ankole.Brain.Citations
  alias Ankole.Brain.Sources

  @enforce_keys [:mode]
  defstruct [:mode, allowed_document_ids: MapSet.new()]

  @type mode :: :human | :agent | :dreaming | :source_learning | :mechanical
  @type t :: %__MODULE__{mode: mode(), allowed_document_ids: MapSet.t(String.t())}

  @spec build(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def build(%{kind: :human}, _opts), do: {:ok, %__MODULE__{mode: :human}}

  def build(%{kind: :agent}, opts) do
    case Keyword.get(opts, :write_context, :agent) do
      :agent ->
        {:ok, %__MODULE__{mode: :agent}}

      {:source_learning, document_id} when is_binary(document_id) ->
        {:ok,
         %__MODULE__{
           mode: :source_learning,
           allowed_document_ids: MapSet.new([document_id])
         }}

      _invalid ->
        {:error, :invalid_write_context}
    end
  end

  def build(%{kind: :dreaming}, opts) do
    case Keyword.get(opts, :write_context) do
      {:dreaming, document_ids} when is_list(document_ids) ->
        if Enum.all?(document_ids, &is_binary/1) do
          {:ok,
           %__MODULE__{
             mode: :dreaming,
             allowed_document_ids: MapSet.new(document_ids)
           }}
        else
          {:error, :invalid_write_context}
        end

      nil ->
        {:ok, %__MODULE__{mode: :dreaming}}

      _invalid ->
        {:error, :invalid_write_context}
    end
  end

  def build(%{kind: nil}, _opts), do: {:ok, %__MODULE__{mode: :mechanical}}
  def build(_actor, _opts), do: {:error, :invalid_write_authority}

  @spec authorize_operation(t(), String.t(), map()) :: :ok | {:error, term()}
  def authorize_operation(%__MODULE__{mode: :source_learning} = authority, operation, attrs) do
    [document_id] = MapSet.to_list(authority.allowed_document_ids)

    case operation do
      "create_entry" ->
        with :ok <- source_learning_create_fields(attrs) do
          require_source_citation(attrs, :initial_body, document_id)
        end

      operation when operation in ["append_block", "edit_block"] ->
        require_source_citation(attrs, :body, document_id)

      operation ->
        {:error, {:source_learning_operation_not_allowed, operation}}
    end
  end

  def authorize_operation(%__MODULE__{}, _operation, _attrs), do: :ok

  @spec authorize_citation(t(), Sources.resolved()) :: :ok | {:error, term()}
  def authorize_citation(%__MODULE__{mode: :human}, _source), do: :ok

  def authorize_citation(%__MODULE__{mode: :source_learning} = authority, source) do
    if MapSet.member?(authority.allowed_document_ids, source.document_id) and
         source.kind == :retained_source do
      :ok
    else
      {:error, {:source_not_allowed_for_write, source.document_id}}
    end
  end

  def authorize_citation(%__MODULE__{mode: :dreaming} = authority, source) do
    if MapSet.member?(authority.allowed_document_ids, source.document_id) and
         Sources.automatic_evidence?(source) do
      :ok
    else
      {:error, {:source_not_allowed_for_write, source.document_id}}
    end
  end

  def authorize_citation(%__MODULE__{mode: :agent}, source) do
    if Sources.automatic_evidence?(source),
      do: :ok,
      else: {:error, {:source_not_allowed_for_write, source.document_id}}
  end

  def authorize_citation(%__MODULE__{mode: :mechanical}, source),
    do: {:error, {:source_not_allowed_for_write, source.document_id}}

  defp source_learning_create_fields(operation) do
    allowed = MapSet.new(["operation", "name", "type", "initial_body"])

    extra_fields =
      operation
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&MapSet.member?(allowed, &1))
      |> Enum.sort()

    case extra_fields do
      [] -> :ok
      fields -> {:error, {:source_learning_create_metadata_not_allowed, fields}}
    end
  end

  defp require_source_citation(operation, field, document_id) do
    body = value(operation, field)

    if is_binary(body) and document_id in Citations.document_ids(body),
      do: :ok,
      else: {:error, {:source_learning_citation_required, document_id}}
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
