defmodule Ankole.AIGateway.CapabilityUsageTest do
  use Ankole.AIGatewayCase

  import Ecto.Query

  alias Ankole.AIGateway.ModelMetadata.Cache, as: ModelMetadataCache
  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.AIGateway.UsageLedger

  @png_base64 "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="

  test "a generated image is a ledger row that token readers leave out" do
    %{principal: agent} = agent_fixture()
    provider_id = "openrouter-image-usage-#{System.unique_integer([:positive])}"
    since = DateTime.add(DateTime.utc_now(), -60, :second)
    signal_id = Ankole.Ecto.UUIDv7.autogenerate()

    base_url =
      start_upstream_server(fn %{path: "api/v1/images"} ->
        {:json, 200,
         %{
           "data" => [%{"b64_json" => @png_base64, "media_type" => "image/png"}],
           "usage" => %{"prompt_tokens" => 9, "completion_tokens" => 4175, "cost" => 0.04}
         }}
      end)

    assert {:ok, provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openrouter",
               base_url: base_url <> "/api/v1",
               credential_pool: %{"entries" => [%{"label" => "Images", "api_key" => "sk-or"}]},
               connection_options: %{"transport" => %{}}
             })

    :ok =
      ModelMetadataCache.put(
        {:image_model_catalog, provider_id, provider.updated_at, "images/models"},
        [%{"id" => "openai/gpt-image-1"}],
        60_000
      )

    :ok =
      ModelMetadataCache.put(
        {:image_model_endpoints, provider_id, provider.updated_at,
         "images/models/openai/gpt-image-1/endpoints"},
        [
          %{
            "provider_slug" => "openai",
            "provider_tag" => "openai/gpt-image-1:openai",
            "supported_parameters" => %{}
          }
        ],
        60_000
      )

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "image_generate", %{
               provider_id: provider_id,
               model: "openai/gpt-image-1"
             })

    assert {:ok, _image} =
             AIGateway.create_image(
               agent.uid,
               %{"model" => "image_generate.default", "prompt" => "Mountain sunrise"},
               subject_type: "agent",
               request_context: %{"signal_id" => signal_id, "session_id" => "session-1"}
             )

    assert [%UsageRecord{} = row] = UsageRecord |> order_by(:id) |> Repo.all()
    assert row.capability == :image_generate
    assert {row.unit, row.quantity} == {:image, 1}
    assert Decimal.equal?(row.provider_cost, Decimal.new("0.04"))
    assert {row.input_tokens, row.output_tokens} == {9, 4175}
    assert row.origin == :agent
    assert row.subject_uid == agent.uid
    assert row.model == "#{provider_id}/openai/gpt-image-1"
    assert row.model_profile == "image_generate"
    assert {row.signal_id, row.session_id} == {signal_id, "session-1"}

    # Image tokens are not language-model tokens, so no token reader counts them.
    assert UsageLedger.window_tokens(agent.uid, since) == 0
    assert AIGateway.turn_usage(signal_id) == nil
    assert UsageLedger.window_summary(since).total.rounds == 0
  end

  test "a call that names no caller writes no row" do
    assert :ok =
             UsageLedger.record_capability(
               %{"capability" => "image_generate", "subject_uid" => "agent"},
               nil,
               %{"usage" => %{}}
             )

    assert Repo.aggregate(UsageRecord, :count) == 0
  end
end
