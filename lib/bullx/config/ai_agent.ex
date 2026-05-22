defmodule BullX.Config.AIAgent do
  @moduledoc """
  Runtime configuration keys used by AIAgent support code.
  """

  use BullX.Config

  @envdoc false
  bullx_env(:web_provider,
    key: [:ai_agent, :web, :provider],
    type: :binary,
    default: nil
  )

  @envdoc false
  bullx_env(:web_search_provider,
    key: [:ai_agent, :web, :search_provider],
    type: :binary,
    default: nil
  )

  @envdoc false
  bullx_env(:web_extract_provider,
    key: [:ai_agent, :web, :extract_provider],
    type: :binary,
    default: nil
  )

  @envdoc false
  bullx_env(:web_exa_api_key,
    key: [:ai_agent, :web, :exa, :api_key],
    type: :binary,
    default: nil,
    secret: true
  )

  @envdoc false
  bullx_env(:web_tavily_api_key,
    key: [:ai_agent, :web, :tavily, :api_key],
    type: :binary,
    default: nil,
    secret: true
  )

  @envdoc false
  bullx_env(:web_serpapi_api_key,
    key: [:ai_agent, :web, :serpapi, :api_key],
    type: :binary,
    default: nil,
    secret: true
  )

  @envdoc false
  bullx_env(:web_jina_api_key,
    key: [:ai_agent, :web, :jina, :api_key],
    type: :binary,
    default: nil,
    secret: true
  )
end
