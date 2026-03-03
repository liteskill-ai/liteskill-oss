defmodule Liteskill.OpenRouter.Models do
  @moduledoc """
  Fetches and searches the OpenRouter model catalog.
  """

  @models_url "https://openrouter.ai/api/v1/models"
  @embedding_models_url "https://openrouter.ai/api/v1/embeddings/models"

  @doc """
  Fetches the full list of models from OpenRouter.

  Returns `{:ok, [model_map]}` or `{:error, reason}`.
  Each model map contains: `:id`, `:name`, `:context_length`,
  `:input_cost_per_million`, `:output_cost_per_million`, `:model_type`.
  """
  def list_models(opts \\ []) do
    req_opts =
      [url: @models_url]
      |> Keyword.merge(test_plug_opts())
      |> Keyword.merge(opts)

    case Req.get(Req.new(retry: false), req_opts) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data}}} when is_list(data) ->
        models =
          data
          |> Enum.map(&parse_model/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1.name)

        {:ok, models}

      {:ok, %Req.Response{status: status}} ->
        {:error, "OpenRouter returned status #{status}"}

      {:error, reason} ->
        {:error, "OpenRouter request failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Fetches the list of embedding models from OpenRouter's dedicated endpoint.

  Returns `{:ok, [model_map]}` or `{:error, reason}`.
  All returned models have `model_type: "embedding"`.
  """
  def list_embedding_models(opts \\ []) do
    req_opts =
      [url: @embedding_models_url]
      |> Keyword.merge(test_plug_opts())
      |> Keyword.merge(opts)

    case Req.get(Req.new(retry: false), req_opts) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data}}} when is_list(data) ->
        models =
          data
          |> Enum.map(&parse_model/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&Map.put(&1, :model_type, "embedding"))
          |> Enum.sort_by(& &1.name)

        {:ok, models}

      {:ok, %Req.Response{status: status}} ->
        {:error, "OpenRouter returned status #{status}"}

      {:error, reason} ->
        {:error, "OpenRouter request failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Filters a list of models by substring match on id or name (case-insensitive).
  Returns at most `limit` results (default 10).
  """
  def search_models(models, query, limit \\ 10) do
    q = String.downcase(query)

    models
    |> Enum.filter(fn m ->
      String.contains?(String.downcase(m.id), q) ||
        String.contains?(String.downcase(m.name), q)
    end)
    |> Enum.take(limit)
  end

  defp parse_model(%{"id" => id, "name" => name} = model) do
    pricing = model["pricing"] || %{}

    %{
      id: id,
      name: name,
      context_length: model["context_length"],
      input_cost_per_million: parse_cost(pricing["prompt"]),
      output_cost_per_million: parse_cost(pricing["completion"]),
      model_type: infer_model_type(model)
    }
  end

  defp parse_model(_), do: nil

  defp parse_cost(nil), do: nil

  defp parse_cost(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, _} -> Decimal.mult(decimal, Decimal.new("1000000"))
      :error -> nil
    end
  end

  defp parse_cost(value) when is_number(value) do
    Decimal.mult(Decimal.from_float(value * 1.0), Decimal.new("1000000"))
  end

  defp parse_cost(_), do: nil

  defp infer_model_type(%{"architecture" => %{"modality" => modality}}) when is_binary(modality) do
    if String.contains?(modality, "embedding"), do: "embedding", else: "inference"
  end

  defp infer_model_type(_), do: "inference"

  defp test_plug_opts do
    if Application.get_env(:liteskill, :env) == :test do
      [plug: {Req.Test, __MODULE__}]
    else
      # coveralls-ignore-start
      []
      # coveralls-ignore-stop
    end
  end
end
