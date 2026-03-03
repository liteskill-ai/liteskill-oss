defmodule LiteskillWeb.E2E.RegistrationTest do
  use LiteskillWeb.FeatureCase, async: false

  test "successful registration redirects to home", %{session: session} do
    session
    |> visit("/register")
    |> take_screenshot(name: "registration/successful_registration/form")
    |> fill_in(Query.css("#user_name"), with: "New User")
    |> fill_in(Query.css("#user_email"), with: "newuser@example.com")
    |> fill_in(Query.css("#user_password"), with: "ValidPassword123!")
    |> click(Query.button("Register"))
    |> assert_has(Query.css("h1", text: "What can I help you with?"))
    |> take_screenshot(name: "registration/successful_registration/success_home")
  end

  test "duplicate email shows error", %{session: session} do
    %{email: email} = create_user()

    session
    |> visit("/register")
    |> fill_in(Query.css("#user_name"), with: "Another User")
    |> fill_in(Query.css("#user_email"), with: email)
    |> fill_in(Query.css("#user_password"), with: "ValidPassword123!")
    |> click(Query.button("Register"))
    |> assert_has(Query.css("p.text-error", text: "has already been taken"))
    |> take_screenshot(name: "registration/duplicate_email/error")
  end
end
