defmodule Liteskill.LLM.Provider do
  @moduledoc """
  Behaviour for LLM provider clients.

  Abstracts the streaming and non-streaming conversation APIs so that
  StreamHandler is not coupled to a specific provider (e.g. Bedrock).
  """

  @type model_id :: String.t()
  @type messages :: [map()]
  @type callback :: ({atom(), map()} -> any())

  @callback converse(model_id(), messages(), keyword()) ::
              {:ok, map()} | {:error, any()}

  @callback converse_stream(model_id(), messages(), callback(), keyword()) ::
              :ok | {:error, any()}
end
