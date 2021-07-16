defmodule TestClient.MQTTHandler do
  @behaviour ExMQTT.Handler

  @impl ExMQTT.Handler
  def handle_connect() do
    IO.puts("got connect")
    :ok
  end

  @impl ExMQTT.Handler
  def handle_disconnect(_reason, _properties) do
    IO.puts("got disconnect")
    :ok
  end

  @impl ExMQTT.Handler
  def handle_message(topic, message) do
    IO.puts("Got message #{inspect(topic)}")
    IO.inspect(message)
    :ok
  end

  @impl ExMQTT.Handler
  def handle_puback(_ack) do
    :ok
  end
end
