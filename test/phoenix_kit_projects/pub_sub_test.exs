defmodule PhoenixKitProjects.PubSubTest do
  use ExUnit.Case, async: true

  alias PhoenixKitProjects.PubSub, as: P

  describe "topics" do
    test "topic_all/0 is stable" do
      assert P.topic_all() == "projects:all"
    end

    test "topic_project/1 embeds the uuid" do
      assert P.topic_project("abc") == "projects:project:abc"
    end

    test "topic_tasks/0 and topic_templates/0" do
      assert P.topic_tasks() == "projects:tasks"
      assert P.topic_templates() == "projects:templates"
    end
  end
end
