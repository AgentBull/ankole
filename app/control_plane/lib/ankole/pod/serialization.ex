defmodule Ankole.Pod.Serialization do
  @moduledoc "JSON values for Pod HTTP, Channel, and Worker contracts."

  def author_profiles(authors) do
    authors
    |> Enum.uniq()
    |> Enum.group_by(& &1.tenant_id, & &1.uid)
    |> Enum.flat_map(fn {tenant, uids} ->
      Ankole.Repo.with_tenant(tenant, fn ->
        Ankole.Principals.list_principals!(
          query: [filter: [uid: [in: uids]], load: [agent: :owner_principal]]
        )
        |> Enum.map(fn principal ->
          {Ankole.ActorRef.from_principal(principal),
           %{
             tenant_id: tenant,
             principal_uid: principal.uid,
             name: Ankole.Principals.display_name(principal),
             kind: principal.type,
             avatar_url: principal.avatar_url
           }}
        end)
      end)
    end)
    |> Map.new()
  end

  def author_json(author, profiles) do
    Map.get(profiles, author, %{
      tenant_id: author.tenant_id,
      principal_uid: author.uid,
      name: nil,
      kind: nil,
      avatar_url: nil
    })
  end

  def page_json(page) do
    page
    |> Map.take([
      :id,
      :parent_id,
      :private_owner_uid,
      :type,
      :title,
      :role,
      :icon,
      :position,
      :inherit_permissions,
      :revision,
      :object_id,
      :saved_from_message_id,
      :children_view,
      :created_at,
      :updated_at,
      :deleted_at,
      :purge_started_at
    ])
    |> enum_json(:type)
    |> Map.update!(:role, fn
      %Ash.NotLoaded{} -> nil
      role -> role
    end)
    |> Ankole.JSON.plain()
  end

  def change_json(change),
    do:
      change
      |> Map.take([:revision, :kind, :client_id, :client_seq, :changes, :created_at])
      |> enum_json(:kind)
      |> Ankole.JSON.plain()

  def document_json(%{page: page, content: content}),
    do: %{page: page_json(page), content: content_json(content)}

  def detail_json(detail),
    do: %{
      page: page_json(detail.page),
      content: content_json(detail.content),
      role: detail.role,
      child_count: Map.get(detail, :child_count, 0),
      source_conversation: detail.source_conversation
    }

  def content_json(nil), do: nil
  def content_json(content), do: %{xml: content.content, plain_text: content.plain_text}

  def item(%schema{} = struct) do
    struct
    |> Map.take(schema.__schema__(:fields) -- [:tenant_id])
    |> then(fn item ->
      if Map.has_key?(item, :type), do: Map.update!(item, :type, &to_string/1), else: item
    end)
  end

  def item(map), do: map

  defp enum_json(item, key) do
    case Map.fetch(item, key) do
      {:ok, value} when is_atom(value) and not is_nil(value) ->
        Map.put(item, key, Atom.to_string(value))

      _ ->
        item
    end
  end

  def error(:field_history_limit),
    do: %{
      code: "field_history_limit",
      message: "This table has reached its column history limit. Copy the table to add fields.",
      details: nil
    }

  def error(:primary_field_size_limit),
    do: %{
      code: "primary_field_size_limit",
      message: "Primary field values must not exceed 2 KiB.",
      details: nil
    }

  def error(:guest_forbidden_in_private),
    do: %{
      code: "guest_forbidden_in_private",
      message: "External guests cannot access private pages.",
      details: nil
    }

  def error({:forbidden, _action}), do: error(:forbidden)
  def error({:field_conflict, details}), do: error_details("field_conflict", details)
  def error({:record_conflict, id}), do: error_details("record_conflict", %{id: id})
  def error({:record_exists, id}), do: error_details("record_exists", %{id: id})
  def error({:schema_conflict, current}), do: error_details("schema_conflict", item(current))
  def error({:conversion_failed, ids}), do: error_details("conversion_failed", %{record_ids: ids})

  def error({:revision_conflict, revision}),
    do: error_details("revision_conflict", %{revision: revision})

  def error({:title_conflict, title}),
    do: error_details("title_conflict", %{title: title})

  def error(reason) when is_atom(reason), do: error_details(Atom.to_string(reason), nil)

  def error({reason, details}) when is_atom(reason),
    do: error_details(Atom.to_string(reason), json_value(details))

  def error(reason) when is_binary(reason),
    do: %{code: "validation_failed", message: reason, details: nil}

  def error(_reason), do: error(:validation_failed)

  defp error_details(code, details), do: %{code: code, message: code, details: details}

  def json_value(%Ankole.Pod.Page{} = page), do: page_json(page)
  def json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def json_value(%Ankole.ActorRef{} = value), do: to_string(value)
  def json_value(%Ecto.Association.NotLoaded{}), do: nil

  def json_value(%schema{} = value),
    do: value |> Map.take(schema.__schema__(:fields) -- [:tenant_id]) |> json_value()

  def json_value(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json_value(item)} end)

  def json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  def json_value(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_value()

  def json_value(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  def json_value(value), do: value

  def status(code) do
    case code do
      "not_found" ->
        404

      "route_not_found" ->
        404

      "method_not_allowed" ->
        405

      "applet_busy" ->
        503

      "handler_timeout" ->
        504

      "ai_unavailable" ->
        502

      code when code in ~w(handler_error handler_out_of_memory read_only_route) ->
        500

      "forbidden" ->
        403

      "move_requires_manage" ->
        403

      "file_too_large" ->
        413

      code
      when code in ~w(revision_conflict title_conflict document_conflict sharing_conflict cannot_restore manifest_changed
                          field_conflict record_conflict record_exists schema_conflict local_table_changed
                          client_sequence_conflict applet_revision_changed
                          position_conflict) ->
        409

      _ ->
        422
    end
  end
end
