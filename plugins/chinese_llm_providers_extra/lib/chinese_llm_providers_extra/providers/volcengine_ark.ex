defmodule ChineseLLMProvidersExtra.Providers.VolcengineArk do
  @moduledoc """
  Volcengine Ark provider for OpenAI-compatible chat endpoints.

  Ark's wire format matches OpenAI's Chat Completions API. The only provider
  specialization is the provider identity and default base URL.
  """

  use ReqLLM.Provider,
    id: :volcengine_ark,
    default_base_url: "https://ark.cn-beijing.volces.com/api/v3",
    default_env_key: "ARK_API_KEY"

  @provider_schema []
end
