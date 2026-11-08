defmodule Ankole.Files.ImageSignature do
  @moduledoc false

  @image_types ~w(image/png image/jpeg image/gif image/webp)

  @spec validate_source(binary() | {:file, String.t()} | term(), term(), pos_integer()) ::
          :ok | {:error, :file_too_large | :invalid_file_type | :missing_file}
  def validate_source(source, content_type, max_bytes)
      when is_integer(max_bytes) and max_bytes > 0 do
    with {:ok, header} <- read_validated_header(source, max_bytes) do
      check_type(content_type, header)
    end
  end

  defp read_validated_header(bytes, max_bytes) when is_binary(bytes) do
    if byte_size(bytes) <= max_bytes do
      {:ok, binary_part(bytes, 0, min(byte_size(bytes), 16))}
    else
      {:error, :file_too_large}
    end
  end

  defp read_validated_header({:file, path}, max_bytes) when is_binary(path) do
    with {:ok, stat} <- File.stat(path) do
      if stat.size <= max_bytes do
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

  defp read_validated_header(_source, _max_bytes), do: {:error, :missing_file}

  defp check_type(type, header) when type in @image_types do
    if valid_signature?(type, header), do: :ok, else: {:error, :invalid_file_type}
  end

  defp check_type(_type, _header), do: {:error, :invalid_file_type}

  defp valid_signature?("image/png", <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>>), do: true
  defp valid_signature?("image/jpeg", <<255, 216, 255, _::binary>>), do: true
  defp valid_signature?("image/gif", <<"GIF87a", _::binary>>), do: true
  defp valid_signature?("image/gif", <<"GIF89a", _::binary>>), do: true
  defp valid_signature?("image/webp", <<"RIFF", _size::32, "WEBP", _::binary>>), do: true
  defp valid_signature?(_type, _header), do: false
end
