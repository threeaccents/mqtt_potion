# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
use Mix.Config

config :test_client,
  mqtt_host: System.get_env("MQTT_HOST"),
  mqtt_port: String.to_integer(System.get_env("MQTT_PORT") || "8883"),
  mqtt_ca_cert_file: System.get_env("MQTT_CA_CERT_FILE"),
  mqtt_user_name: System.get_env("MQTT_USER_NAME"),
  mqtt_password: System.get_env("MQTT_PASSWORD")
