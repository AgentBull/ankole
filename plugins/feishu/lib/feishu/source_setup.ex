defmodule Feishu.SourceSetup do
  @moduledoc false

  alias BullX.EventBus.RoutingContext
  alias Feishu.Source

  @credentials_key "bullx.plugins.feishu.credentials"
  @sources_key "bullx.plugins.feishu.eventbus_sources"
  @generated_secret_fields [["credentials", "verification_token"]]

  @spec config_keys() :: %{credentials: String.t(), sources: String.t()}
  def config_keys, do: %{credentials: @credentials_key, sources: @sources_key}

  @spec form_schema() :: map()
  def form_schema do
    %{
      adapter_id: "feishu",
      label: "Feishu / Lark",
      help_url: "https://open.feishu.cn/document/home/index",
      default_source: %{
        "id" => "main",
        "credential_id" => "default",
        "enabled" => true,
        "domain" => "feishu",
        "web_login_disabled" => false,
        "oidc" => %{"enabled" => true},
        "im_listen_mode" => "addressed_only",
        "start_transport" => true
      },
      sections: [
        %{
          key: "source",
          fields: [
            %{path: ["source", "id"], kind: :text, required: true},
            %{
              path: ["source", "domain"],
              kind: :select,
              required: true,
              options: ["feishu", "lark"]
            },
            %{path: ["source", "connected_realm_ref"], kind: :text},
            %{path: ["source", "web_login_disabled"], kind: :boolean},
            %{path: ["source", "oidc", "enabled"], kind: :boolean},
            %{path: ["source", "oidc", "redirect_uri"], kind: :text},
            %{
              path: ["source", "im_listen_mode"],
              kind: :select,
              options: ["addressed_only", "all_messages"]
            },
            %{path: ["source", "start_transport"], kind: :boolean}
          ]
        },
        %{
          key: "credentials",
          fields: [
            %{path: ["credentials", "credential_id"], kind: :text, required: true},
            %{path: ["credentials", "app_id"], kind: :text, required: true},
            %{path: ["credentials", "app_secret"], kind: :secret, required: true},
            %{path: ["credentials", "verification_token"], kind: :generated_secret},
            %{path: ["credentials", "encrypt_key"], kind: :secret}
          ]
        }
      ]
    }
  end

  @spec public_projection() :: map()
  def public_projection do
    credentials = Feishu.Config.credentials!()
    configured_sources = Feishu.Config.eventbus_sources!()
    runtime = runtime_status()

    %{
      adapter_id: "feishu",
      credentials: public_credentials(credentials),
      sources: Enum.map(configured_sources, &public_source(&1, runtime))
    }
  end

  @spec cast_credentials(map()) :: {:ok, map()} | {:error, map()}
  def cast_credentials(payload) when is_map(payload) do
    credentials = payload_map(payload, "credentials")
    credential_id = string_field(credentials, "credential_id", "default")

    with {:ok, app_id} <- required_string(credentials, "app_id"),
         {:ok, app_secret} <- secret_or_existing(credential_id, credentials, "app_secret") do
      profile =
        %{
          "app_id" => app_id,
          "app_secret" => app_secret,
          "app_type" => string_field(credentials, "app_type", "self_built")
        }
        |> maybe_put("verification_token", string_field(credentials, "verification_token", nil))
        |> maybe_put("encrypt_key", string_field(credentials, "encrypt_key", nil))

      merged =
        Feishu.Config.credentials!()
        |> Map.put(credential_id, profile)

      case Feishu.Config.Credentials.cast(merged) do
        {:ok, normalized} -> {:ok, normalized}
        :error -> {:error, %{field: "credentials", message: "invalid Feishu credentials"}}
      end
    end
  end

  @spec cast_source(map(), map()) :: {:ok, map()} | {:error, map()}
  def cast_source(payload, credentials) when is_map(payload) and is_map(credentials) do
    source = payload_map(payload, "source")
    oidc = payload_map(source, "oidc")
    credentials_payload = payload_map(payload, "credentials")
    credential_id = string_field(credentials_payload, "credential_id", "default")

    attrs =
      %{
        "id" => string_field(source, "id", "main"),
        "credential_id" => credential_id,
        "enabled" => boolean_field(source, "enabled", true),
        "domain" => string_field(source, "domain", "feishu"),
        "connected_realm_ref" => string_field(source, "connected_realm_ref", nil),
        "web_login_disabled" => boolean_field(source, "web_login_disabled", false),
        "oidc" =>
          %{"enabled" => boolean_field(oidc, "enabled", true)}
          |> maybe_put("redirect_uri", string_field(oidc, "redirect_uri", nil)),
        "im_listen_mode" => string_field(source, "im_listen_mode", "addressed_only"),
        "start_transport" => boolean_field(source, "start_transport", true)
      }
      |> maybe_put("tenant_key", string_field(source, "tenant_key", nil))

    case Feishu.Config.EventBusSources.cast([attrs]) do
      {:ok, [normalized]} -> {:ok, normalized}
      :error -> {:error, %{field: "source", message: "invalid Feishu source"}}
    end
  end

  @spec generated_secret_fields() :: [[String.t()]]
  def generated_secret_fields, do: @generated_secret_fields

  @spec connectivity_check(map()) :: {:ok, map()} | {:error, map()}
  def connectivity_check(source) when is_map(source) do
    Source.connectivity_check(source)
  end

  @spec routing_sample(map()) :: {:ok, map()} | {:error, map()}
  def routing_sample(source) when is_map(source) do
    id = Map.get(source, "id") || Map.get(source, :id)

    %{
      "id" => "setup-routing-sample",
      "source" => "feishu://#{id}",
      "type" => "bullx.im.message.addressed",
      "time" => DateTime.utc_now(:microsecond) |> DateTime.to_iso8601(),
      "data" => %{
        "channel" => %{"adapter" => "feishu", "id" => id},
        "scope" => %{"id" => "setup-scope", "thread_id" => nil},
        "actor" => %{"external_id" => "setup-operator"},
        "refs" => %{},
        "reply_channel" => %{"adapter" => "feishu", "source_id" => id},
        "routing_facts" => %{"chat_type" => "p2p"}
      }
    }
    |> RoutingContext.project()
    |> then(&{:ok, &1})
  end

  @spec reconcile_sources() :: {:ok, map()} | {:error, term()}
  def reconcile_sources, do: Feishu.SourceSupervisor.reconcile_sources()

  defp public_credentials(credentials) do
    Map.new(credentials, fn {id, profile} ->
      {id,
       %{
         "id" => id,
         "app_id" => Map.get(profile, "app_id"),
         "app_secret" => secret_status(profile["app_secret"]),
         "verification_token" => secret_status(profile["verification_token"]),
         "encrypt_key" => secret_status(profile["encrypt_key"])
       }}
    end)
  end

  defp public_source(source, runtime) do
    source
    |> Source.public_config()
    |> Map.put("runtime", runtime_for_source(runtime, source["id"]))
  end

  defp runtime_status do
    case Feishu.SourceSupervisor.runtime_status() do
      {:ok, status} -> status
      {:error, reason} -> %{ready?: false, error: inspect(reason), sources: []}
    end
  end

  defp runtime_for_source(%{sources: sources}, id) do
    Enum.find(sources, %{"ready" => false}, fn source ->
      Map.get(source, :id) == id or Map.get(source, "id") == id
    end)
  end

  defp runtime_for_source(_runtime, _id), do: %{"ready" => false}

  defp payload_map(payload, key) do
    case Map.get(payload, key) || Map.get(payload, String.to_atom(key)) do
      %{} = value -> stringify_keys(value)
      _other -> %{}
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp required_string(map, key) do
    case string_field(map, key, nil) do
      value when is_binary(value) -> {:ok, value}
      nil -> {:error, %{field: key, message: "is required"}}
    end
  end

  defp secret_or_existing(credential_id, map, key) do
    case string_field(map, key, nil) do
      value when is_binary(value) ->
        {:ok, value}

      nil ->
        case get_in(Feishu.Config.credentials!(), [credential_id, key]) do
          value when is_binary(value) -> {:ok, value}
          _value -> {:error, %{field: key, message: "is required"}}
        end
    end
  end

  defp string_field(map, key, default) do
    case Map.get(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> default
          trimmed -> trimmed
        end

      nil ->
        default

      value ->
        to_string(value)
    end
  end

  defp boolean_field(map, key, default) do
    case Map.get(map, key) do
      value when is_boolean(value) -> value
      "true" -> true
      "false" -> false
      nil -> default
      _value -> default
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp secret_status(value) when is_binary(value) and value != "",
    do: %{"present" => true, "masked" => "******"}

  defp secret_status(_value), do: %{"present" => false}
end
