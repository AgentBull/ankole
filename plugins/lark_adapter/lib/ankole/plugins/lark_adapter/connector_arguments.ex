defmodule Ankole.Plugins.LarkAdapter.ConnectorArguments do
  @moduledoc false
  alias Ankole.Plugins.LarkAdapter.Connector

  def prepare(tool, args, context) do
    with {:ok, args} <- bind_employee(tool, args, context),
         {:ok, args} <- resolve_people(args, context.auth_config),
         {:ok, args} <- calendar(tool, args, context),
         {:ok, args} <- form(tool, args, context) do
      unit = if tool.toolkit in ["lark_tasks", "lark_approvals"], do: :millisecond, else: :second

      {:ok,
       if(tool.toolkit in ["lark_tasks", "lark_calendar", "lark_approvals"],
         do: times(args, unit, tool.operation["query"] || []),
         else: args
       )}
    end
  end

  defp bind_employee(%{upstream_auth: :app_token_with_bound_user}, args, %{external_user_id: id})
       when is_binary(id),
       do: {:ok, args |> Map.delete("open_id") |> Map.put("user_id", id)}

  defp bind_employee(%{upstream_auth: :app_token_with_bound_user}, _args, _context),
    do: {:error, :oauth_consent_required}

  defp bind_employee(%{name: "approvals_list_tasks"}, args, %{external_user_id: id})
       when is_binary(id), do: {:ok, Map.put_new(args, "user_id", id)}

  defp bind_employee(_tool, args, _context), do: {:ok, args}

  defp resolve_people(value, config, target \\ "id")

  defp resolve_people(value, config, target) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn value, {:ok, acc} ->
      case resolve_people(value, config, target) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp resolve_people(%{"principal_uid" => uid} = value, config, target) do
    with {:ok, id} <- Connector.bound_user_id(config, uid) do
      key = if Map.has_key?(value, "msg_type"), do: "receive_id", else: target
      value = value |> Map.delete("principal_uid") |> Map.put(key, id)

      value =
        if key == "receive_id", do: Map.put(value, "receive_id_type", "user_id"), else: value

      value = if target == "user_id", do: Map.put_new(value, "type", "user"), else: value
      resolve_people(value, config, target)
    end
  end

  defp resolve_people(%{"principal_uids" => uids} = value, config, target) do
    with {:ok, people} <- resolve_people(Enum.map(uids, &%{"principal_uid" => &1}), config),
         do:
           resolve_people(
             value
             |> Map.delete("principal_uids")
             |> Map.put("user_ids", Enum.map(people, & &1["id"])),
             config,
             target
           )
  end

  defp resolve_people(value, config, target) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case resolve_people(value, config, if(key == "attendees", do: "user_id", else: target)) do
        {:ok, result} -> {:cont, {:ok, Map.put(acc, key, result)}}
        error -> {:halt, error}
      end
    end)
  end

  defp resolve_people(value, _config, _target), do: {:ok, value}

  defp calendar(%{toolkit: "lark_calendar", operation: %{"path" => path}}, args, context) do
    if String.contains?(path, ":calendar_id") and not is_binary(args["calendar_id"]) do
      with {:ok, primary} <-
             Connector.call(Connector.find_tool("calendar_get_primary"), %{}, context),
           [%{"calendar" => %{"calendar_id" => id}} | _] <- primary["calendars"] do
        {:ok, Map.put(args, "calendar_id", id)}
      else
        {:error, _} = error -> error
        _ -> {:error, :primary_calendar_unavailable}
      end
    else
      {:ok, args}
    end
  end

  defp calendar(_tool, args, _context), do: {:ok, args}

  defp form(%{name: "approvals_create_instance"}, %{"form" => form} = args, context)
       when is_map(form) do
    with {:ok, definition} <-
           Connector.call(
             Connector.find_tool("approvals_get_definition"),
             %{"approval_code" => args["approval_code"]},
             context
           ),
         controls when is_list(controls) <- definition["form"] do
      Enum.reduce_while(form, {:ok, []}, fn {id, value}, {:ok, acc} ->
        case Enum.find(controls, &(&1["id"] == id or &1["name"] == id)) do
          nil ->
            {:halt, {:error, %{code: "unknown_approval_control", control: id, retryable: false}}}

          control ->
            {:cont,
             {:ok, [%{"id" => control["id"], "type" => control["type"], "value" => value} | acc]}}
        end
      end)
      |> case do
        {:ok, controls} -> {:ok, Map.put(args, "form", Torque.encode!(Enum.reverse(controls)))}
        error -> error
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_approval_definition}
    end
  end

  defp form(%{name: "approvals_create_instance"}, %{"form" => form} = args, _context)
       when is_list(form), do: {:ok, Map.put(args, "form", Torque.encode!(form))}

  defp form(_tool, args, _context), do: {:ok, args}

  def operation(tool, args) do
    operation = tool.operation

    operation =
      if tool.upstream_auth == :app_token_with_bound_user,
        do: Map.update!(operation, "query", &Enum.uniq(["user_id_type" | &1])),
        else: operation

    args =
      if "user_id_type" in operation["query"],
        do: Map.put(args, "user_id_type", "user_id"),
        else: args

    args =
      if is_map(args["content"]), do: Map.update!(args, "content", &Torque.encode!/1), else: args

    {operation, args} =
      case tool.name do
        "im_update_message" ->
          if(args["msg_type"] == "interactive",
            do: {%{operation | "method" => "PATCH"}, Map.delete(args, "msg_type")},
            else: {operation, args}
          )

        "im_list_thread_messages" ->
          {operation,
           args
           |> Map.put("container_id_type", "thread")
           |> Map.put("container_id", args["thread_id"])
           |> Map.delete("thread_id")}

        "im_urgent_message" ->
          {%{
             operation
             | "path" =>
                 String.replace(
                   operation["path"],
                   "urgent_app",
                   "urgent_" <> (args["channel"] || "app")
                 )
           }, Map.delete(args, "channel")}

        _ ->
          {operation, args}
      end

    case Map.pop(args, "operation") do
      {"remove", args} ->
        path =
          operation["path"]
          |> String.replace("add_members", "remove_members")
          |> String.replace("add_reminders", "remove_reminders")
          |> String.replace("add_tasklist", "remove_tasklist")

        path =
          if tool.name == "calendar_manage_attendees", do: path <> "/batch_delete", else: path

        {%{operation | "path" => path}, args}

      {_, args} ->
        {operation, args}
    end
  end

  defp times(value, unit, scalar_fields) when is_map(value),
    do:
      Map.new(value, fn {key, value} ->
        result =
          cond do
            key in ["start_time", "end_time"] and is_binary(value) and
                String.contains?(value, "T") ->
              if(key in scalar_fields,
                do: timestamp(value, unit),
                else: %{"timestamp" => timestamp(value, unit)}
              )

            key in ["timestamp", "completed_at", "anchor_time"] and is_binary(value) ->
              timestamp(value, unit)

            true ->
              times(value, unit, [])
          end

        {key, result}
      end)

  defp times(value, unit, _scalar_fields) when is_list(value),
    do: Enum.map(value, &times(&1, unit, []))

  defp times(value, _unit, _scalar_fields), do: value

  defp timestamp(value, unit) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _} -> date |> DateTime.to_unix(unit) |> Integer.to_string()
      _ -> value
    end
  end
end
