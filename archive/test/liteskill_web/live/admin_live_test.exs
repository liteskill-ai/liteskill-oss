defmodule LiteskillWeb.AdminLiveTest do
  use ExUnit.Case, async: true

  alias LiteskillWeb.AdminLive

  describe "parse_decimal/1" do
    test "parses valid decimal string" do
      assert %Decimal{} = d = AdminLive.parse_decimal("1.23")
      assert Decimal.equal?(d, Decimal.new("1.23"))
    end

    test "parses integer string" do
      assert %Decimal{} = d = AdminLive.parse_decimal("42")
      assert Decimal.equal?(d, Decimal.new("42"))
    end

    test "returns nil for nil" do
      assert AdminLive.parse_decimal(nil) == nil
    end

    test "returns nil for empty string" do
      assert AdminLive.parse_decimal("") == nil
    end

    test "returns nil for invalid string" do
      assert AdminLive.parse_decimal("abc") == nil
    end

    test "returns nil for partial parse" do
      assert AdminLive.parse_decimal("1.23abc") == nil
    end
  end

  describe "parse_json_config/1" do
    test "parses valid JSON object" do
      assert {:ok, %{"key" => "value"}} = AdminLive.parse_json_config(~s({"key": "value"}))
    end

    test "returns empty map for nil" do
      assert {:ok, %{}} = AdminLive.parse_json_config(nil)
    end

    test "returns empty map for empty string" do
      assert {:ok, %{}} = AdminLive.parse_json_config("")
    end

    test "returns error for JSON array" do
      assert {:error, "Config must be a JSON object, not an array or scalar"} =
               AdminLive.parse_json_config("[1, 2]")
    end

    test "returns error for JSON scalar" do
      assert {:error, "Config must be a JSON object, not an array or scalar"} =
               AdminLive.parse_json_config(~s("just a string"))
    end

    test "returns error for invalid JSON" do
      assert {:error, "Invalid JSON in config field"} =
               AdminLive.parse_json_config("{bad json")
    end
  end

  describe "build_provider_attrs/2" do
    test "builds attrs from valid params" do
      user_id = Ecto.UUID.generate()

      params = %{
        "name" => "My Provider",
        "provider_type" => "bedrock",
        "provider_config_json" => ~s({"region": "us-east-1"}),
        "instance_wide" => "true",
        "status" => "active"
      }

      assert {:ok, attrs} = AdminLive.build_provider_attrs(params, user_id)
      assert attrs.name == "My Provider"
      assert attrs.provider_type == "bedrock"
      assert attrs.provider_config == %{"region" => "us-east-1"}
      assert attrs.instance_wide == true
      assert attrs.status == "active"
      assert attrs.user_id == user_id
    end

    test "includes api_key when present and non-empty" do
      params = %{
        "name" => "P",
        "provider_type" => "openai",
        "provider_config_json" => "{}",
        "instance_wide" => "false",
        "api_key" => "sk-secret"
      }

      assert {:ok, attrs} = AdminLive.build_provider_attrs(params, Ecto.UUID.generate())
      assert attrs.api_key == "sk-secret"
    end

    test "excludes api_key when nil" do
      params = %{
        "name" => "P",
        "provider_type" => "openai",
        "provider_config_json" => "{}",
        "instance_wide" => "false",
        "api_key" => nil
      }

      assert {:ok, attrs} = AdminLive.build_provider_attrs(params, Ecto.UUID.generate())
      refute Map.has_key?(attrs, :api_key)
    end

    test "excludes api_key when empty string" do
      params = %{
        "name" => "P",
        "provider_type" => "openai",
        "provider_config_json" => "{}",
        "instance_wide" => "false",
        "api_key" => ""
      }

      assert {:ok, attrs} = AdminLive.build_provider_attrs(params, Ecto.UUID.generate())
      refute Map.has_key?(attrs, :api_key)
    end

    test "returns error for invalid JSON config" do
      params = %{
        "name" => "P",
        "provider_type" => "openai",
        "provider_config_json" => "{bad",
        "instance_wide" => "false"
      }

      assert {:error, _} = AdminLive.build_provider_attrs(params, Ecto.UUID.generate())
    end

    test "defaults status to active" do
      params = %{
        "name" => "P",
        "provider_type" => "openai",
        "provider_config_json" => "{}",
        "instance_wide" => "false"
      }

      assert {:ok, attrs} = AdminLive.build_provider_attrs(params, Ecto.UUID.generate())
      assert attrs.status == "active"
    end
  end

  describe "build_model_attrs/2" do
    test "builds attrs from valid params" do
      user_id = Ecto.UUID.generate()
      provider_id = Ecto.UUID.generate()

      params = %{
        "name" => "Claude Sonnet",
        "provider_id" => provider_id,
        "model_id" => "claude-sonnet-4-5-20250929",
        "model_type" => "inference",
        "model_config_json" => ~s({"max_tokens": 4096}),
        "instance_wide" => "true",
        "status" => "active",
        "input_cost_per_million" => "3.00",
        "output_cost_per_million" => "15.00"
      }

      assert {:ok, attrs} = AdminLive.build_model_attrs(params, user_id)
      assert attrs.name == "Claude Sonnet"
      assert attrs.provider_id == provider_id
      assert attrs.model_id == "claude-sonnet-4-5-20250929"
      assert attrs.model_type == "inference"
      assert attrs.model_config == %{"max_tokens" => 4096}
      assert attrs.instance_wide == true
      assert attrs.status == "active"
      assert Decimal.equal?(attrs.input_cost_per_million, Decimal.new("3.00"))
      assert Decimal.equal?(attrs.output_cost_per_million, Decimal.new("15.00"))
      assert attrs.user_id == user_id
    end

    test "handles nil cost fields" do
      params = %{
        "name" => "M",
        "provider_id" => Ecto.UUID.generate(),
        "model_id" => "m",
        "model_config_json" => "{}",
        "instance_wide" => "false",
        "input_cost_per_million" => nil,
        "output_cost_per_million" => nil
      }

      assert {:ok, attrs} = AdminLive.build_model_attrs(params, Ecto.UUID.generate())
      assert attrs.input_cost_per_million == nil
      assert attrs.output_cost_per_million == nil
    end

    test "defaults model_type to inference" do
      params = %{
        "name" => "M",
        "provider_id" => Ecto.UUID.generate(),
        "model_id" => "m",
        "model_config_json" => "{}",
        "instance_wide" => "false",
        "input_cost_per_million" => nil,
        "output_cost_per_million" => nil
      }

      assert {:ok, attrs} = AdminLive.build_model_attrs(params, Ecto.UUID.generate())
      assert attrs.model_type == "inference"
    end

    test "returns error for invalid JSON config" do
      params = %{
        "name" => "M",
        "provider_id" => Ecto.UUID.generate(),
        "model_id" => "m",
        "model_config_json" => "[not an object]",
        "instance_wide" => "false",
        "input_cost_per_million" => nil,
        "output_cost_per_million" => nil
      }

      assert {:error, _} = AdminLive.build_model_attrs(params, Ecto.UUID.generate())
    end
  end
end
