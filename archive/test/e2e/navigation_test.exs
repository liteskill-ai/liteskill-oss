defmodule LiteskillWeb.E2E.NavigationTest do
  use LiteskillWeb.FeatureCase, async: false

  test "unauthenticated user is redirected to login", %{session: session} do
    session
    |> visit("/")
    |> assert_has(Query.button("Sign In"))
    |> take_screenshot(name: "navigation/unauthenticated_redirect/login_page")
  end

  test "authenticated user can navigate to profile", %{session: session} do
    register_user(session)

    # Wait for home page to fully render
    assert_has(session, Query.css("h1", text: "What can I help you with?"))

    # Click the user email link in the sidebar to navigate to profile
    session
    |> find(Query.css("a[href='/profile']"))
    |> Element.click()

    session
    |> assert_has(Query.css("h1", text: "Profile"))
    |> take_screenshot(name: "navigation/navigate_to_profile/profile_page")
  end
end
