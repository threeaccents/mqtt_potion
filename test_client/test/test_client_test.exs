defmodule TestClientTest do
  use ExUnit.Case
  doctest TestClient

  test "greets the world" do
    assert TestClient.hello() == :world
  end
end
