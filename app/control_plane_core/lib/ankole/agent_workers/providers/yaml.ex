defmodule Ankole.AgentWorkers.Providers.YAML do
  @moduledoc "One YAML mapping with source locations for provider validation errors."

  @spec parse(String.t()) :: {:ok, map(), map()} | {:error, [map()]}
  def parse(text) when is_binary(text) do
    with {:ok, [data]} when is_map(data) <- YamlElixir.read_all_from_string(text),
         [document] <-
           :yamerl_constr.string(text,
             detailed_constr: true,
             str_node_as_binary: true,
             keep_duplicate_keys: true
           ),
         {:ok, locations} <- locations(document, [], %{}) do
      {:ok, data, locations}
    else
      {:error, %YamlElixir.ParsingError{} = error} ->
        {:error, [%{path: "$", line: error.line, message: error.message}]}

      {:error, errors} ->
        {:error, errors}

      _other ->
        {:error, [%{path: "$", line: 1, message: "must contain exactly one YAML mapping"}]}
    end
  end

  def parse(_text), do: {:error, [%{path: "$", line: nil, message: "must be YAML text"}]}

  @spec error(map(), [String.t()], String.t()) :: map()
  def error(locations, path, message) do
    %{
      path: if(path == [], do: "$", else: Enum.join(path, ".")),
      line: line(locations, path),
      message: message
    }
  end

  defp line(locations, path) do
    case Map.fetch(locations, path) do
      {:ok, value} -> value
      :error when path == [] -> 1
      :error -> line(locations, Enum.drop(path, -1))
    end
  end

  defp locations({:yamerl_doc, root}, path, index), do: locations(root, path, index)

  defp locations({:yamerl_map, _, _, loc, pairs}, path, index) do
    index = Map.put_new(index, path, loc[:line])

    Enum.reduce_while(pairs, {:ok, index}, fn {key, value}, {:ok, acc} ->
      key_value =
        case key do
          {:yamerl_str, _, _, _, value} -> value
          _non_string -> nil
        end

      child = path ++ [key_value]

      cond do
        not is_binary(key_value) ->
          {:halt, {:error, [error(acc, path, "mapping keys must be strings")]}}

        Map.has_key?(acc, child) ->
          {:halt, {:error, [error(acc, child, "duplicate mapping key")]}}

        true ->
          case locations(value, child, Map.put(acc, child, elem(key, 3)[:line])) do
            {:ok, next} -> {:cont, {:ok, next}}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp locations({:yamerl_seq, _, _, loc, values, _count}, path, index) do
    values
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, Map.put_new(index, path, loc[:line])}, fn {value, i}, {:ok, acc} ->
      case locations(value, path ++ [to_string(i)], acc) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp locations(node, path, index),
    do: {:ok, Map.put_new(index, path, elem(node, 3)[:line])}
end
