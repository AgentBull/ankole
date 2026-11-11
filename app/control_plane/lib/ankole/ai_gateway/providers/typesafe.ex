defmodule Ankole.AIGateway.Providers.TypeSafe do
  @moduledoc """
  TypeSafe and compatible SystemOne decision-model endpoints.
  """

  use Ankole.AIGateway.ProviderDSL

  alias Ankole.AIGateway.OpenAIError
  alias Ankole.AIGateway.UniversalAIRequest

  provider :typesafe do
    label(%{"default" => "TypeSafe (SystemOne)", "zh-Hans-CN" => "TypeSafe（SystemOne 兼容）"})
    base_url("https://api.typesafe.ai/v1")

    setting(:api_key, encrypted: true, scope: :credential)

    setting(:auth_scheme,
      type: :select,
      default: "bearer",
      options: ~w(bearer api_key),
      scope: :credential,
      advanced: true
    )

    setting(:allow_images, type: :boolean, default: true, advanced: true)
    setting(:headers, type: :map, advanced: true)
    setting(:query_params, type: :map, advanced: true)
    setting(:longContext, type: :boolean, scope: :request, advanced: true)

    decision_model do
      api_resolver(:systemone_decision)
      prepare(:prepare_decision_model)
    end
  end

  @doc "Builds a SystemOne request for TypeSafe or a compatible endpoint."
  def prepare_decision_model(ctx) do
    with :ok <- validate_images(ctx) do
      ctx = put_in(ctx.settings[:base_url], systemone_base_url(ctx.settings[:base_url]))

      ctx
      |> UniversalAIRequest.new("systemone", :systemone_decision)
      |> UniversalAIRequest.put_provider_options(Map.delete(ctx.provider_options, "longContext"))
      |> UniversalAIRequest.put_client_identity_headers(ctx)
      |> put_auth(ctx)
      |> put_decision_headers(ctx)
    end
  end

  @impl true
  def models_metadata_source(ctx) when is_map(ctx) do
    ctx = put_in(ctx.settings[:base_url], systemone_base_url(ctx.settings[:base_url]))

    headers =
      ctx
      |> UniversalAIRequest.raw_headers()
      |> put_auth(ctx)

    {:ok,
     {:typesafe,
      %{
        ctx: ctx,
        path: "models",
        headers: headers,
        cache_key: "models",
        allow_images: ctx.settings[:allow_images] != false
      }}}
  end

  defp systemone_base_url(base_url) when is_binary(base_url) do
    base_url
    |> String.trim_trailing("/")
    |> String.replace_suffix("/systemone", "")
  end

  defp systemone_base_url(base_url), do: base_url

  defp put_auth(request_or_headers, ctx) do
    case ctx.settings[:auth_scheme] do
      scheme when scheme in ["api_key", :api_key] ->
        UniversalAIRequest.api_key_header(request_or_headers, "api-key", ctx.settings[:api_key])

      _bearer ->
        UniversalAIRequest.bearer_auth(request_or_headers, ctx.settings[:api_key])
    end
  end

  defp put_decision_headers(request, ctx) do
    request
    |> maybe_put_images_header(ctx.request)
    |> maybe_put_long_context_header(ctx.provider_options)
  end

  defp maybe_put_images_header(request, %{"images" => images})
       when is_list(images) and images != [],
       do: UniversalAIRequest.put_header(request, "TypeSafe-Danger-Zone-Images", "true")

  defp maybe_put_images_header(request, _request), do: request

  defp maybe_put_long_context_header(request, %{"longContext" => true}),
    do: UniversalAIRequest.put_header(request, "TypeSafe-Danger-Zone-Long-Context", "true")

  defp maybe_put_long_context_header(request, _options), do: request

  defp validate_images(ctx) do
    images = Map.get(ctx.request, "images", [])

    cond do
      images != [] and ctx.settings[:allow_images] == false ->
        unsupported_images("The configured SystemOne endpoint does not accept images.")

      Enum.any?(images, &String.starts_with?(&1, "data:image/webp;base64,")) ->
        unsupported_images("SystemOne decision models accept only PNG and JPEG images.")

      true ->
        :ok
    end
  end

  defp unsupported_images(message) do
    {:error, OpenAIError.invalid("images", "unsupported_value", message)}
  end
end
