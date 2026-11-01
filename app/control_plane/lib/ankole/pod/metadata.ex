defmodule Ankole.Pod.Metadata do
  @moduledoc """
  Tenant-wide Pod files under `metadata/`, outside any Page directory.

  Page icons reference the shared custom-emoji library by drive path. Listing
  the library requires space `node_view`, uploading requires space `node_edit`,
  and reading an individual custom-emoji file requires an active Pod Principal.
  """

  import Bitwise, only: [band: 2]

  alias Ankole.Files, as: Drive
  alias Ankole.Files.Access

  @custom_emoji "metadata/custom-emoji/"
  @max_emoji_bytes 1024 * 1024
  @max_name_bytes 64
  @image_types ~w(image/png image/jpeg image/gif image/webp)
  @name_format ~r/^:[a-z0-9_]+:$/

  def max_emoji_bytes, do: @max_emoji_bytes

  @doc "Lists the shared custom emojis and whether the caller may add one."
  def custom_emojis(%Ankole.AuthZ.Actor{} = actor) do
    with {:ok, bits} <- Access.space_bits(actor),
         :ok <- authorize_bits(bits, "node_view"),
         {:ok, files} <- list_all() do
      {:ok,
       %{
         custom_emojis: Enum.map(files, &entry/1),
         can_upload: authorized?(bits, "node_edit")
       }}
    end
  end

  @doc "Stores one image in the shared custom-emoji library."
  def upload_custom_emoji(%Ankole.AuthZ.Actor{} = actor, name, source, content_type) do
    with :ok <- authorize(actor, "node_edit"),
         {:ok, header} <- read_validated_header(source),
         :ok <- check_type(content_type, header),
         :ok <- check_name(name),
         {:ok, stored} <- Drive.store(source) do
      path = @custom_emoji <> stored.sha256 <> "/" <> name

      Access.write(actor.turn_authority, fn ->
        Ankole.AdvisoryLock.lock!(Ankole.Repo, "pod-metadata:#{Ankole.Repo.tenant_id!()}")
        upload = %{path: path, object: stored, source: "pod", content_type: content_type}

        with {:ok, existing} <- list_all(),
             :ok <- check_unique_shortcode(existing, name, path),
             {:ok, _} <- Ankole.Pod.Files.commit_files_in_tx(nil, [upload], []) do
          {:ok,
           %{
             path: path,
             name: name,
             sha256: stored.sha256,
             size: stored.size,
             content_type: content_type
           }}
        end
      end)
    end
  end

  @doc "Copies one custom emoji into a local file for the HTTP response."
  def read_to_file(%Ankole.AuthZ.Actor{} = actor, path, local_path) do
    with {:ok, file} <- resolve(actor, path),
         :ok <- Drive.read_object_to_file(file.object_id, local_path) do
      {:ok, %{name: Path.basename(file.path), content_type: file.content_type}}
    end
  end

  @doc "Resolves one custom emoji after checking the current Pod Principal."
  def resolve(%Ankole.AuthZ.Actor{} = actor, path) do
    with {:ok, _principal} <- Access.principal(actor),
         {:ok, relative} <- normalize(path),
         do: fetch(relative)
  end

  defp list_all, do: Ankole.Pod.Files.list_files(nil, String.trim_trailing(@custom_emoji, "/"))

  defp fetch(relative), do: Ankole.Pod.Files.fetch_file(nil, relative)

  defp normalize(path) when is_binary(path) do
    with {:ok, relative} <- Ankole.Files.Path.normalize(path),
         true <- String.starts_with?(relative, @custom_emoji) do
      {:ok, relative}
    else
      _ -> {:error, :not_found}
    end
  end

  defp normalize(_path), do: {:error, :not_found}

  defp authorize(%Ankole.AuthZ.Actor{} = actor, action) do
    with {:ok, bits} <- Access.space_bits(actor), do: authorize_bits(bits, action)
  end

  defp authorize_bits(bits, action) do
    if authorized?(bits, action), do: :ok, else: {:error, :forbidden}
  end

  defp authorized?(bits, action), do: band(bits, Access.action_bit(action)) != 0

  defp read_validated_header(bytes) when is_binary(bytes) do
    if byte_size(bytes) <= @max_emoji_bytes do
      {:ok, binary_part(bytes, 0, min(byte_size(bytes), 16))}
    else
      {:error, :file_too_large}
    end
  end

  defp read_validated_header({:file, path}) when is_binary(path) do
    with {:ok, stat} <- File.stat(path) do
      if stat.size <= @max_emoji_bytes do
        case File.open(path, [:read, :binary], &IO.binread(&1, 16)) do
          {:ok, :eof} -> {:ok, ""}
          {:ok, header} when is_binary(header) -> {:ok, header}
          _ -> {:error, :missing_file}
        end
      else
        {:error, :file_too_large}
      end
    else
      _ -> {:error, :missing_file}
    end
  end

  defp read_validated_header(_source), do: {:error, :missing_file}

  defp check_type(type, header) when type in @image_types do
    if valid_image_signature?(type, header), do: :ok, else: {:error, :invalid_file_type}
  end

  defp check_type(_type, _header), do: {:error, :invalid_file_type}

  defp valid_image_signature?("image/png", <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>>),
    do: true

  defp valid_image_signature?("image/jpeg", <<255, 216, 255, _::binary>>), do: true
  defp valid_image_signature?("image/gif", <<"GIF87a", _::binary>>), do: true
  defp valid_image_signature?("image/gif", <<"GIF89a", _::binary>>), do: true
  defp valid_image_signature?("image/webp", <<"RIFF", _size::32, "WEBP", _::binary>>), do: true
  defp valid_image_signature?(_type, _header), do: false

  defp check_unique_shortcode(existing, name, path) do
    if Enum.any?(existing, &(Path.basename(&1.path) == name and &1.path != path)),
      do: {:error, :shortcode_taken},
      else: :ok
  end

  defp check_name(name) when is_binary(name) do
    if byte_size(name) <= @max_name_bytes and Regex.match?(@name_format, name),
      do: :ok,
      else: {:error, :invalid_file_name}
  end

  defp check_name(_name), do: {:error, :invalid_file_name}

  defp entry(file) do
    %{
      path: file.path,
      name: Path.basename(file.path),
      sha256: Base.encode16(file.sha256, case: :lower),
      size: file.size,
      content_type: file.content_type
    }
  end
end
