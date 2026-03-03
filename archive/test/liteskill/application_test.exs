defmodule Liteskill.ApplicationTest do
  use ExUnit.Case, async: true

  describe "config_change/3" do
    test "delegates to endpoint config_change" do
      assert :ok = Liteskill.Application.config_change([], [], [])
    end
  end
end
