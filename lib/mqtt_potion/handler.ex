defmodule MqttPotion.Handler do
  @moduledoc """
  Handler behaviour for the MQTT client.
  """

  @callback handle_connect() :: :ok
  @callback handle_disconnect(reason_code :: 0..0xFF, properties :: term) :: :ok
  @callback handle_message(topic :: list(String.t()), message :: MqttPotion.Message.t()) :: :ok
  @callback handle_puback(ack :: term) :: :ok
end
