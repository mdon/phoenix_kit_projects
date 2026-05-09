defmodule PhoenixKitProjects.Web.ProjectFormLive do
  @moduledoc "Create or edit a project."

  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitProjects.{Activity, Errors, Paths, Projects}
  alias PhoenixKitProjects.Schemas.Project

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, params) do
    template_uuid = Map.get(params, "template")
    templates = Projects.list_templates()
    project = %Project{}

    socket
    |> assign(
      page_title: gettext("New project"),
      project: project,
      live_action: :new,
      templates: templates,
      selected_template: template_uuid
    )
    |> assign_form(Projects.change_project(project))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case Projects.get_project(id) do
      nil ->
        socket
        |> put_flash(:error, gettext("Project not found."))
        |> push_navigate(to: Paths.projects())

      project ->
        socket
        |> assign(
          page_title: gettext("Edit %{name}", name: project.name),
          project: project,
          live_action: :edit,
          templates: [],
          selected_template: nil
        )
        |> assign_form(Projects.change_project(project))
    end
  end

  defp assign_form(socket, cs), do: assign(socket, form: to_form(cs))

  @impl true
  def handle_event("validate", %{"project" => attrs} = params, socket) do
    selected_template = Map.get(params, "template_uuid", socket.assigns.selected_template)
    cs = socket.assigns.project |> Projects.change_project(attrs) |> Map.put(:action, :validate)
    {:noreply, socket |> assign(selected_template: selected_template) |> assign_form(cs)}
  end

  def handle_event("save", %{"project" => attrs} = params, socket) do
    template_uuid = Map.get(params, "template_uuid", nil) |> blank_to_nil()
    save(socket, socket.assigns.live_action, attrs, template_uuid)
  end

  defp save(socket, :new, attrs, nil) do
    case Projects.create_project(attrs) do
      {:ok, project} ->
        Activity.log("projects.project_created",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{"name" => project.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Project created."))
         |> push_navigate(to: Paths.project(project.uuid))}

      {:error, cs} ->
        {:noreply, assign_form(socket, cs)}
    end
  end

  defp save(socket, :new, attrs, template_uuid) do
    case Projects.create_project_from_template(template_uuid, attrs) do
      {:ok, project} ->
        Activity.log("projects.project_created_from_template",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{"name" => project.name, "template_uuid" => template_uuid}
        )

        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Project created from template with all tasks and dependencies.")
         )
         |> push_navigate(to: Paths.project(project.uuid))}

      {:error, :template_not_found} ->
        {:noreply, put_flash(socket, :error, Errors.message(:template_not_found))}

      # Changeset errors that originate from the cloned project itself get
      # re-assigned to the form so the user sees inline validation.
      {:error, %Ecto.Changeset{data: %Project{}} = cs} ->
        {:noreply, assign_form(socket, cs)}

      # Changesets from deeper in the transaction (assignment / dependency
      # cloning) don't map cleanly onto the project form — surface a
      # generic error message instead.
      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not copy the template. Please check the source and try again.")
         )}

      # Any other shape (e.g. `{:error, reason}` from a transaction that
      # caught an unexpected exception) — fail closed with a flash
      # instead of a pattern-match crash.
      {:error, _other} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Something went wrong while creating the project. Please try again.")
         )}
    end
  end

  defp save(socket, :edit, attrs, _template_uuid) do
    case Projects.update_project(socket.assigns.project, attrs) do
      {:ok, project} ->
        Activity.log("projects.project_updated",
          actor_uuid: Activity.actor_uuid(socket),
          resource_type: "project",
          resource_uuid: project.uuid,
          metadata: %{"name" => project.name}
        )

        {:noreply,
         socket
         |> put_flash(:info, gettext("Project updated."))
         |> push_navigate(to: Paths.project(project.uuid))}

      {:error, cs} ->
        {:noreply, assign_form(socket, cs)}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp start_mode_value(form) do
    case form[:start_mode] do
      %{value: val} when is_binary(val) and val != "" -> val
      _ -> "immediate"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col mx-auto max-w-xl px-4 py-6 gap-4">
      <div>
        <.link navigate={Paths.projects()} class="link link-hover text-sm">
          <.icon name="hero-arrow-left" class="w-4 h-4 inline" /> {gettext("Projects")}
        </.link>
        <h1 class="text-2xl font-bold mt-1">{@page_title}</h1>
      </div>

      <div class="card bg-base-100 shadow">
        <div class="card-body">
          <.form for={@form} id="project-form" phx-change="validate" phx-submit="save" phx-debounce="300" class="flex flex-col gap-3">
            <%= if @live_action == :new and @templates != [] do %>
              <.select
                name="template_uuid"
                label={gettext("From template (optional)")}
                value={@selected_template}
                options={Enum.map(@templates, &{&1.name, &1.uuid})}
                prompt={gettext("Start from scratch")}
              />
            <% end %>
            <.input field={@form[:name]} label={gettext("Name")} required />
            <.textarea field={@form[:description]} label={gettext("Description")} />
            <label class="flex items-center gap-2 cursor-pointer">
              <input
                type="hidden"
                name={@form[:counts_weekends].name}
                value="false"
              />
              <input
                type="checkbox"
                name={@form[:counts_weekends].name}
                value="true"
                checked={@form[:counts_weekends].value == true or @form[:counts_weekends].value == "true"}
                class="checkbox checkbox-sm"
              />
              <span class="text-sm">{gettext("Count weekends in schedule")}</span>
            </label>
            <.select
              field={@form[:start_mode]}
              label={gettext("Start")}
              options={[{gettext("Immediately (set up tasks first)"), "immediate"}, {gettext("Scheduled date"), "scheduled"}]}
            />
            <%= if start_mode_value(@form) == "scheduled" do %>
              <.input field={@form[:scheduled_start_date]} label={gettext("Start date")} type="date" />
            <% end %>
            <div class="flex justify-end gap-2 mt-2">
              <.link navigate={Paths.projects()} class="btn btn-ghost btn-sm">{gettext("Cancel")}</.link>
              <button type="submit" phx-disable-with={gettext("Saving…")} class="btn btn-primary btn-sm">
                <%= if @live_action == :new, do: gettext("Create"), else: gettext("Save") %>
              </button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
