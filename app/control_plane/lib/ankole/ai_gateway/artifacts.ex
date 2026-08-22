defmodule Ankole.AIGateway.Artifacts do
  @moduledoc """
  Principal-scoped storage and reference resolution for hosted-tool images.

  Uploaded files and generated images share one bounded binary store, but keep
  different public ID prefixes and lifecycle rules.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIGateway.Artifacts.Image
  alias Ankole.AIGateway.Artifacts.References
  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.Schemas.Artifact
  alias Ankole.Ecto.UUIDv7
  alias Ankole.Principals
  alias Ankole.Repo

  @max_image_bytes 50 * 1024 * 1024
  @min_expiry_seconds 3_600
  @max_expiry_seconds 2_592_000
  @stateless_generated_ttl_seconds 30 * 24 * 60 * 60

  @type list_opts :: [
          limit: pos_integer(),
          order: :asc | :desc,
          after: String.t(),
          purpose: String.t()
        ]

  @spec max_image_bytes() :: pos_integer()
  def max_image_bytes, do: @max_image_bytes

  @spec create_uploaded_file(String.t(), Plug.Upload.t(), map()) ::
          {:ok, Artifact.t()} | {:error, term()}
  def create_uploaded_file(subject_uid, %Plug.Upload{} = upload, params) when is_map(params) do
    with {:ok, subject_uid} <- normalize_subject(subject_uid),
         :ok <- validate_purpose(params),
         {:ok, expires_at} <- expires_at(params),
         {:ok, payload} <- read_bounded_upload(upload),
         {:ok, mime_type} <- Image.sniff(payload) do
      insert(%{
        subject_uid: subject_uid,
        kind: "uploaded_file",
        filename: upload.filename,
        purpose: "vision",
        mime_type: mime_type,
        byte_size: byte_size(payload),
        sha256: :crypto.hash(:sha256, payload),
        payload: payload,
        expires_at: expires_at
      })
    end
  end

  def create_uploaded_file(_subject_uid, _upload, _params),
    do: {:error, OpenAIError.invalid("file", "invalid_type", "file must be an upload.")}

  @spec persist_generated_image(
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          keyword()
        ) ::
          {:ok, Artifact.t()} | {:error, term()}
  def persist_generated_image(subject_uid, public_id, base64, mime_type, opts \\ []) do
    with {:ok, subject_uid} <- normalize_subject(subject_uid),
         {:ok, identity} <- generated_image_identity(public_id),
         {:ok, payload} <- Image.decode_base64(base64),
         :ok <- Image.validate_generated_size(payload, @max_image_bytes),
         {:ok, sniffed_type} <- Image.sniff(payload),
         :ok <- Image.validate_declared_mime(mime_type, sniffed_type) do
      message_id = Keyword.get(opts, :message_id)

      insert(%{
        id: identity.id,
        provider_item_id: identity.provider_item_id,
        subject_uid: subject_uid,
        message_id: message_id,
        kind: "generated_image",
        filename: Keyword.get(opts, :filename),
        mime_type: sniffed_type,
        byte_size: byte_size(payload),
        sha256: :crypto.hash(:sha256, payload),
        payload: payload,
        expires_at: generated_expiry(message_id)
      })
    end
  end

  # The item-id shape selects the identity source. The Kernel hosted executor
  # mints `ig_<UUIDv7>` item ids, and those stay the Artifact primary key. A
  # native provider mints an opaque item id, so the Artifact gets a local
  # primary key and keeps the provider id for reference lookup.
  defp generated_image_identity(public_id) do
    case public_uuid(public_id, "ig_") do
      {:ok, id} ->
        {:ok, %{id: id, provider_item_id: nil}}

      {:error, _reason} when is_binary(public_id) and public_id != "" ->
        {:ok, %{id: UUIDv7.autogenerate(), provider_item_id: public_id}}

      {:error, _reason} = error ->
        error
    end
  end

  @spec get_file(String.t(), String.t(), keyword()) ::
          {:ok, Artifact.t()} | {:error, OpenAIError.t()}
  def get_file(subject_uid, file_id, opts \\ []) do
    get_for_subject(subject_uid, file_id, "file_", "uploaded_file", opts)
  end

  @spec get_generated_image(String.t(), String.t(), keyword()) ::
          {:ok, Artifact.t()} | {:error, OpenAIError.t()}
  def get_generated_image(subject_uid, image_id, opts \\ []) do
    case public_uuid(image_id, "ig_") do
      {:ok, _id} ->
        get_for_subject(subject_uid, image_id, "ig_", "generated_image", opts)

      # A native provider's item id is not a local UUID; the Artifact stored
      # it in provider_item_id, so the public reference stays resolvable.
      {:error, _not_castable} ->
        get_by_provider_item_id(subject_uid, image_id, opts)
    end
  end

  @spec delete_file(String.t(), String.t()) :: {:ok, map()} | {:error, OpenAIError.t()}
  def delete_file(subject_uid, file_id) do
    with {:ok, artifact} <- get_file(subject_uid, file_id),
         {:ok, _artifact} <- Repo.delete(artifact) do
      {:ok, %{"id" => file_id, "object" => "file", "deleted" => true}}
    end
  end

  @spec list_files(String.t(), map()) :: {:ok, map()} | {:error, OpenAIError.t()}
  def list_files(subject_uid, params) when is_map(params) do
    with {:ok, subject_uid} <- normalize_subject(subject_uid),
         {:ok, limit} <- list_limit(params),
         {:ok, order} <- list_order(params),
         :ok <- list_purpose(params),
         {:ok, cursor} <- list_cursor(params) do
      rows = list_query(subject_uid, params, order, cursor, limit + 1) |> Repo.all()
      has_more = length(rows) > limit
      rows = Enum.take(rows, limit)
      data = Enum.map(rows, &file_object/1)

      {:ok,
       %{
         "object" => "list",
         "data" => data,
         "first_id" => rows |> List.first() |> nullable_file_id(),
         "last_id" => rows |> List.last() |> nullable_file_id(),
         "has_more" => has_more
       }}
    end
  end

  @spec file_object(Artifact.t()) :: map()
  def file_object(%Artifact{} = artifact) do
    %{
      "id" => public_id(artifact),
      "object" => "file",
      "bytes" => artifact.byte_size,
      "created_at" => unix_timestamp(artifact.inserted_at),
      "filename" => artifact.filename,
      "purpose" => artifact.purpose,
      "status" => "processed"
    }
    |> Ankole.Attrs.maybe_put("expires_at", nullable_unix_timestamp(artifact.expires_at))
  end

  @spec public_id(Artifact.t()) :: String.t()
  def public_id(%Artifact{kind: "uploaded_file", id: id}), do: "file_#{id}"
  def public_id(%Artifact{kind: "generated_image", id: id}), do: "ig_#{id}"

  @spec hydrate_generated_images(String.t(), [map()]) :: {:ok, [map()]} | {:error, term()}
  defdelegate hydrate_generated_images(subject_uid, items), to: References

  @spec resolve_references(String.t(), map()) :: {:ok, [map()]} | {:error, term()}
  defdelegate resolve_references(subject_uid, request), to: References, as: :resolve

  @spec resolve_native_input(String.t(), map()) :: {:ok, map()} | {:error, term()}
  defdelegate resolve_native_input(subject_uid, request), to: References

  @spec cleanup_expired_and_failed(DateTime.t()) :: non_neg_integer()
  def cleanup_expired_and_failed(now \\ DateTime.utc_now(:microsecond)) do
    failed_message_ids =
      from(message in Ankole.AIGateway.Schemas.Message,
        where: message.status == "error",
        select: message.id
      )

    {count, _rows} =
      from(artifact in Artifact,
        where:
          (not is_nil(artifact.expires_at) and artifact.expires_at <= ^now) or
            (artifact.kind == "generated_image" and is_nil(artifact.expires_at) and
               (is_nil(artifact.message_id) or
                  artifact.message_id in subquery(failed_message_ids)))
      )
      |> Repo.delete_all()

    count
  end

  defp insert(attrs) do
    %Artifact{}
    |> Artifact.changeset(attrs)
    |> Repo.insert()
  end

  defp get_for_subject(subject_uid, public_id, prefix, kind, opts) do
    with {:ok, subject_uid} <- normalize_subject(subject_uid),
         {:ok, id} <- public_uuid(public_id, prefix),
         %Artifact{} = artifact <- Repo.one(artifact_query(subject_uid, id, kind, opts)) do
      {:ok, artifact}
    else
      _missing_or_invalid -> {:error, OpenAIError.not_found("file_id")}
    end
  end

  defp get_by_provider_item_id(subject_uid, provider_item_id, opts)
       when is_binary(provider_item_id) and provider_item_id != "" do
    with {:ok, subject_uid} <- normalize_subject(subject_uid),
         %Artifact{} = artifact <-
           Repo.one(provider_item_query(subject_uid, provider_item_id, opts)) do
      {:ok, artifact}
    else
      _missing_or_invalid -> {:error, OpenAIError.not_found("file_id")}
    end
  end

  defp get_by_provider_item_id(_subject_uid, _provider_item_id, _opts),
    do: {:error, OpenAIError.not_found("file_id")}

  defp artifact_query(subject_uid, id, kind, opts) do
    now = DateTime.utc_now(:microsecond)

    from(artifact in Artifact,
      where:
        artifact.id == ^id and artifact.subject_uid == ^subject_uid and
          artifact.kind == ^kind and
          (is_nil(artifact.expires_at) or artifact.expires_at > ^now)
    )
    |> maybe_select_payload(opts)
  end

  # The provider_item_id index is not unique, so the newest matching Artifact
  # wins deterministically.
  defp provider_item_query(subject_uid, provider_item_id, opts) do
    now = DateTime.utc_now(:microsecond)

    from(artifact in Artifact,
      where:
        artifact.provider_item_id == ^provider_item_id and
          artifact.subject_uid == ^subject_uid and
          artifact.kind == "generated_image" and
          (is_nil(artifact.expires_at) or artifact.expires_at > ^now),
      order_by: [desc: artifact.inserted_at, desc: artifact.id],
      limit: 1
    )
    |> maybe_select_payload(opts)
  end

  defp maybe_select_payload(query, opts) do
    if Keyword.get(opts, :payload?, false) do
      from(artifact in query, select_merge: %{payload: artifact.payload})
    else
      query
    end
  end

  defp normalize_subject(subject_uid) do
    case Principals.normalize_uid(subject_uid) do
      {:ok, subject_uid} -> {:ok, subject_uid}
      _error -> {:error, OpenAIError.not_found(nil, "Resource not found.")}
    end
  end

  defp validate_purpose(params) do
    case value(params, "purpose") do
      "vision" ->
        :ok

      nil ->
        {:error,
         OpenAIError.invalid("purpose", "missing_required_parameter", "purpose is required.")}

      _value ->
        {:error,
         OpenAIError.invalid(
           "purpose",
           "unsupported_value",
           "Only purpose 'vision' is supported."
         )}
    end
  end

  defp expires_at(params) do
    case value(params, "expires_after") do
      nil ->
        {:ok, nil}

      %{} = expiry ->
        parse_expiry(expiry)

      _value ->
        {:error,
         OpenAIError.invalid("expires_after", "invalid_type", "expires_after must be an object.")}
    end
  end

  defp parse_expiry(expiry) do
    anchor = value(expiry, "anchor")
    seconds = integer_value(value(expiry, "seconds"))

    cond do
      anchor != "created_at" ->
        {:error,
         OpenAIError.invalid(
           "expires_after.anchor",
           "unsupported_value",
           "expires_after.anchor must be 'created_at'."
         )}

      not is_integer(seconds) or seconds < @min_expiry_seconds or seconds > @max_expiry_seconds ->
        {:error,
         OpenAIError.invalid(
           "expires_after.seconds",
           "invalid_value",
           "expires_after.seconds must be between 3600 and 2592000."
         )}

      true ->
        {:ok, DateTime.add(DateTime.utc_now(:microsecond), seconds, :second)}
    end
  end

  defp read_bounded_upload(%Plug.Upload{path: path}) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_image_bytes ->
        image_too_large()

      {:ok, _stat} ->
        case File.read(path) do
          {:ok, payload} when byte_size(payload) <= @max_image_bytes -> {:ok, payload}
          {:ok, _payload} -> image_too_large()
          {:error, _reason} -> unreadable_file()
        end

      {:error, _reason} ->
        unreadable_file()
    end
  end

  defp image_too_large,
    do:
      {:error,
       OpenAIError.invalid("file", "request_too_large", "Image exceeds the 50 MiB limit.")}

  defp unreadable_file,
    do:
      {:error,
       OpenAIError.invalid("file", "invalid_file", "The uploaded file could not be read.")}

  defp generated_expiry(nil),
    do: DateTime.add(DateTime.utc_now(:microsecond), @stateless_generated_ttl_seconds, :second)

  defp generated_expiry(_message_id), do: nil

  defp list_limit(params) do
    case integer_value(value(params, "limit") || 10_000) do
      limit when is_integer(limit) and limit in 1..10_000 ->
        {:ok, limit}

      _value ->
        {:error,
         OpenAIError.invalid("limit", "invalid_value", "limit must be between 1 and 10000.")}
    end
  end

  defp list_order(params) do
    case value(params, "order") || "desc" do
      "asc" ->
        {:ok, :asc}

      "desc" ->
        {:ok, :desc}

      _value ->
        {:error, OpenAIError.invalid("order", "invalid_value", "order must be 'asc' or 'desc'.")}
    end
  end

  defp list_purpose(params) do
    case value(params, "purpose") do
      nil ->
        :ok

      "vision" ->
        :ok

      _value ->
        {:error,
         OpenAIError.invalid(
           "purpose",
           "unsupported_value",
           "Only purpose 'vision' is supported."
         )}
    end
  end

  defp list_cursor(params) do
    case value(params, "after") do
      nil -> {:ok, nil}
      id -> public_uuid(id, "file_")
    end
  end

  defp list_query(subject_uid, params, order, cursor, limit) do
    now = DateTime.utc_now(:microsecond)

    query =
      from(artifact in Artifact,
        where:
          artifact.subject_uid == ^subject_uid and artifact.kind == "uploaded_file" and
            (is_nil(artifact.expires_at) or artifact.expires_at > ^now),
        limit: ^limit
      )

    query =
      case value(params, "purpose") do
        purpose when is_binary(purpose) ->
          from(artifact in query, where: artifact.purpose == ^purpose)

        _purpose ->
          query
      end

    query = apply_cursor(query, subject_uid, cursor, order)

    case order do
      :asc -> from(artifact in query, order_by: [asc: artifact.inserted_at, asc: artifact.id])
      :desc -> from(artifact in query, order_by: [desc: artifact.inserted_at, desc: artifact.id])
    end
  end

  defp apply_cursor(query, _subject_uid, nil, _order), do: query

  defp apply_cursor(query, subject_uid, cursor, order) do
    case Repo.one(
           from(artifact in Artifact,
             where:
               artifact.id == ^cursor and artifact.subject_uid == ^subject_uid and
                 artifact.kind == "uploaded_file",
             select: {artifact.inserted_at, artifact.id}
           )
         ) do
      {inserted_at, id} when order == :asc ->
        from(artifact in query,
          where:
            artifact.inserted_at > ^inserted_at or
              (artifact.inserted_at == ^inserted_at and artifact.id > ^id)
        )

      {inserted_at, id} ->
        from(artifact in query,
          where:
            artifact.inserted_at < ^inserted_at or
              (artifact.inserted_at == ^inserted_at and artifact.id < ^id)
        )

      nil ->
        from(artifact in query, where: false)
    end
  end

  defp public_uuid(value, prefix) when is_binary(value) do
    case value do
      ^prefix <> uuid ->
        case UUIDv7.cast(uuid) do
          {:ok, id} -> {:ok, id}
          :error -> {:error, OpenAIError.not_found("file_id")}
        end

      _value ->
        {:error, OpenAIError.not_found("file_id")}
    end
  end

  defp public_uuid(_value, _prefix), do: {:error, OpenAIError.not_found("file_id")}

  defp nullable_file_id(nil), do: nil
  defp nullable_file_id(%Artifact{} = artifact), do: public_id(artifact)

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _value -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp unix_timestamp(%DateTime{} = datetime), do: DateTime.to_unix(datetime)

  defp unix_timestamp(%NaiveDateTime{} = datetime),
    do: datetime |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

  defp nullable_unix_timestamp(nil), do: nil
  defp nullable_unix_timestamp(datetime), do: unix_timestamp(datetime)
end
