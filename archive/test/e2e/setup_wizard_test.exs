defmodule LiteskillWeb.E2E.SetupWizardTest do
  use LiteskillWeb.FeatureCase, async: false

  @password "SecurePass123!!"

  describe "setup wizard walk-through" do
    test "skip all optional steps, then login with new password", %{session: session} do
      create_setup_admin()

      # Step 1: Password
      session
      |> visit("/setup")
      |> assert_has(Query.css("h2", text: "Welcome to Liteskill"))
      |> take_screenshot(name: "setup_wizard/skip_all_steps/01_password_step")
      |> fill_in(Query.css("[name='setup[password]']"), with: @password)
      |> fill_in(Query.css("[name='setup[password_confirmation]']"), with: @password)
      |> click(Query.button("Set Password & Continue"))

      # Step 2: Permissions — skip
      |> assert_has(Query.css("h2", text: "Default User Permissions"))
      |> take_screenshot(name: "setup_wizard/skip_all_steps/02_permissions_step")
      |> click(Query.button("Skip"))

      # Step 3: Providers — skip
      |> assert_has(Query.css("h2", text: "Configure LLM Providers"))
      |> take_screenshot(name: "setup_wizard/skip_all_steps/03_providers_step")
      |> click(Query.button("Skip"))

      # Step 4: Models — skip
      |> assert_has(Query.css("h2", text: "Configure LLM Models"))
      |> take_screenshot(name: "setup_wizard/skip_all_steps/04_models_step")
      |> click(Query.button("Skip"))

      # Step 5: RAG — skip
      |> assert_has(Query.css("h2", text: "RAG Embedding Model"))
      |> take_screenshot(name: "setup_wizard/skip_all_steps/05_rag_step")
      |> click(Query.button("Skip for now"))

      # Step 6: Data Sources — skip
      |> assert_has(Query.css("h2", text: "Connect Your Data Sources"))
      |> take_screenshot(name: "setup_wizard/skip_all_steps/06_data_sources_step")
      |> click(Query.button("Skip for now"))

      # Should redirect to /login
      session
      |> assert_has(Query.button("Sign In"))
      |> take_screenshot(name: "setup_wizard/skip_all_steps/07_redirected_to_login")

      # Log in with the new password
      session
      |> login_user("admin@liteskill.local", @password)
      |> assert_has(Query.css("h1", text: "What can I help you with?"))
      |> take_screenshot(name: "setup_wizard/skip_all_steps/08_logged_in_home")
    end

    test "create provider and model during wizard", %{session: session} do
      create_setup_admin()

      # Set password
      session
      |> visit("/setup")
      |> fill_in(Query.css("[name='setup[password]']"), with: @password)
      |> fill_in(Query.css("[name='setup[password_confirmation]']"), with: @password)
      |> click(Query.button("Set Password & Continue"))

      # Skip permissions
      |> assert_has(Query.css("h2", text: "Default User Permissions"))
      |> click(Query.button("Skip"))

      # Providers step: click Manual Entry
      |> assert_has(Query.css("h2", text: "Configure LLM Providers"))
      |> click(Query.button("Manual Entry"))
      |> take_screenshot(name: "setup_wizard/create_provider_and_model/provider_manual_entry")

      # Fill provider form (provider_type defaults to first alphabetical option)
      |> fill_in(Query.css("[name='llm_provider[name]']"), with: "Test Provider")
      |> fill_in(Query.css("[name='llm_provider[api_key]']"), with: "sk-test-key-123")
      |> click(Query.button("Add Provider"))

      # Assert provider listed
      |> assert_has(Query.css(".text-sm.font-medium", text: "Test Provider"))
      |> take_screenshot(name: "setup_wizard/create_provider_and_model/provider_created")

      # Continue to models step
      |> click(Query.button("Continue"))
      |> assert_has(Query.css("h2", text: "Configure LLM Models"))

      # Fill model form
      |> fill_in(Query.css("[name='llm_model[name]']"), with: "Claude Test")
      |> fill_in(Query.css("[name='llm_model[model_id]']"), with: "claude-test-model")
      |> click(Query.button("Add Model"))

      # Assert model listed
      |> assert_has(Query.css(".text-sm.font-medium", text: "Claude Test"))
      |> take_screenshot(name: "setup_wizard/create_provider_and_model/model_created")

      # Continue through remaining steps
      |> click(Query.button("Continue"))
      |> assert_has(Query.css("h2", text: "RAG Embedding Model"))
      |> click(Query.button("Skip for now"))
      |> assert_has(Query.css("h2", text: "Connect Your Data Sources"))
      |> click(Query.button("Skip for now"))

      # Should redirect to /login
      session
      |> assert_has(Query.button("Sign In"))
      |> take_screenshot(name: "setup_wizard/create_provider_and_model/wizard_complete")
    end

    test "password validation shows error on mismatch", %{session: session} do
      create_setup_admin()

      session
      |> visit("/setup")
      |> assert_has(Query.css("h2", text: "Welcome to Liteskill"))
      |> fill_in(Query.css("[name='setup[password]']"), with: "SecurePass123!!")
      |> fill_in(Query.css("[name='setup[password_confirmation]']"), with: "DifferentPass456!!")
      |> click(Query.button("Set Password & Continue"))
      |> assert_has(Query.css("p.text-error", text: "Passwords do not match"))
      |> take_screenshot(name: "setup_wizard/password_validation_error/mismatch")
    end
  end
end
