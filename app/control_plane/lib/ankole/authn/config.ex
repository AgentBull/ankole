defmodule Ankole.Authn.Config do
  @moduledoc "Site authentication mail transport and verification limits."
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Schema

  def definitions do
    [definition("mail", Schema.new(&mail/1), nil, true)] ++
      Enum.map(
        [
          {"code_ttl_seconds", 600},
          {"send_window_seconds", 60},
          {"send_email_limit", 3},
          {"send_source_limit", 20},
          {"send_channel_limit", 100},
          {"failure_window_seconds", 600},
          {"failure_email_limit", 10},
          {"failure_source_limit", 100}
        ],
        fn {name, default} -> definition(name, Schema.new(&positive_integer/1), default) end
      )
  end

  def get(name) do
    definition = Enum.find(definitions(), &(&1.key == "authn.email." <> name))

    if Ankole.Repo.in_transaction?(),
      do: AppConfigure.get_in_tx(definition, scope: :global),
      else: AppConfigure.get(definition, scope: :global)
  end

  def put_mail(settings), do: AppConfigure.put_global_by_key("authn.email.mail", settings)

  defp definition(name, schema, default, encrypted \\ false) do
    AppConfigure.define(
      key: "authn.email." <> name,
      scope: :global,
      encrypted: encrypted,
      schema: schema,
      default_value: default,
      description: "Site authentication email: #{name}."
    )
  end

  def mail(nil), do: {:ok, nil}

  def mail(%{"server" => server, "from" => from} = settings)
      when is_binary(server) and is_binary(from) do
    port = Map.get(settings, "port", 587)
    ssl = Map.get(settings, "ssl", false)
    optional = ["username", "password", "cacertfile"]

    if Schema.json_value?(settings) and String.trim(server) != "" and
         Regex.match?(~r/\A[^\s@]+@[^\s@]+\.[^\s@]+\z/, from) and
         is_integer(port) and port in 1..65_535 and is_boolean(ssl) and
         Enum.all?(optional, &(is_nil(settings[&1]) or is_binary(settings[&1]))) do
      {:ok, settings}
    else
      {:error, :invalid_mail_configuration}
    end
  end

  def mail(_), do: {:error, :invalid_mail_configuration}

  defp positive_integer(value) when is_integer(value) and value > 0 and value <= 86_400,
    do: {:ok, value}

  defp positive_integer(_), do: {:error, :invalid_positive_integer}
end
