defmodule PhoenixKitProjects.Web.TemplateFormLiveTest do
  @moduledoc """
  Smoke tests for `TemplateFormLive`. The original sweep shipped this
  LV with 0% coverage. Pins mount + validate + save flows for both
  `:new` and `:edit` actions, plus the not-found redirect. Activity
  log entries on save are pinned via `assert_activity_logged/2`.
  """

  use PhoenixKitProjects.LiveCase, async: false

  setup %{conn: conn} do
    scope = fake_scope()
    conn = put_test_scope(conn, scope)
    {:ok, conn: conn, actor_uuid: scope.user.uuid}
  end

  describe "new template" do
    test "mounts and renders the form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/templates/new")
      assert html =~ "template-form"
      assert html =~ "New template"
    end

    test "submit button has phx-disable-with", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/en/admin/projects/templates/new")
      assert html =~ ~r/phx-disable-with=/
    end

    test "validate event with empty name shows inline error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/templates/new")

      html =
        view
        |> form("#template-form", project: %{name: "", description: "x"})
        |> render_change()

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
    end

    test "save creates a template and logs the activity", %{conn: conn, actor_uuid: actor_uuid} do
      {:ok, view, _html} = live(conn, "/en/admin/projects/templates/new")

      title = "Tpl-#{System.unique_integer([:positive])}"

      {:error, {:live_redirect, %{to: redirect_to}}} =
        view
        |> form("#template-form", project: %{name: title, description: "d"})
        |> render_submit()

      assert redirect_to =~ "/templates/"

      assert_activity_logged("projects.template_created",
        actor_uuid: actor_uuid,
        metadata_has: %{"name" => title}
      )
    end
  end

  describe "edit template" do
    test "renders existing values", %{conn: conn} do
      template =
        fixture_template(%{"name" => "Existing-#{System.unique_integer([:positive])}"})

      {:ok, _view, html} = live(conn, "/en/admin/projects/templates/#{template.uuid}/edit")
      assert html =~ template.name
    end

    test "save updates and logs activity", %{conn: conn, actor_uuid: actor_uuid} do
      template = fixture_template()

      {:ok, view, _html} = live(conn, "/en/admin/projects/templates/#{template.uuid}/edit")

      new_name = "Renamed-#{System.unique_integer([:positive])}"

      {:error, {:live_redirect, _}} =
        view
        |> form("#template-form", project: %{name: new_name, description: "d2"})
        |> render_submit()

      assert_activity_logged("projects.template_updated",
        actor_uuid: actor_uuid,
        resource_uuid: template.uuid,
        metadata_has: %{"name" => new_name}
      )
    end

    test "missing template id flashes + redirects to templates index", %{conn: conn} do
      bogus = Ecto.UUID.generate()

      {:error, {:live_redirect, %{to: redirect_to, flash: flash}}} =
        live(conn, "/en/admin/projects/templates/#{bogus}/edit")

      assert redirect_to =~ "/templates"
      assert flash["error"] =~ "Template not found"
    end
  end
end
