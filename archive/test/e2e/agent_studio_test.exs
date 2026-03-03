defmodule LiteskillWeb.E2E.AgentStudioTest do
  use LiteskillWeb.FeatureCase, async: false

  alias Liteskill.Runs
  alias Liteskill.Usage

  # --- Landing Page ---

  test "agent studio landing page shows all sections", %{session: session} do
    register_and_wait(session)

    session
    |> visit("/agents")
    |> assert_has(Query.css("h1", text: "Agent Studio"))
    |> assert_has(Query.css(".card-title", text: "Agents"))
    |> assert_has(Query.css(".card-title", text: "Teams"))
    |> assert_has(Query.css(".card-title", text: "Runs"))
    |> assert_has(Query.css(".card-title", text: "Schedules"))
    |> take_screenshot(name: "agent_studio/landing/all_sections")
  end

  test "landing page cards navigate to list pages", %{session: session} do
    register_and_wait(session)

    session
    |> visit("/agents")
    |> assert_has(Query.css(".card-title", text: "Agents"))

    session
    |> find(Query.css(".card-title", text: "Agents"))
    |> Element.click()

    assert_has(session, Query.css("h1", text: "Agents"))
    take_screenshot(session, name: "agent_studio/landing/navigated_to_agents")
  end

  # --- Agent CRUD ---

  test "create a new agent", %{session: session} do
    register_and_wait(session)

    # Navigate to agents list
    session
    |> visit("/agents/list")
    |> assert_has(Query.css("h1", text: "Agents"))
    |> assert_has(Query.css("p", text: "No agents yet"))
    |> take_screenshot(name: "agent_studio/agents/empty_list")

    # Click New Agent
    session
    |> click(Query.link("New Agent"))
    |> assert_has(Query.css("h1", text: "New Agent"))
    |> take_screenshot(name: "agent_studio/agents/new_form_empty")

    # Fill the form
    session
    |> fill_in(Query.css("input[name='agent[name]']"), with: "Research Assistant")
    |> fill_in(Query.css("textarea[name='agent[description]']"),
      with: "An assistant that helps with research tasks"
    )
    |> fill_in(Query.css("textarea[name='agent[backstory]']"),
      with: "You are a thorough researcher who always cites sources."
    )
    |> fill_in(Query.css("textarea[name='agent[system_prompt]']"),
      with: "Always provide detailed, well-sourced answers."
    )
    |> take_screenshot(name: "agent_studio/agents/new_form_filled")

    # Add an opinion
    session
    |> click(Query.button("Add opinion"))
    |> fill_in(Query.css("input[name='agent[opinions][0][key]']"), with: "tone")
    |> fill_in(Query.css("input[name='agent[opinions][0][value]']"), with: "concise and direct")
    |> take_screenshot(name: "agent_studio/agents/new_form_with_opinion")

    # Submit
    click(session, Query.button("Create Agent"))

    # Verify we're on the show page
    session
    |> assert_has(Query.css("h1", text: "Research Assistant"))
    |> assert_has(Query.css(".badge", text: "active"))
    |> take_screenshot(name: "agent_studio/agents/show_after_create")
  end

  test "view agent details", %{session: session} do
    register_and_wait(session)
    seed_agent(session)

    session
    |> visit("/agents/list")
    |> assert_has(Query.css("h1", text: "Agents"))

    # Click on the agent card link
    session
    |> find(Query.link("E2E Test Agent"))
    |> Element.click()

    session
    |> assert_has(Query.css("h1", text: "E2E Test Agent"))
    |> assert_has(Query.css("p", text: "react", count: :any))
    |> take_screenshot(name: "agent_studio/agents/show_details")
  end

  test "edit an existing agent", %{session: session} do
    register_and_wait(session)
    seed_agent(session)

    session
    |> visit("/agents/list")
    |> assert_has(Query.link("E2E Test Agent"))

    # Click the Edit link on the card
    session
    |> click(Query.link("Edit"))
    |> assert_has(Query.css("h1", text: "Edit Agent"))
    |> take_screenshot(name: "agent_studio/agents/edit_form_loaded")

    # Update the name
    session
    |> fill_in(Query.css("input[name='agent[name]']"), with: "Updated Agent Name")
    |> take_screenshot(name: "agent_studio/agents/edit_form_modified")

    # Submit
    click(session, Query.button("Update Agent"))

    # Verify we're on the show page with updated name
    session
    |> assert_has(Query.css("h1", text: "Updated Agent Name"))
    |> take_screenshot(name: "agent_studio/agents/show_after_edit")
  end

  test "delete an agent", %{session: session} do
    register_and_wait(session)
    seed_agent(session)

    session
    |> visit("/agents/list")
    |> assert_has(Query.link("E2E Test Agent"))

    # Click the trash button
    click(session, Query.css("[phx-click='confirm_delete_agent']"))

    # Confirm modal appears
    session
    |> assert_has(Query.css("h3", text: "Delete Agent"))
    |> take_screenshot(name: "agent_studio/agents/delete_confirm_modal")

    # Click Delete in the modal
    click(session, Query.button("Delete"))

    # After deletion, navigate to the agents list to verify it's empty
    session
    |> visit("/agents/list")
    |> assert_has(Query.css("h1", text: "Agents"))
    |> assert_has(Query.css("p", text: "No agents yet"))
    |> take_screenshot(name: "agent_studio/agents/deleted")
  end

  # --- Team CRUD ---

  test "create a new team", %{session: session} do
    register_and_wait(session)

    session
    |> visit("/teams")
    |> assert_has(Query.css("h1", text: "Teams"))
    |> assert_has(Query.css("p", text: "No teams yet"))
    |> take_screenshot(name: "agent_studio/teams/empty_list")

    # Click New Team
    session
    |> click(Query.link("New Team"))
    |> assert_has(Query.css("h1", text: "New Team"))
    |> take_screenshot(name: "agent_studio/teams/new_form_empty")

    # Fill the form
    session
    |> fill_in(Query.css("input[name='team[name]']"), with: "Content Team")
    |> fill_in(Query.css("textarea[name='team[description]']"),
      with: "A team for content creation tasks"
    )
    |> fill_in(Query.css("textarea[name='team[shared_context]']"),
      with: "We focus on high-quality, well-researched content."
    )
    |> take_screenshot(name: "agent_studio/teams/new_form_filled")

    # Submit
    click(session, Query.button("Create Team"))

    # Verify we're on the show page
    session
    |> assert_has(Query.css("h1", text: "Content Team"))
    |> assert_has(Query.css("p", text: "pipeline", count: :any))
    |> take_screenshot(name: "agent_studio/teams/show_after_create")
  end

  test "view team details", %{session: session} do
    register_and_wait(session)
    seed_agent(session)
    seed_team(session)

    session
    |> visit("/teams")
    |> assert_has(Query.link("E2E Test Team"))

    session
    |> find(Query.link("E2E Test Team"))
    |> Element.click()

    session
    |> assert_has(Query.css("h1", text: "E2E Test Team"))
    |> assert_has(Query.css("p", text: "pipeline", count: :any))
    |> take_screenshot(name: "agent_studio/teams/show_details")
  end

  test "edit team and manage members", %{session: session} do
    register_and_wait(session)
    seed_agent(session)
    seed_team(session)

    session
    |> visit("/teams")
    |> assert_has(Query.link("E2E Test Team"))

    # Click Edit link on the card
    session
    |> click(Query.link("Edit"))
    |> assert_has(Query.css("h1", text: "Edit Team"))
    |> take_screenshot(name: "agent_studio/teams/edit_form_loaded")

    # Update the name
    session
    |> fill_in(Query.css("input[name='team[name]']"), with: "Updated Team")
    |> take_screenshot(name: "agent_studio/teams/edit_form_modified")

    # Submit
    click(session, Query.button("Update Team"))

    session
    |> assert_has(Query.css("h1", text: "Updated Team"))
    |> take_screenshot(name: "agent_studio/teams/show_after_edit")
  end

  test "delete a team", %{session: session} do
    register_and_wait(session)
    seed_team(session)

    session
    |> visit("/teams")
    |> assert_has(Query.link("E2E Test Team"))

    # Click the trash button
    click(session, Query.css("[phx-click='confirm_delete_team']"))

    # Confirm modal
    session
    |> assert_has(Query.css("h3", text: "Delete Team"))
    |> take_screenshot(name: "agent_studio/teams/delete_confirm_modal")

    # Click Delete
    click(session, Query.button("Delete"))

    session
    |> assert_has(Query.css("h1", text: "Teams"))
    |> assert_has(Query.css("p", text: "No teams yet"))
    |> take_screenshot(name: "agent_studio/teams/deleted")
  end

  # --- Run CRUD ---

  test "create a new run", %{session: session} do
    register_and_wait(session)
    seed_team(session)

    session
    |> visit("/runs")
    |> assert_has(Query.css("h1", text: "Runs"))
    |> assert_has(Query.css("p", text: "No runs yet"))
    |> take_screenshot(name: "agent_studio/runs/empty_list")

    # Click New Run
    session
    |> click(Query.link("New Run"))
    |> assert_has(Query.css("h1", text: "New Run"))
    |> take_screenshot(name: "agent_studio/runs/new_form_empty")

    # Fill the form
    session
    |> fill_in(Query.css("input[name='run[name]']"), with: "Blog Post Generation")
    |> fill_in(Query.css("textarea[name='run[description]']"),
      with: "Generate a blog post about AI agents"
    )
    |> fill_in(Query.css("textarea[name='run[prompt]']"),
      with: "Write a comprehensive blog post about multi-agent AI systems."
    )
    |> fill_in(Query.css("input[name='run[cost_limit]']"), with: "2.50")
    |> take_screenshot(name: "agent_studio/runs/new_form_filled")

    # Submit
    click(session, Query.button("Create Run"))

    # Verify we're on the show page
    session
    |> assert_has(Query.css("h1", text: "Blog Post Generation"))
    |> assert_has(Query.css(".badge", text: "pending"))
    |> take_screenshot(name: "agent_studio/runs/show_after_create")
  end

  test "view run details", %{session: session} do
    register_and_wait(session)
    seed_run(session)

    session
    |> visit("/runs")
    |> assert_has(Query.link("E2E Test Run"))

    session
    |> find(Query.link("E2E Test Run"))
    |> Element.click()

    session
    |> assert_has(Query.css("h1", text: "E2E Test Run"))
    |> assert_has(Query.css(".badge", text: "pending"))
    |> assert_has(Query.css("p", text: "pipeline", count: :any))
    |> take_screenshot(name: "agent_studio/runs/show_details")
  end

  test "delete a run", %{session: session} do
    register_and_wait(session)
    seed_run(session)

    session
    |> visit("/runs")
    |> assert_has(Query.link("E2E Test Run"))

    # Click the trash button
    click(session, Query.css("[phx-click='confirm_delete_run']"))

    # Confirm modal
    session
    |> assert_has(Query.css("h3", text: "Delete Run"))
    |> take_screenshot(name: "agent_studio/runs/delete_confirm_modal")

    # Click Delete
    click(session, Query.button("Delete"))

    session
    |> assert_has(Query.css("h1", text: "Runs"))
    |> assert_has(Query.css("p", text: "No runs yet"))
    |> take_screenshot(name: "agent_studio/runs/deleted")
  end

  # --- Schedule CRUD ---

  test "create a new schedule", %{session: session} do
    register_and_wait(session)
    seed_team(session)

    session
    |> visit("/schedules")
    |> assert_has(Query.css("h1", text: "Schedules"))
    |> assert_has(Query.css("p", text: "No schedules yet"))
    |> take_screenshot(name: "agent_studio/schedules/empty_list")

    # Click New Schedule
    session
    |> click(Query.link("New Schedule"))
    |> assert_has(Query.css("h1", text: "New Schedule"))
    |> take_screenshot(name: "agent_studio/schedules/new_form_empty")

    # Fill the form
    session
    |> fill_in(Query.css("input[name='schedule[name]']"), with: "Daily Report")
    |> fill_in(Query.css("textarea[name='schedule[description]']"),
      with: "Generate a daily summary report"
    )
    |> fill_in(Query.css("input[name='schedule[cron_expression]']"), with: "0 9 * * *")
    |> fill_in(Query.css("textarea[name='schedule[prompt]']"),
      with: "Summarize yesterday's key events and metrics."
    )
    |> take_screenshot(name: "agent_studio/schedules/new_form_filled")

    # Submit
    click(session, Query.button("Create Schedule"))

    # Verify we're on the show page
    session
    |> assert_has(Query.css("h1", text: "Daily Report"))
    |> take_screenshot(name: "agent_studio/schedules/show_after_create")
  end

  test "view schedule details", %{session: session} do
    register_and_wait(session)
    seed_schedule(session)

    session
    |> visit("/schedules")
    |> assert_has(Query.link("E2E Test Schedule"))

    session
    |> find(Query.link("E2E Test Schedule"))
    |> Element.click()

    session
    |> assert_has(Query.css("h1", text: "E2E Test Schedule"))
    |> take_screenshot(name: "agent_studio/schedules/show_details")
  end

  test "toggle schedule enabled/disabled", %{session: session} do
    register_and_wait(session)
    seed_schedule(session)

    session
    |> visit("/schedules")
    |> assert_has(Query.link("E2E Test Schedule"))
    |> take_screenshot(name: "agent_studio/schedules/list_with_schedule")

    # Toggle the schedule off
    click(session, Query.css("[phx-click='toggle_schedule']"))

    # Small wait for LV update
    Process.sleep(200)
    take_screenshot(session, name: "agent_studio/schedules/toggled")
  end

  test "delete a schedule", %{session: session} do
    register_and_wait(session)
    seed_schedule(session)

    session
    |> visit("/schedules")
    |> assert_has(Query.link("E2E Test Schedule"))

    # Click the trash button
    click(session, Query.css("[phx-click='confirm_delete_schedule']"))

    # Confirm modal
    session
    |> assert_has(Query.css("h3", text: "Delete Schedule"))
    |> take_screenshot(name: "agent_studio/schedules/delete_confirm_modal")

    # Click Delete
    click(session, Query.button("Delete"))

    session
    |> assert_has(Query.css("h1", text: "Schedules"))
    |> assert_has(Query.css("p", text: "No schedules yet"))
    |> take_screenshot(name: "agent_studio/schedules/deleted")
  end

  # --- Cross-feature: full workflow ---

  test "full workflow: create agent, create team, create run", %{session: session} do
    register_and_wait(session)

    # 1. Create an agent
    session
    |> visit("/agents/new")
    |> assert_has(Query.css("h1", text: "New Agent"))
    |> fill_in(Query.css("input[name='agent[name]']"), with: "Writer Agent")
    |> fill_in(Query.css("textarea[name='agent[description]']"),
      with: "Writes high-quality content"
    )
    |> fill_in(Query.css("textarea[name='agent[backstory]']"),
      with: "You are an expert technical writer."
    )
    |> click(Query.button("Create Agent"))

    session
    |> assert_has(Query.css("h1", text: "Writer Agent"))
    |> take_screenshot(name: "agent_studio/workflow/agent_created")

    # 2. Create a team
    session
    |> visit("/teams/new")
    |> assert_has(Query.css("h1", text: "New Team"))
    |> fill_in(Query.css("input[name='team[name]']"), with: "Writing Team")
    |> fill_in(Query.css("textarea[name='team[description]']"),
      with: "Team that produces written content"
    )
    |> click(Query.button("Create Team"))

    session
    |> assert_has(Query.css("h1", text: "Writing Team"))
    |> take_screenshot(name: "agent_studio/workflow/team_created")

    # 3. Create a run
    session
    |> visit("/runs/new")
    |> assert_has(Query.css("h1", text: "New Run"))
    |> fill_in(Query.css("input[name='run[name]']"), with: "Article Draft")
    |> fill_in(Query.css("textarea[name='run[prompt]']"),
      with: "Write a draft article about the future of AI."
    )
    |> take_screenshot(name: "agent_studio/workflow/run_form_filled")
    |> click(Query.button("Create Run"))

    session
    |> assert_has(Query.css("h1", text: "Article Draft"))
    |> assert_has(Query.css(".badge", text: "pending"))
    |> take_screenshot(name: "agent_studio/workflow/run_created_pending")
  end

  # --- Mocked Run States ---

  test "completed pipeline run shows tasks, logs, and usage", %{session: session} do
    {session, user_id} = login_with_known_user(session)
    run = stage_completed_pipeline_run(user_id)

    session
    |> visit("/runs/#{run.id}")
    |> assert_has(Query.css("h1", text: "Completed Pipeline Run"))
    |> assert_has(Query.css(".badge.badge-sm", text: "completed"))
    |> take_screenshot(name: "agent_studio/runs/completed_run_header")

    # Verify tasks section shows all 3 pipeline stages
    session
    |> assert_has(Query.css("span", text: "Research Agent", count: :any))
    |> assert_has(Query.css("span", text: "Writer Agent", count: :any))
    |> assert_has(Query.css("span", text: "Editor Agent", count: :any))
    |> take_screenshot(name: "agent_studio/runs/completed_run_tasks")

    # Verify usage & cost section
    session
    |> assert_has(Query.css("h3", text: "Usage & Cost", count: :any))
    |> take_screenshot(name: "agent_studio/runs/completed_run_usage")

    # Verify execution log section
    session
    |> assert_has(Query.css("h3", text: "Execution Log", count: :any))
    |> take_screenshot(name: "agent_studio/runs/completed_run_logs")

    # Verify Rerun button visible for completed runs
    session
    |> assert_has(Query.css("button[phx-click='rerun']"))
    |> take_screenshot(name: "agent_studio/runs/completed_run_full_page")
  end

  test "failed run shows error section and retry buttons", %{session: session} do
    {session, user_id} = login_with_known_user(session)
    run = stage_failed_run(user_id)

    session
    |> visit("/runs/#{run.id}")
    |> assert_has(Query.css("h1", text: "Failed Analysis Run"))
    |> assert_has(Query.css(".badge.badge-sm", text: "failed"))
    |> take_screenshot(name: "agent_studio/runs/failed_run_header")

    # Verify error section with error message
    session
    |> assert_has(Query.css("h3", text: "Error"))
    |> assert_has(Query.css("p", text: "Rate limit exceeded", count: :any))
    |> take_screenshot(name: "agent_studio/runs/failed_run_error_section")

    # Verify task states (one completed, one failed)
    session
    |> assert_has(Query.css("span", text: "Data Collector", count: :any))
    |> assert_has(Query.css("span", text: "Analyst Agent", count: :any))
    |> take_screenshot(name: "agent_studio/runs/failed_run_tasks")

    # Verify error-level entries in execution log
    session
    |> assert_has(Query.css("h3", text: "Execution Log", count: :any))
    |> take_screenshot(name: "agent_studio/runs/failed_run_logs")

    # Verify Retry and New Run buttons
    session
    |> assert_has(Query.css("button[phx-click='retry_run']"))
    |> assert_has(Query.css("button[phx-click='rerun']"))
    |> take_screenshot(name: "agent_studio/runs/failed_run_action_buttons")
  end

  test "cancelled run shows retry and new run buttons", %{session: session} do
    {session, user_id} = login_with_known_user(session)
    run = stage_cancelled_run(user_id)

    session
    |> visit("/runs/#{run.id}")
    |> assert_has(Query.css("h1", text: "Cancelled Report Run"))
    |> assert_has(Query.css(".badge.badge-sm", text: "cancelled"))
    |> take_screenshot(name: "agent_studio/runs/cancelled_run_header")

    # Verify task states (one completed, one skipped)
    session
    |> assert_has(Query.css("span", text: "Researcher", count: :any))
    |> assert_has(Query.css("span", text: "Report Writer", count: :any))
    |> take_screenshot(name: "agent_studio/runs/cancelled_run_tasks")

    # Verify Retry and New Run buttons
    session
    |> assert_has(Query.css("button[phx-click='retry_run']"))
    |> assert_has(Query.css("button[phx-click='rerun']"))
    |> take_screenshot(name: "agent_studio/runs/cancelled_run_action_buttons")
  end

  test "running run shows cancel button and active tasks", %{session: session} do
    {session, user_id} = login_with_known_user(session)
    run = stage_running_run(user_id)

    session
    |> visit("/runs/#{run.id}")
    |> assert_has(Query.css("h1", text: "Active Generation Run"))
    |> assert_has(Query.css(".badge.badge-sm", text: "running"))
    |> take_screenshot(name: "agent_studio/runs/running_run_header")

    # Verify mixed task states (completed, running, pending)
    session
    |> assert_has(Query.css("span", text: "Planner Agent", count: :any))
    |> assert_has(Query.css("span", text: "Writer Agent", count: :any))
    |> assert_has(Query.css("span", text: "Reviewer Agent", count: :any))
    |> take_screenshot(name: "agent_studio/runs/running_run_tasks")

    # Verify Cancel button visible
    session
    |> assert_has(Query.css("button[phx-click='cancel_run']"))
    |> take_screenshot(name: "agent_studio/runs/running_run_cancel_button")
  end

  test "pending run shows start button", %{session: session} do
    {session, user_id} = login_with_known_user(session)

    {:ok, run} =
      Runs.create_run(%{
        user_id: user_id,
        name: "Queued Pipeline Run",
        prompt: "Generate a weekly summary report",
        description: "Waiting to be started"
      })

    session
    |> visit("/runs/#{run.id}")
    |> assert_has(Query.css("h1", text: "Queued Pipeline Run"))
    |> assert_has(Query.css(".badge.badge-sm", text: "pending"))
    |> assert_has(Query.css("button[phx-click='start_run']"))
    |> take_screenshot(name: "agent_studio/runs/pending_run_start_button")
  end

  test "execution log entry detail page", %{session: session} do
    {session, user_id} = login_with_known_user(session)
    run = stage_completed_pipeline_run(user_id)

    # Load run with preloaded logs to get a log entry ID
    {:ok, run_with_logs} = Runs.get_run(run.id, user_id)
    first_log = List.first(run_with_logs.run_logs)

    session
    |> visit("/runs/#{run.id}/logs/#{first_log.id}")
    |> assert_has(Query.css("*", text: first_log.message, count: :any))
    |> take_screenshot(name: "agent_studio/runs/log_detail_page")
  end

  test "run with multi-model usage shows by-model table", %{session: session} do
    {session, user_id} = login_with_known_user(session)
    run = stage_multi_model_run(user_id)

    session
    |> visit("/runs/#{run.id}")
    |> assert_has(Query.css("h1", text: "Multi-Model Run"))
    |> assert_has(Query.css(".badge.badge-sm", text: "completed"))
    |> take_screenshot(name: "agent_studio/runs/multi_model_run_header")

    # Verify usage section with by-model table
    session
    |> assert_has(Query.css("h3", text: "Usage & Cost", count: :any))
    |> assert_has(Query.css("td", text: "claude-3-5-sonnet", count: :any))
    |> assert_has(Query.css("td", text: "gpt-4o", count: :any))
    |> take_screenshot(name: "agent_studio/runs/multi_model_usage_table")
  end

  # --- Helpers ---

  # Register a user and wait for the post-registration redirect to complete.
  # This ensures the session is authenticated and on the chat page before
  # navigating to Agent Studio pages.
  defp register_and_wait(session) do
    register_user(session)
    assert_has(session, Query.css("#message-input"))
    session
  end

  # Seeds an agent for the currently logged-in user via the browser.
  defp seed_agent(session) do
    session
    |> visit("/agents/new")
    |> assert_has(Query.css("h1", text: "New Agent"))
    |> fill_in(Query.css("input[name='agent[name]']"), with: "E2E Test Agent")
    |> fill_in(Query.css("textarea[name='agent[description]']"),
      with: "Agent created for E2E testing"
    )
    |> click(Query.button("Create Agent"))

    assert_has(session, Query.css("h1", text: "E2E Test Agent"))
    session
  end

  # Seeds a team for the currently logged-in user via the browser.
  defp seed_team(session) do
    session
    |> visit("/teams/new")
    |> assert_has(Query.css("h1", text: "New Team"))
    |> fill_in(Query.css("input[name='team[name]']"), with: "E2E Test Team")
    |> fill_in(Query.css("textarea[name='team[description]']"),
      with: "Team created for E2E testing"
    )
    |> click(Query.button("Create Team"))

    assert_has(session, Query.css("h1", text: "E2E Test Team"))
    session
  end

  # Seeds a run for the currently logged-in user via the browser.
  defp seed_run(session) do
    session
    |> visit("/runs/new")
    |> assert_has(Query.css("h1", text: "New Run"))
    |> fill_in(Query.css("input[name='run[name]']"), with: "E2E Test Run")
    |> fill_in(Query.css("textarea[name='run[prompt]']"),
      with: "Test prompt for E2E run"
    )
    |> click(Query.button("Create Run"))

    assert_has(session, Query.css("h1", text: "E2E Test Run"))
    session
  end

  # Seeds a schedule for the currently logged-in user via the browser.
  defp seed_schedule(session) do
    session
    |> visit("/schedules/new")
    |> assert_has(Query.css("h1", text: "New Schedule"))
    |> fill_in(Query.css("input[name='schedule[name]']"), with: "E2E Test Schedule")
    |> fill_in(Query.css("input[name='schedule[cron_expression]']"), with: "0 8 * * *")
    |> fill_in(Query.css("textarea[name='schedule[prompt]']"),
      with: "Test prompt for E2E schedule"
    )
    |> click(Query.button("Create Schedule"))

    assert_has(session, Query.css("h1", text: "E2E Test Schedule"))
    session
  end

  # Login with a user whose ID we know (for direct DB operations).
  defp login_with_known_user(session) do
    %{user: user, email: email, password: password} = create_user()
    login_user(session, email, password)
    assert_has(session, Query.css("#message-input"))
    {session, user.id}
  end

  defp stage_completed_pipeline_run(user_id) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    started_at = DateTime.add(now, -120, :second)

    {:ok, run} =
      Runs.create_run(%{
        user_id: user_id,
        name: "Completed Pipeline Run",
        prompt: "Write a comprehensive blog post about AI agents",
        description: "A multi-step pipeline that researches, writes, and edits content",
        topology: "pipeline",
        status: "completed",
        started_at: started_at,
        completed_at: now
      })

    {:ok, _} =
      Runs.add_task(run.id, %{
        name: "Research Agent",
        status: "completed",
        position: 0,
        duration_ms: 45_000,
        started_at: started_at,
        completed_at: DateTime.add(started_at, 45, :second),
        output_summary: "Found 15 relevant sources on AI agents"
      })

    {:ok, _} =
      Runs.add_task(run.id, %{
        name: "Writer Agent",
        status: "completed",
        position: 1,
        duration_ms: 60_000,
        started_at: DateTime.add(started_at, 45, :second),
        completed_at: DateTime.add(started_at, 105, :second),
        output_summary: "Generated 2500-word blog post draft"
      })

    {:ok, _} =
      Runs.add_task(run.id, %{
        name: "Editor Agent",
        status: "completed",
        position: 2,
        duration_ms: 15_000,
        started_at: DateTime.add(started_at, 105, :second),
        completed_at: now,
        output_summary: "Refined and polished final article"
      })

    Runs.add_log(run.id, "info", "init", "Pipeline starting with 3 agents")
    Runs.add_log(run.id, "info", "agent_start", "Research Agent started")
    Runs.add_log(run.id, "debug", "llm_round", "Calling claude-3-5-sonnet (round 1)")
    Runs.add_log(run.id, "debug", "llm_round", "Calling claude-3-5-sonnet (round 2)")
    Runs.add_log(run.id, "info", "agent_complete", "Research Agent completed in 45s")
    Runs.add_log(run.id, "info", "agent_start", "Writer Agent started")
    Runs.add_log(run.id, "debug", "llm_round", "Calling claude-3-5-sonnet (round 1)")
    Runs.add_log(run.id, "debug", "llm_round", "Calling claude-3-5-sonnet (round 2)")
    Runs.add_log(run.id, "debug", "llm_round", "Calling claude-3-5-sonnet (round 3)")
    Runs.add_log(run.id, "info", "agent_complete", "Writer Agent completed in 60s")
    Runs.add_log(run.id, "info", "agent_start", "Editor Agent started")
    Runs.add_log(run.id, "debug", "llm_round", "Calling claude-3-5-sonnet (round 1)")
    Runs.add_log(run.id, "info", "agent_complete", "Editor Agent completed in 15s")
    Runs.add_log(run.id, "info", "complete", "Pipeline completed successfully")

    {:ok, _} =
      Usage.record_usage(%{
        user_id: user_id,
        run_id: run.id,
        model_id: "claude-3-5-sonnet",
        call_type: "complete",
        input_tokens: 15_000,
        output_tokens: 3_500,
        total_tokens: 18_500,
        input_cost: Decimal.new("0.045"),
        output_cost: Decimal.new("0.053"),
        total_cost: Decimal.new("0.098")
      })

    {:ok, _} =
      Usage.record_usage(%{
        user_id: user_id,
        run_id: run.id,
        model_id: "claude-3-5-sonnet",
        call_type: "complete",
        input_tokens: 20_000,
        output_tokens: 5_000,
        total_tokens: 25_000,
        input_cost: Decimal.new("0.060"),
        output_cost: Decimal.new("0.075"),
        total_cost: Decimal.new("0.135")
      })

    run
  end

  defp stage_failed_run(user_id) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    started_at = DateTime.add(now, -90, :second)

    {:ok, run} =
      Runs.create_run(%{
        user_id: user_id,
        name: "Failed Analysis Run",
        prompt: "Analyze quarterly sales data and produce insights",
        description: "Two-stage analysis pipeline",
        topology: "pipeline",
        status: "failed",
        error: "Rate limit exceeded after 3 retries on claude-3-5-sonnet. Last error: 429 Too Many Requests",
        started_at: started_at,
        completed_at: now
      })

    {:ok, _} =
      Runs.add_task(run.id, %{
        name: "Data Collector",
        status: "completed",
        position: 0,
        duration_ms: 30_000,
        started_at: started_at,
        completed_at: DateTime.add(started_at, 30, :second)
      })

    {:ok, _} =
      Runs.add_task(run.id, %{
        name: "Analyst Agent",
        status: "failed",
        position: 1,
        duration_ms: 60_000,
        error: "LLM request failed: 429 Too Many Requests",
        started_at: DateTime.add(started_at, 30, :second),
        completed_at: now
      })

    Runs.add_log(run.id, "info", "init", "Pipeline starting with 2 agents")
    Runs.add_log(run.id, "info", "agent_start", "Data Collector started")
    Runs.add_log(run.id, "info", "agent_complete", "Data Collector completed in 30s")
    Runs.add_log(run.id, "info", "agent_start", "Analyst Agent started")
    Runs.add_log(run.id, "debug", "llm_round", "Calling claude-3-5-sonnet (round 1)")
    Runs.add_log(run.id, "warn", "retry", "Rate limited (429), retrying in 2s...")
    Runs.add_log(run.id, "warn", "retry", "Rate limited (429), retrying in 4s...")
    Runs.add_log(run.id, "warn", "retry", "Rate limited (429), retrying in 8s...")
    Runs.add_log(run.id, "error", "agent_crash", "Analyst Agent failed: Rate limit exceeded")
    Runs.add_log(run.id, "error", "failed", "Pipeline failed at stage 2")

    run
  end

  defp stage_cancelled_run(user_id) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    started_at = DateTime.add(now, -60, :second)

    {:ok, run} =
      Runs.create_run(%{
        user_id: user_id,
        name: "Cancelled Report Run",
        prompt: "Generate monthly financial report",
        description: "Two-stage report pipeline",
        topology: "pipeline",
        status: "cancelled",
        started_at: started_at,
        completed_at: now
      })

    {:ok, _} =
      Runs.add_task(run.id, %{
        name: "Researcher",
        status: "completed",
        position: 0,
        duration_ms: 40_000,
        started_at: started_at,
        completed_at: DateTime.add(started_at, 40, :second)
      })

    {:ok, _} =
      Runs.add_task(run.id, %{
        name: "Report Writer",
        status: "skipped",
        position: 1
      })

    Runs.add_log(run.id, "info", "init", "Pipeline starting with 2 agents")
    Runs.add_log(run.id, "info", "agent_start", "Researcher started")
    Runs.add_log(run.id, "info", "agent_complete", "Researcher completed in 40s")
    Runs.add_log(run.id, "warn", "cancelled", "Run cancelled by user")

    run
  end

  defp stage_running_run(user_id) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    started_at = DateTime.add(now, -45, :second)

    {:ok, run} =
      Runs.create_run(%{
        user_id: user_id,
        name: "Active Generation Run",
        prompt: "Create a marketing campaign for product launch",
        description: "Three-stage generation pipeline",
        topology: "pipeline",
        status: "running",
        started_at: started_at
      })

    {:ok, _} =
      Runs.add_task(run.id, %{
        name: "Planner Agent",
        status: "completed",
        position: 0,
        duration_ms: 25_000,
        started_at: started_at,
        completed_at: DateTime.add(started_at, 25, :second)
      })

    {:ok, _} =
      Runs.add_task(run.id, %{
        name: "Writer Agent",
        status: "running",
        position: 1,
        started_at: DateTime.add(started_at, 25, :second)
      })

    {:ok, _} =
      Runs.add_task(run.id, %{
        name: "Reviewer Agent",
        status: "pending",
        position: 2
      })

    Runs.add_log(run.id, "info", "init", "Pipeline starting with 3 agents")
    Runs.add_log(run.id, "info", "agent_start", "Planner Agent started")
    Runs.add_log(run.id, "info", "agent_complete", "Planner Agent completed in 25s")
    Runs.add_log(run.id, "info", "agent_start", "Writer Agent started")
    Runs.add_log(run.id, "debug", "llm_round", "Calling claude-3-5-sonnet (round 1)")
    Runs.add_log(run.id, "debug", "llm_round", "Calling claude-3-5-sonnet (round 2)")

    run
  end

  defp stage_multi_model_run(user_id) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    started_at = DateTime.add(now, -180, :second)

    {:ok, run} =
      Runs.create_run(%{
        user_id: user_id,
        name: "Multi-Model Run",
        prompt: "Generate and review a technical document",
        description: "Uses different models for different tasks",
        topology: "pipeline",
        status: "completed",
        started_at: started_at,
        completed_at: now
      })

    {:ok, _} =
      Runs.add_task(run.id, %{
        name: "Draft Generator",
        status: "completed",
        position: 0,
        duration_ms: 90_000
      })

    {:ok, _} =
      Runs.add_task(run.id, %{
        name: "Technical Reviewer",
        status: "completed",
        position: 1,
        duration_ms: 60_000
      })

    Runs.add_log(run.id, "info", "init", "Pipeline starting with 2 agents (multi-model)")
    Runs.add_log(run.id, "info", "agent_start", "Draft Generator started (claude-3-5-sonnet)")
    Runs.add_log(run.id, "info", "agent_complete", "Draft Generator completed")
    Runs.add_log(run.id, "info", "agent_start", "Technical Reviewer started (gpt-4o)")
    Runs.add_log(run.id, "info", "agent_complete", "Technical Reviewer completed")
    Runs.add_log(run.id, "info", "complete", "Pipeline completed successfully")

    {:ok, _} =
      Usage.record_usage(%{
        user_id: user_id,
        run_id: run.id,
        model_id: "claude-3-5-sonnet",
        call_type: "complete",
        input_tokens: 25_000,
        output_tokens: 8_000,
        total_tokens: 33_000,
        input_cost: Decimal.new("0.075"),
        output_cost: Decimal.new("0.120"),
        total_cost: Decimal.new("0.195")
      })

    {:ok, _} =
      Usage.record_usage(%{
        user_id: user_id,
        run_id: run.id,
        model_id: "gpt-4o",
        call_type: "complete",
        input_tokens: 30_000,
        output_tokens: 5_000,
        total_tokens: 35_000,
        input_cost: Decimal.new("0.150"),
        output_cost: Decimal.new("0.100"),
        total_cost: Decimal.new("0.250")
      })

    run
  end
end
