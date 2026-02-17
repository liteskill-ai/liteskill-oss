defmodule LiteskillWeb.AuthLive do
  use LiteskillWeb, :live_view

  alias Liteskill.Accounts
  alias Liteskill.Settings

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       form: to_form(%{}, as: :user),
       error: nil,
       invitation: nil,
       registration_open: Settings.registration_open?()
     )}
  end

  @impl true
  def handle_params(%{"token" => token}, _uri, %{assigns: %{live_action: :invite}} = socket) do
    case Accounts.get_invitation_by_token(token) do
      nil ->
        {:noreply, assign(socket, error: "This invitation link is invalid.", invitation: nil)}

      invitation ->
        cond do
          Accounts.Invitation.used?(invitation) ->
            {:noreply,
             assign(socket,
               error: "This invitation has already been used.",
               invitation: nil
             )}

          Accounts.Invitation.expired?(invitation) ->
            {:noreply,
             assign(socket,
               error: "This invitation has expired. Please request a new one.",
               invitation: nil
             )}

          true ->
            {:noreply,
             assign(socket,
               invitation: invitation,
               error: nil,
               form: to_form(%{"email" => invitation.email}, as: :user)
             )}
        end
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, error: nil, form: to_form(%{}, as: :user), invitation: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-base-200 px-4">
      <div class="card w-full max-w-sm bg-base-100 shadow-xl">
        <div class="card-body">
          <h2 class="card-title text-2xl font-bold justify-center mb-2">
            {page_title(@live_action, @invitation)}
          </h2>

          {render_form(assigns)}
        </div>
      </div>
    </div>
    """
  end

  defp render_form(%{live_action: :register} = assigns) do
    ~H"""
    <div :if={!@registration_open} class="text-center space-y-4">
      <p class="text-base-content/70">
        Registration is currently closed. Contact an administrator for an invitation.
      </p>
      <.link navigate={~p"/login"} class="link link-primary">
        Back to Sign In
      </.link>
    </div>

    <div :if={@registration_open}>
      <.form for={@form} phx-submit="submit" class="space-y-4">
        <div class="form-control">
          <label class="label" for="user_name">
            <span class="label-text">Name</span>
          </label>
          <input
            type="text"
            name="user[name]"
            id="user_name"
            value={@form[:name].value}
            class="input input-bordered w-full"
            required
          />
        </div>

        <div class="form-control">
          <label class="label" for="user_email">
            <span class="label-text">Email</span>
          </label>
          <input
            type="email"
            name="user[email]"
            id="user_email"
            value={@form[:email].value}
            placeholder="Email"
            class="input input-bordered w-full"
            required
          />
        </div>

        <div class="form-control">
          <label class="label" for="user_password">
            <span class="label-text">Password</span>
          </label>
          <input
            type="password"
            name="user[password]"
            id="user_password"
            class="input input-bordered w-full"
            required
          />
        </div>

        <p :if={@error} class="text-error text-sm">{@error}</p>

        <div class="form-control mt-6">
          <button type="submit" class="btn btn-primary w-full">Register</button>
        </div>
      </.form>

      <div class="divider">or</div>

      <div class="text-center text-sm">
        <.link navigate={~p"/login"} class="link link-primary">
          Already have an account? Sign in
        </.link>
      </div>
    </div>
    """
  end

  defp render_form(%{live_action: :login} = assigns) do
    ~H"""
    <.form for={@form} phx-submit="submit" class="space-y-4">
      <div class="form-control">
        <label class="label" for="user_email">
          <span class="label-text">Email</span>
        </label>
        <input
          type="text"
          name="user[email]"
          id="user_email"
          value={@form[:email].value}
          placeholder="Email"
          class="input input-bordered w-full"
          required
        />
      </div>

      <div class="form-control">
        <label class="label" for="user_password">
          <span class="label-text">Password</span>
        </label>
        <input
          type="password"
          name="user[password]"
          id="user_password"
          class="input input-bordered w-full"
          required
        />
      </div>

      <p :if={@error} class="text-error text-sm">{@error}</p>

      <div class="form-control mt-6">
        <button type="submit" class="btn btn-primary w-full">Sign In</button>
      </div>
    </.form>

    <div class="divider">or</div>

    <div class="text-center text-sm">
      <.link :if={@registration_open} navigate={~p"/register"} class="link link-primary">
        Create an account
      </.link>
      <span :if={!@registration_open} class="text-base-content/50">
        Registration is closed. Contact an administrator for an invitation.
      </span>
    </div>
    """
  end

  defp render_form(%{live_action: :invite, invitation: nil} = assigns) do
    ~H"""
    <div class="text-center space-y-4">
      <p :if={@error} class="text-error">{@error}</p>
      <.link navigate={~p"/login"} class="link link-primary">
        Go to Sign In
      </.link>
    </div>
    """
  end

  defp render_form(%{live_action: :invite, invitation: invitation} = assigns)
       when not is_nil(invitation) do
    ~H"""
    <.form for={@form} phx-submit="submit" class="space-y-4">
      <div class="form-control">
        <label class="label" for="user_email">
          <span class="label-text">Email</span>
        </label>
        <input
          type="email"
          name="user[email]"
          id="user_email"
          value={@invitation.email}
          class="input input-bordered w-full bg-base-200"
          readonly
        />
      </div>

      <div class="form-control">
        <label class="label" for="user_name">
          <span class="label-text">Name</span>
        </label>
        <input
          type="text"
          name="user[name]"
          id="user_name"
          value={@form[:name].value}
          class="input input-bordered w-full"
          required
        />
      </div>

      <div class="form-control">
        <label class="label" for="user_password">
          <span class="label-text">Password</span>
        </label>
        <input
          type="password"
          name="user[password]"
          id="user_password"
          class="input input-bordered w-full"
          required
          minlength="12"
        />
      </div>

      <p :if={@error} class="text-error text-sm">{@error}</p>

      <div class="form-control mt-6">
        <button type="submit" class="btn btn-primary w-full">Create Account</button>
      </div>
    </.form>
    """
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    case socket.assigns.live_action do
      :register -> handle_register(params, socket)
      :login -> handle_login(params, socket)
      :invite -> handle_invite(params, socket)
    end
  end

  defp handle_register(params, socket) do
    attrs = %{
      email: params["email"],
      name: params["name"],
      password: params["password"]
    }

    case Accounts.register_user(attrs) do
      {:ok, user} ->
        token = Phoenix.Token.sign(LiteskillWeb.Endpoint, "user_session", user.id)
        {:noreply, redirect(socket, to: "/auth/session?token=#{token}")}

      {:error, changeset} ->
        {:noreply, assign(socket, error: format_changeset(changeset))}
    end
  end

  defp handle_login(params, socket) do
    email = expand_admin_shorthand(params["email"])

    case Accounts.authenticate_by_email_password(email, params["password"]) do
      {:ok, user} ->
        token = Phoenix.Token.sign(LiteskillWeb.Endpoint, "user_session", user.id)
        {:noreply, redirect(socket, to: "/auth/session?token=#{token}")}

      {:error, :invalid_credentials} ->
        {:noreply, assign(socket, error: "Invalid email or password")}
    end
  end

  defp handle_invite(params, socket) do
    invitation = socket.assigns.invitation

    case Accounts.accept_invitation(invitation.token, %{
           name: params["name"],
           password: params["password"]
         }) do
      {:ok, user} ->
        token = Phoenix.Token.sign(LiteskillWeb.Endpoint, "user_session", user.id)
        {:noreply, redirect(socket, to: "/auth/session?token=#{token}")}

      {:error, :already_used} ->
        {:noreply, assign(socket, error: "This invitation has already been used.")}

      {:error, :expired} ->
        {:noreply, assign(socket, error: "This invitation has expired.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, error: format_changeset(changeset))}

      {:error, reason} ->
        {:noreply, assign(socket, error: action_error("create account", reason))}
    end
  end

  defp expand_admin_shorthand("admin"), do: Liteskill.Accounts.User.admin_email()
  defp expand_admin_shorthand(email), do: email

  defp page_title(:register, _), do: "Create Account"
  defp page_title(:login, _), do: "Welcome Back"
  defp page_title(:invite, nil), do: "Invitation"
  defp page_title(:invite, _), do: "Accept Invitation"
end
