defmodule PhoenixKitProjects.Web.TaskFilesTest do
  @moduledoc """
  A task holds its own files and images (the boss's list, item 7; chain
  V27): stored in a folder per task inside the project's, recorded as the
  task's, listed on the edit popup's More tab, an image pasted into the
  description stored the same way and placed by its address — never as a
  `data:` URL.
  """

  use PhoenixKitProjects.LiveCase, async: false

  alias PhoenixKit.Modules.Storage.Folder
  alias PhoenixKitProjects.{Attachments, Projects}
  alias PhoenixKitProjects.Test.Repo

  # A 1×1 PNG.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
       )

  setup %{conn: conn} do
    me = embed_user_uuid!()
    project = fixture_project(%{"start_mode" => "immediate"})

    {:ok, %{assignment: a}} =
      Projects.create_task_with_assignment(
        project.uuid,
        %{"title" => "Measure the window", "ad_hoc" => true},
        %{}
      )

    {:ok, conn: put_test_scope(conn, fake_scope(user_uuid: me)), me: me, project: project, a: a}
  end

  defp tmp(bytes) do
    path = Path.join(System.tmp_dir!(), "pkp-test-#{System.unique_integer([:positive])}")
    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "a stored file is the task's, in the task's folder, and removed again", ctx do
    path = tmp("plan v1 #{System.unique_integer()}")

    assert {:ok, file} =
             Attachments.store_task_file(
               ctx.a,
               path,
               [filename: "plan.txt", content_type: "text/plain", size_bytes: 10],
               ctx.me
             )

    assert [%{file: %{uuid: uuid}, inline: false}] = Attachments.list_task_files(ctx.a.uuid)
    assert uuid == file.uuid

    folder = Repo.get(Folder, Repo.get(PhoenixKit.Modules.Storage.File, file.uuid).folder_uuid)
    assert folder.name == Attachments.task_folder_name(ctx.a.uuid)

    assert :ok = Attachments.remove_task_file(ctx.a, file.uuid, ctx.me)
    assert Attachments.list_task_files(ctx.a.uuid) == []
    assert {:error, :not_found} = Attachments.remove_task_file(ctx.a, file.uuid, ctx.me)
  end

  test "the edit popup lists the task's files on More, and a pasted image is stored", ctx do
    path = tmp("notes #{System.unique_integer()}")

    {:ok, _} =
      Attachments.store_task_file(
        ctx.a,
        path,
        [filename: "notes.txt", content_type: "text/plain", size_bytes: 5],
        ctx.me
      )

    {:ok, view, html} =
      live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.a.uuid}/edit")

    assert has_element?(view, "#assignment-pane-more #assignment-files", "notes.txt")
    refute has_element?(view, "#assignment-pane-task #assignment-files")

    [id] =
      Regex.run(~r/data-description-editor="(assignment-description--[^"]+)"/, html,
        capture: :all_but_first
      )

    send(
      view.pid,
      {:leaf_paste_image,
       %{
         editor_id: id,
         data_url: "data:image/png;base64," <> Base.encode64(@png),
         name: "shot.png",
         mime: "image/png"
       }}
    )

    render(view)
    assert [%{inline: true}] = Attachments.list_task_files(ctx.a.uuid, inline: true)
  end

  test "a pasted file that is not an image is refused", ctx do
    {:ok, view, html} =
      live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.a.uuid}/edit")

    [id] =
      Regex.run(~r/data-description-editor="(assignment-description--[^"]+)"/, html,
        capture: :all_but_first
      )

    send(
      view.pid,
      {:leaf_paste_image,
       %{
         editor_id: id,
         data_url: "data:text/html;base64," <> Base.encode64("<script></script>"),
         name: "x.html",
         mime: "text/html"
       }}
    )

    assert render(view) =~ "Upload failed"
    assert Attachments.list_task_files(ctx.a.uuid) == []
  end

  # LiveViewTest's upload client needs a PubSub on the test endpoint, which
  # this suite's has not: the input and its drop zone are checked here, the
  # storing path through `store_task_file/4` and the paste above.
  test "the More tab has the upload button and drop zone; the first tab does not", ctx do
    {:ok, view, _} =
      live(ctx.conn, "/en/admin/projects/#{ctx.project.uuid}/assignments/#{ctx.a.uuid}/edit")

    assert has_element?(view, "#assignment-pane-more #assignment-files[phx-drop-target]")
    assert has_element?(view, "#assignment-files input[type=file][name=task_files]")
    assert has_element?(view, "#assignment-description-image")
  end
end
