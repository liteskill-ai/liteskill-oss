defmodule Liteskill.Usage.UsageRecordTest do
  use Liteskill.DataCase, async: false

  alias Liteskill.Usage.UsageRecord

  setup do
    {:ok, user} =
      Liteskill.Accounts.find_or_create_from_oidc(%{
        email: "usage-record-#{System.unique_integer([:positive])}@example.com",
        name: "Usage Test",
        oidc_sub: "usage-#{System.unique_integer([:positive])}",
        oidc_issuer: "https://test.example.com"
      })

    %{user: user}
  end

  describe "changeset/2" do
    test "valid changeset with required fields", %{user: user} do
      attrs = %{
        user_id: user.id,
        model_id: "claude-3-5-sonnet-20241022",
        call_type: "stream"
      }

      changeset = UsageRecord.changeset(%UsageRecord{}, attrs)
      assert changeset.valid?
    end

    test "valid changeset with all fields", %{user: user} do
      attrs = %{
        user_id: user.id,
        model_id: "claude-3-5-sonnet-20241022",
        call_type: "complete",
        input_tokens: 100,
        output_tokens: 50,
        total_tokens: 150,
        reasoning_tokens: 10,
        cached_tokens: 20,
        cache_creation_tokens: 5,
        input_cost: Decimal.new("0.001"),
        output_cost: Decimal.new("0.002"),
        reasoning_cost: Decimal.new("0.0005"),
        total_cost: Decimal.new("0.0035"),
        latency_ms: 1500,
        tool_round: 1
      }

      changeset = UsageRecord.changeset(%UsageRecord{}, attrs)
      assert changeset.valid?
    end

    test "requires user_id" do
      attrs = %{model_id: "claude-3-5-sonnet", call_type: "stream"}
      changeset = UsageRecord.changeset(%UsageRecord{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).user_id
    end

    test "requires model_id", %{user: user} do
      attrs = %{user_id: user.id, call_type: "stream"}
      changeset = UsageRecord.changeset(%UsageRecord{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).model_id
    end

    test "requires call_type", %{user: user} do
      attrs = %{user_id: user.id, model_id: "claude-3-5-sonnet"}
      changeset = UsageRecord.changeset(%UsageRecord{}, attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).call_type
    end

    test "validates call_type inclusion", %{user: user} do
      attrs = %{user_id: user.id, model_id: "claude-3-5-sonnet", call_type: "invalid"}
      changeset = UsageRecord.changeset(%UsageRecord{}, attrs)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).call_type
    end

    test "accepts stream call_type", %{user: user} do
      attrs = %{user_id: user.id, model_id: "claude-3-5-sonnet", call_type: "stream"}
      changeset = UsageRecord.changeset(%UsageRecord{}, attrs)
      assert changeset.valid?
    end

    test "accepts complete call_type", %{user: user} do
      attrs = %{user_id: user.id, model_id: "claude-3-5-sonnet", call_type: "complete"}
      changeset = UsageRecord.changeset(%UsageRecord{}, attrs)
      assert changeset.valid?
    end

    test "casts decimal fields", %{user: user} do
      attrs = %{
        user_id: user.id,
        model_id: "claude-3-5-sonnet",
        call_type: "stream",
        input_cost: "0.001",
        output_cost: "0.002",
        total_cost: "0.003"
      }

      changeset = UsageRecord.changeset(%UsageRecord{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :input_cost) == Decimal.new("0.001")
    end
  end
end
