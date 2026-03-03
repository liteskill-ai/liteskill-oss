defmodule LiteskillWeb.E2E.LoginTest do
  use LiteskillWeb.FeatureCase, async: false

  test "valid login redirects to home", %{session: session} do
    %{email: email, password: password} = create_user()

    session
    |> visit("/login")
    |> take_screenshot(name: "login/valid_login/form")
    |> fill_in(Query.css("#user_email"), with: email)
    |> fill_in(Query.css("#user_password"), with: password)
    |> click(Query.button("Sign In"))
    |> assert_has(Query.css("h1", text: "What can I help you with?"))
    |> take_screenshot(name: "login/valid_login/success_home")
  end

  test "invalid password shows error", %{session: session} do
    %{email: email} = create_user()

    session
    |> visit("/login")
    |> fill_in(Query.css("#user_email"), with: email)
    |> fill_in(Query.css("#user_password"), with: "WrongPassword999!")
    |> click(Query.button("Sign In"))
    |> assert_has(Query.css("p.text-error", text: "Invalid email or password"))
    |> take_screenshot(name: "login/invalid_password/error")
  end
end
