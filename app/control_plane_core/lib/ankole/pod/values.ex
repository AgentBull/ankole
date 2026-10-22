defmodule Ankole.Pod.Values do
  @moduledoc false
  import Ecto.Query
  require Ash.Query
  alias Ankole.Pod.{DbRecord, DbTable, Formula}
  alias Ankole.Repo

  def patch(data, fields, page_id, opts \\ [])

  def patch(data, fields, page_id, opts) when is_map(data) do
    Enum.reduce_while(data, {:ok, %{}}, fn {id, value}, {:ok, patch} ->
      case Enum.find(fields, &(&1.id == id)) do
        nil ->
          {:halt, {:error, {:unknown_field, id}}}

        field ->
          if Formula.readonly?(field) or
               (field.type == :auto_number and not Keyword.get(opts, :internal, false)) do
            {:halt, {:error, {:readonly_field, id}}}
          else
            case cast(field, value, page_id) do
              {:ok, value} -> {:cont, {:ok, Map.put(patch, id, value)}}
              _ -> {:halt, {:error, {:invalid_value, id}}}
            end
          end
      end
    end)
  end

  def patch(_, _, _, _), do: {:error, :invalid_record}

  def cast(_field, value, _page) when value in [nil, "", []], do: {:ok, nil}
  def cast(%{type: :text}, value, _) when is_binary(value), do: {:ok, value}

  def cast(%{type: type}, value, _) when type in [:number, :auto_number] and is_number(value),
    do: {:ok, value}

  def cast(%{type: :checkbox}, value, _) when is_boolean(value), do: {:ok, value}

  def cast(%{type: :datetime}, value, _) when is_binary(value) do
    with {:ok, datetime, _offset} <- DateTime.from_iso8601(value),
         do:
           {:ok,
            datetime
            |> DateTime.shift_zone!("Etc/UTC")
            |> Map.put(:microsecond, {elem(datetime.microsecond, 0), 6})
            |> DateTime.to_iso8601()},
         else: (_ -> {:error, :invalid_datetime})
  end

  def cast(%{type: :select, config: config}, value, _) do
    multiple = config["multiple"] == true
    options = Enum.map(config["options"] || [], &Ankole.Attrs.get(&1, :id))

    cond do
      multiple and is_list(value) and Enum.all?(value, &(&1 in options)) ->
        {:ok, Enum.uniq(value)}

      not multiple and is_binary(value) and value in options ->
        {:ok, value}

      true ->
        {:error, :invalid_option}
    end
  end

  def cast(%{type: :user}, value, _) when is_list(value) do
    with {:ok, ids} <- normalize_ids(value, &Ankole.Principals.normalize_uid/1),
         principals <-
           Ankole.Principals.list_principals!(query: [filter: [uid: [in: ids]], select: [:uid]]),
         true <- length(principals) == length(ids) do
      {:ok, ids}
    else
      _ -> {:error, :invalid_principal}
    end
  end

  def cast(%{type: :link, config: config}, value, page) when is_list(value) do
    with {:ok, target} <- Ecto.UUID.cast(config["table_id"]),
         %DbTable{page_id: ^page} <-
           DbTable |> Ash.Query.filter(id == ^target) |> Ankole.Ash.read_one!(),
         {:ok, ids} <- normalize_ids(value, &Ecto.UUID.cast/1),
         true <- config["multiple"] != false or length(ids) <= 1,
         count <-
           Repo.aggregate(
             from(r in DbRecord, where: r.table_id == ^target and r.id in ^ids),
             :count
           ),
         true <- count == length(ids) do
      {:ok, ids}
    else
      _ -> {:error, :invalid_link}
    end
  end

  def cast(%{type: :attachment}, value, page) when is_list(value) do
    if Enum.all?(value, fn item ->
         path = if is_map(item), do: Ankole.Attrs.get(item, :path, "")

         is_map(item) and is_binary(path) and is_binary(Ankole.Attrs.get(item, :name)) and
           is_binary(Ankole.Attrs.get(item, :mime)) and
           is_integer(Ankole.Attrs.get(item, :size)) and Ankole.Attrs.get(item, :size) >= 0 and
           String.starts_with?(path, Ankole.Pod.Files.prefix(page) <> "/attachments/") and
           match?({:ok, _}, Ankole.Files.fetch(:pod, path))
       end), do: {:ok, value}, else: {:error, :invalid_attachment}
  end

  def cast(_, _, _), do: {:error, :invalid_value}

  defp normalize_ids(values, normalize) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, ids} ->
      case normalize.(value) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        _ -> {:halt, {:error, :invalid_id}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, ids |> Enum.reverse() |> Enum.uniq()}
      error -> error
    end
  end

  def convert(field, value, page) do
    candidate =
      case field.type do
        :text ->
          if is_binary(value),
            do: value,
            else: if(is_nil(value), do: nil, else: Torque.encode!(value))

        :number when is_binary(value) ->
          case Float.parse(value) do
            {number, ""} -> number
            _ -> :invalid
          end

        :select when is_binary(value) ->
          if field.config["multiple"], do: [value], else: value

        :select when is_list(value) ->
          if field.config["multiple"],
            do: value,
            else: if(length(value) == 1, do: hd(value), else: :invalid)

        :checkbox when value in ["true", "false"] ->
          value == "true"

        _ ->
          value
      end

    cast(field, candidate, page)
  end
end
