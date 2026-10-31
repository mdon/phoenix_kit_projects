defmodule PhoenixKitProjects.InlineImages do
  @moduledoc """
  Images placed in a task's description, kept in the text by the FILE they
  show — `![alt](pkfile:<file uuid>)` — never by an address.

  An address is the wrong thing to keep: a file in a private library is
  served only with a time-window token (core's storage rules), so an
  address written into the text stops working, and a permanent one would
  show the picture to anyone holding the text. The reference is resolved
  when the text is drawn, for the person reading it (`resolve/3`, through
  `Storage.authorized_url/4`): an image they may not see is left out, and
  an image whose file is gone too.

  The editor shows pictures by address, so the text it is given has the
  references resolved (`resolve/3` with `keep_missing: true`, so a picture
  it cannot show is still kept), and what it writes back is turned into
  references again before it is stored (`to_refs/1`, in the assignment's
  changeset): an app file address in an image (`/…/file/<uuid>/original/…`)
  becomes that file's reference.

  The reference names the file, not the task, so a description copied to a
  task's next occurrence (`Repeats`) shows the same pictures: the file rows
  stay with the occurrence they were added to.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File
  alias PhoenixKit.Users.Auth.Scope

  @uuid "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"

  # `![alt](target "title")` — the target with or without `<…>`.
  @image ~r/!\[([^\]\n]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"\n]*")?\s*\)/
  @ref ~r/^pkfile:(#{@uuid})$/
  # An address the app signed for a file's original (`URLSigner.signed_url/3`),
  # always a path on this site.
  @app_url ~r{^/(?:[^\s)]*/)?file/(#{@uuid})/original/}

  @doc "The reference an image of `file_uuid` is kept by."
  @spec ref(binary()) :: String.t()
  def ref(file_uuid) when is_binary(file_uuid), do: "pkfile:" <> String.downcase(file_uuid)

  @doc "Whether `text` holds an image reference (cheap: no regex)."
  @spec refs?(term()) :: boolean()
  def refs?(text) when is_binary(text), do: String.contains?(text, "pkfile:")
  def refs?(_), do: false

  @doc """
  `text` with every image shown by an app file address kept by its file's
  reference instead. Any other image, and anything that is not text, is
  left as it is.
  """
  @spec to_refs(term()) :: term()
  def to_refs(text) when is_binary(text) do
    if String.contains?(text, "/file/") do
      Regex.replace(@image, text, fn whole, alt, target ->
        case Regex.run(@app_url, target, capture: :all_but_first) do
          [uuid] -> "![#{alt}](#{ref(uuid)})"
          _ -> whole
        end
      end)
    else
      text
    end
  end

  def to_refs(text), do: text

  @doc """
  `text` with each image reference turned into an address `scope` may open
  (`Storage.authorized_url/4`; a private library's is a time-window one).
  An image the viewer may not see, or whose file is gone, is left out —
  or, with `keep_missing: true` (the editor), kept as its reference.
  """
  @spec resolve(term(), term(), keyword()) :: term()
  def resolve(text, scope, opts \\ [])

  def resolve(text, scope, opts) when is_binary(text) do
    if refs?(text) do
      urls = urls(uuids(text), scope)
      keep? = Keyword.get(opts, :keep_missing, false)

      Regex.replace(@image, text, fn whole, alt, target ->
        resolve_image(whole, alt, target, urls, keep?)
      end)
    else
      text
    end
  end

  def resolve(text, _scope, _opts), do: text

  defp resolve_image(whole, alt, target, urls, keep?) do
    case Regex.run(@ref, target, capture: :all_but_first) do
      [uuid] -> resolved(whole, alt, Map.get(urls, String.downcase(uuid)), keep?)
      # not a reference: left as written
      _ -> whole
    end
  end

  defp resolved(_whole, alt, url, _keep?) when is_binary(url), do: "![#{alt}](#{url})"
  # a reference this viewer cannot open: kept for the editor, else left out
  defp resolved(whole, _alt, _url, true), do: whole
  defp resolved(_whole, _alt, _url, _keep?), do: ""

  @doc """
  `text` without the images of `file_uuid` — by reference or by app
  address — for a file taken off the task.
  """
  @spec strip(term(), binary()) :: term()
  def strip(text, file_uuid) when is_binary(text) and is_binary(file_uuid) do
    uuid = String.downcase(file_uuid)

    Regex.replace(@image, text, fn whole, _alt, target ->
      named =
        case Regex.run(@ref, target, capture: :all_but_first) ||
               Regex.run(@app_url, target, capture: :all_but_first) do
          [found] -> String.downcase(found)
          _ -> nil
        end

      if named == uuid, do: "", else: whole
    end)
  end

  def strip(text, _file_uuid), do: text

  @doc """
  The address `scope` may open `file` at — what the editor is handed for a
  picture just stored — or nil.
  """
  @spec url(File.t(), term()) :: String.t() | nil
  def url(%File{} = file, scope), do: authorized(scope_or_nil(scope), file)

  defp uuids(text) do
    Regex.scan(~r/pkfile:(#{@uuid})/, text, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  # One read for every file the text names, then each one's address.
  defp urls([], _scope), do: %{}

  defp urls(uuids, scope) do
    scope = scope_or_nil(scope)

    from(f in File,
      where: f.uuid in ^uuids,
      where: f.status != "trashed" and not coalesce(f.system_managed, false)
    )
    |> PhoenixKit.RepoHelper.repo().all()
    |> Map.new(&{String.downcase(to_string(&1.uuid)), authorized(scope, &1)})
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp authorized(scope, file) do
    Storage.authorized_url(scope, file, "original", locale: :none)
  rescue
    _ -> nil
  end

  defp scope_or_nil(%Scope{} = scope), do: scope
  defp scope_or_nil(_), do: nil
end
