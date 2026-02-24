defmodule LiteskillWeb.AdminLive.Helpers do
  @moduledoc false

  def require_admin(socket, fun) do
    if Liteskill.Rbac.has_any_admin_permission?(socket.assigns.current_user.id) do
      fun.()
    else
      {:noreply, socket}
    end
  end

  def build_provider_attrs(params, user_id) do
    with {:ok, provider_config} <- parse_json_config(params["provider_config_json"]) do
      attrs = %{
        name: params["name"],
        provider_type: params["provider_type"],
        provider_config: provider_config,
        instance_wide: params["instance_wide"] == "true",
        status: params["status"] || "active",
        user_id: user_id
      }

      attrs =
        case params["api_key"] do
          nil -> attrs
          "" -> attrs
          key -> Map.put(attrs, :api_key, key)
        end

      {:ok, attrs}
    end
  end

  def build_model_attrs(params, user_id) do
    with {:ok, model_config} <- parse_json_config(params["model_config_json"]) do
      {:ok,
       %{
         name: params["name"],
         provider_id: params["provider_id"],
         model_id: params["model_id"],
         model_type: params["model_type"] || "inference",
         model_config: model_config,
         instance_wide: params["instance_wide"] == "true",
         status: params["status"] || "active",
         input_cost_per_million: parse_decimal(params["input_cost_per_million"]),
         output_cost_per_million: parse_decimal(params["output_cost_per_million"]),
         user_id: user_id
       }}
    end
  end

  def parse_decimal(nil), do: nil
  def parse_decimal(""), do: nil

  def parse_decimal(val) when is_binary(val) do
    case Decimal.parse(val) do
      {d, ""} -> d
      _ -> nil
    end
  end

  def parse_json_config(nil), do: {:ok, %{}}
  def parse_json_config(""), do: {:ok, %{}}

  def parse_json_config(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _} -> {:error, "Config must be a JSON object, not an array or scalar"}
      {:error, _} -> {:error, "Invalid JSON in config field"}
    end
  end
end
