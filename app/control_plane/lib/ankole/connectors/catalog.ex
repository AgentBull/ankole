defmodule Ankole.Connectors.Catalog do
  @moduledoc "Credential forms reuse each platform plugin's declared configuration fields."
  alias Ankole.Connectors.LegacyConfig

  def list do
    Ankole.Plugins.Registry.list_active()
    |> Enum.filter(&String.ends_with?(&1.id, "-adapter"))
    |> Enum.flat_map(fn plugin ->
      connectors =
        Enum.filter(plugin.adapter_declarations, &(&1.contract_id == "connectors.connector"))

      Enum.map(if(connectors == [], do: [nil], else: connectors), &entry(plugin, &1))
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp entry(plugin, connector) do
    id = if connector, do: connector.id, else: String.trim_trailing(plugin.id, "-adapter")
    {schemes, fields} = declared_fields(plugin.adapter_declarations, id)

    credential_fields =
      if connector && connector[:credential_fields],
        do: connector.credential_fields,
        else:
          fields
          |> Enum.filter(&LegacyConfig.credential_field?(Ankole.Attrs.get(&1, :path)))
          |> Enum.map(&field/1)

    public_fields =
      if connector && connector[:public_fields],
        do: connector.public_fields,
        else:
          fields
          |> Enum.filter(
            &(LegacyConfig.public_field?(Ankole.Attrs.get(&1, :path)) and
                not LegacyConfig.credential_field?(Ankole.Attrs.get(&1, :path)))
          )
          |> Enum.map(&field/1)

    %{
      id: id,
      plugin_id: id,
      display_name:
        label(
          if(connector,
            do: Map.get(connector, :display_name, plugin.display_name),
            else: plugin.display_name
          )
        ),
      toolkits:
        if(connector,
          do: connector.module.tools() |> Enum.map(& &1.toolkit) |> Enum.uniq(),
          else: []
        ),
      auth_schemes:
        if(connector && connector[:auth_schemes], do: connector.auth_schemes, else: schemes),
      personal_credentials:
        (connector && Map.get(connector, :personal_credentials, false)) || false,
      personal_credential_fields:
        if(connector, do: Map.get(connector, :personal_credential_fields, []), else: []),
      credential_fields: credential_fields,
      public_fields: public_fields,
      trigger_types: if(connector, do: Map.get(connector, :trigger_types, []), else: []),
      event_streams: if(connector, do: Map.get(connector, :event_streams, []), else: [])
    }
  end

  defp declared_fields(declarations, id) do
    chat = Enum.find(declarations, &(&1.contract_id == "signals.adapter"))
    identity = Enum.find(declarations, &(&1.contract_id == "principals.identity_provider"))

    if chat && identity && required_credentials(chat) != required_credentials(identity) do
      fields =
        Enum.flat_map([{chat, scheme(id)}, {identity, "identity_app"}], fn {declaration, scheme} ->
          Enum.map(Map.get(declaration, :fields, []), &Map.put(&1, :schemes, [scheme]))
        end)

      {[scheme(id), "identity_app"], fields}
    else
      {[scheme(id)],
       declarations
       |> Enum.flat_map(&Map.get(&1, :fields, []))
       |> Enum.uniq_by(&Ankole.Attrs.get(&1, :path))}
    end
  end

  defp required_credentials(declaration) do
    declaration
    |> Map.get(:fields, [])
    |> Enum.filter(
      &(Ankole.Attrs.get(&1, :required) == true and
          LegacyConfig.credential_field?(Ankole.Attrs.get(&1, :path)))
    )
    |> Enum.map(&Ankole.Attrs.get(&1, :path))
    |> Enum.sort()
  end

  defp field(field) do
    %{
      key: Ankole.Attrs.get(field, :path),
      label: label(Ankole.Attrs.get(field, :label)),
      secret: Ankole.Attrs.get(field, :encrypted) == true,
      required: Ankole.Attrs.get(field, :required) == true,
      type: Ankole.Attrs.get(field, :type) || "string",
      options: Ankole.Attrs.get(field, :options) || [],
      default: Ankole.Attrs.get(field, :default),
      schemes: Ankole.Attrs.get(field, :schemes)
    }
  end

  defp label(value) when is_binary(value), do: value
  defp label(value) when is_map(value), do: value["default"] || value["en"] || ""
  defp label(_), do: ""
  defp scheme("lark"), do: "lark_app"
  defp scheme("email"), do: "imap_smtp"
  defp scheme(_), do: "platform_app"
end
