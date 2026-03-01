defmodule LiteskillWeb.ChatLive.CostHandlerTest do
  use ExUnit.Case, async: true

  alias LiteskillWeb.ChatLive.CostHandler

  @models [%{id: "m1", name: "Model 1", input_cost_per_million: Decimal.new("3.00")}]

  describe "assigns/0" do
    test "returns expected default assigns" do
      assigns = CostHandler.assigns()
      assert Keyword.get(assigns, :cost_limit) == nil
      assert Keyword.get(assigns, :cost_limit_input) == ""
      assert Keyword.get(assigns, :cost_limit_tokens) == nil
      assert Keyword.get(assigns, :show_cost_popover) == false
      assert Keyword.get(assigns, :show_usage_modal) == false
      assert Keyword.get(assigns, :usage_modal_data) == nil
      assert Keyword.get(assigns, :available_llm_models) == []
      assert Keyword.get(assigns, :selected_llm_model_id) == nil
    end
  end

  describe "events/0" do
    test "returns all cost/model events" do
      events = CostHandler.events()
      assert "select_llm_model" in events
      assert "toggle_cost_popover" in events
      assert "update_cost_limit" in events
      assert "clear_cost_limit" in events
      assert "show_usage_modal" in events
      assert "close_usage_modal" in events
    end
  end

  describe "handle_event toggle_cost_popover" do
    test "toggles popover open" do
      socket = build_socket(%{show_cost_popover: false})

      {:noreply, socket} = CostHandler.handle_event("toggle_cost_popover", %{}, socket)

      assert socket.assigns.show_cost_popover == true
    end

    test "toggles popover closed" do
      socket = build_socket(%{show_cost_popover: true})

      {:noreply, socket} = CostHandler.handle_event("toggle_cost_popover", %{}, socket)

      assert socket.assigns.show_cost_popover == false
    end
  end

  describe "handle_event update_cost_limit with cost" do
    test "clears cost limit when cost is empty" do
      socket = build_socket(%{cost_limit: Decimal.new("1.00")})

      {:noreply, socket} =
        CostHandler.handle_event("update_cost_limit", %{"cost" => ""}, socket)

      assert socket.assigns.cost_limit == nil
      assert socket.assigns.cost_limit_input == ""
      assert socket.assigns.cost_limit_tokens == nil
    end

    test "sets cost limit and calculates tokens" do
      socket =
        build_socket(%{
          selected_llm_model_id: "m1",
          available_llm_models: @models
        })

      {:noreply, socket} =
        CostHandler.handle_event(
          "update_cost_limit",
          %{"cost" => "1.50", "_target" => ["cost"]},
          socket
        )

      assert Decimal.equal?(socket.assigns.cost_limit, Decimal.new("1.50"))
      assert socket.assigns.cost_limit_input == "1.50"
      assert is_integer(socket.assigns.cost_limit_tokens)
    end

    test "ignores non-cost target" do
      socket = build_socket(%{cost_limit: nil})

      {:noreply, socket} =
        CostHandler.handle_event(
          "update_cost_limit",
          %{"cost" => "1.50", "_target" => ["other"]},
          socket
        )

      assert socket.assigns.cost_limit == nil
    end

    test "ignores invalid cost string" do
      socket = build_socket(%{cost_limit: nil})

      {:noreply, socket} =
        CostHandler.handle_event(
          "update_cost_limit",
          %{"cost" => "abc", "_target" => ["cost"]},
          socket
        )

      assert socket.assigns.cost_limit == nil
    end
  end

  describe "handle_event update_cost_limit with tokens" do
    test "clears cost limit when tokens is empty" do
      socket = build_socket(%{cost_limit: Decimal.new("1.00")})

      {:noreply, socket} =
        CostHandler.handle_event("update_cost_limit", %{"tokens" => ""}, socket)

      assert socket.assigns.cost_limit == nil
      assert socket.assigns.cost_limit_tokens == nil
    end

    test "sets tokens and calculates cost" do
      socket =
        build_socket(%{
          selected_llm_model_id: "m1",
          available_llm_models: @models
        })

      {:noreply, socket} =
        CostHandler.handle_event(
          "update_cost_limit",
          %{"tokens" => "500000", "_target" => ["tokens"]},
          socket
        )

      assert socket.assigns.cost_limit_tokens == 500_000
      assert socket.assigns.cost_limit
      assert socket.assigns.cost_limit_input != ""
    end

    test "ignores non-positive tokens" do
      socket = build_socket(%{cost_limit_tokens: nil})

      {:noreply, socket} =
        CostHandler.handle_event(
          "update_cost_limit",
          %{"tokens" => "0", "_target" => ["tokens"]},
          socket
        )

      assert socket.assigns.cost_limit_tokens == nil
    end

    test "ignores non-tokens target" do
      socket = build_socket(%{cost_limit_tokens: nil})

      {:noreply, socket} =
        CostHandler.handle_event(
          "update_cost_limit",
          %{"tokens" => "1000", "_target" => ["other"]},
          socket
        )

      assert socket.assigns.cost_limit_tokens == nil
    end
  end

  describe "handle_event clear_cost_limit" do
    test "clears all cost-related assigns and closes popover" do
      socket =
        build_socket(%{
          cost_limit: Decimal.new("1.00"),
          cost_limit_input: "1.00",
          cost_limit_tokens: 333_333,
          show_cost_popover: true
        })

      {:noreply, socket} = CostHandler.handle_event("clear_cost_limit", %{}, socket)

      assert socket.assigns.cost_limit == nil
      assert socket.assigns.cost_limit_input == ""
      assert socket.assigns.cost_limit_tokens == nil
      assert socket.assigns.show_cost_popover == false
    end
  end

  describe "handle_event close_usage_modal" do
    test "closes usage modal" do
      socket = build_socket(%{show_usage_modal: true})

      {:noreply, socket} = CostHandler.handle_event("close_usage_modal", %{}, socket)

      assert socket.assigns.show_usage_modal == false
    end
  end

  describe "handle_event show_usage_modal" do
    test "no-op when no conversation" do
      socket = build_socket(%{conversation: nil, show_usage_modal: false})

      {:noreply, socket} = CostHandler.handle_event("show_usage_modal", %{}, socket)

      assert socket.assigns.show_usage_modal == false
    end
  end

  # --- Test helpers ---

  defp build_socket(extra_assigns) do
    base = %{
      __changed__: %{},
      cost_limit: nil,
      cost_limit_input: "",
      cost_limit_tokens: nil,
      show_cost_popover: false,
      show_usage_modal: false,
      usage_modal_data: nil,
      available_llm_models: [],
      selected_llm_model_id: nil,
      conversation: nil,
      flash: %{}
    }

    assigns = Map.merge(base, extra_assigns)
    %Phoenix.LiveView.Socket{assigns: assigns}
  end
end
