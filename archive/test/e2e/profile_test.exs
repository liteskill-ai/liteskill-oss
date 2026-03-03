defmodule LiteskillWeb.E2E.ProfileTest do
  use LiteskillWeb.FeatureCase, async: false

  test "user can change password", %{session: session} do
    %{password: old_password} = register_user(session)

    session
    |> visit("/profile/password")
    |> assert_has(Query.css("h2", text: "Change Password"))
    |> take_screenshot(name: "profile/change_password/form")
    |> fill_in(Query.css("input[name='password[current]']"), with: old_password)
    |> fill_in(Query.css("input[name='password[new]']"), with: "NewSecurePassword456!")
    |> fill_in(Query.css("input[name='password[confirm]']"), with: "NewSecurePassword456!")
    |> click(Query.button("Update Password"))
    |> assert_has(Query.css("p.text-success", text: "Password changed successfully."))
    |> take_screenshot(name: "profile/change_password/changed")
  end
end
