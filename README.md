# MqttPotion

An Elixir wrapper around the Erlang [`emqtt`](https://github.com/emqx/emqtt) library.

Why this package?

 * supports MQTT v3.0, v3.1.1, and v5.0
 * supports clean_session/clean_start
 * simplifies usage to just defining opts and implementing a message handler

## Installation

The package can be installed by adding `mqtt_potion` to your list of dependencies in
`mix.exs`:

```elixir
def deps do
  [
    {:mqtt_potion, github: "brianmay/mqtt_potion", branch: "master"}
  ]
end
```

Sometimes you might have dependency issues because of the `emqtt` dependencies
using git links and tags (see: https://github.com/emqx/emqtt/issues/100),
so you might need to do:

```elixir
def deps do
  [
    {:mqtt_potion, github: "brianmay/mqtt_potion", branch: "master"},
    {:gun, "~> 1.3.0", override: true},
    {:cowlib, "~> 2.6.0", override: true}
  ]
end
```

**Note:** This is not available in hex, necause the emqtt package is dated.
See https://github.com/emqx/emqtt/issues/133. Packages that have git
dependancies cannot be uploaded to hex.

There are no plans to upload packages to hex unless `emqtt` starts consistently
and reliably publishing to hex.

## Usage

### Starting the client

You can use the `GenServer` or the `Supervisor` like so:

```elixir
MqttPotion.Connection.start_link(opts)
```
You probably just want to add this to your application's supervision tree.

```
    {MqttPotion, opts}
```

### Using the client

```elixir
:ok = MqttPotion.publish(name, message, topic, opts)

:ok = MqttPotion.subscribe({name, qos})

:ok = MqttPotion.unsubscribe(name, topic)
```

The async methods will log errors with Logger.error.

```
:ok = MqttPotion.publish_sync(name, message, topic, opts)

:ok = MqttPotion.subscribe_sync(name, {topic, qos})

:ok = MqttPotion.unsubscribe_sync(name, topic)
```

The sync methods will return errors as `{:error, reason :: String.t()}`.

### `opts`

```elixir
{:name, atom}
{:owner, pid}
{:handler, module}
{:host, binary}
{:hosts, [{binary, :inet.port_number()}]}
{:port, :inet.port_number()}
{:tcp_opts, [:gen_tcp.option()]}
{:ssl, boolean}
{:ssl_opts, [:ssl.ssl_option()]}
{:ws_path, binary}
{:connect_timeout, pos_integer}
{:bridge_mode, boolean}
{:client_id, iodata}
{:clean_start, boolean}
{:username, iodata}
{:password, iodata}
{:protocol_version, 3 | 4 | 5}
{:keepalive, non_neg_integer}
{:max_inflight, pos_integer}
{:retry_interval, timeout}
{:will_topic, iodata}
{:will_payload, iodata}
{:will_retain, boolean}
{:will_qos, pos_integer}
{:will_props, %{atom => term}}
{:auto_ack, boolean}
{:ack_timeout, pos_integer}
{:force_ping, boolean}
{:properties, %{atom => term}}
{:subscriptions, [{topic :: binary, qos :: non_neg_integer}]}
{:start_when, {mfa, retry_in :: non_neg_integer}}
```

**Note:**

 * The `opts` are *mostly* the same as [`:emqtt.option()`](https://github.com/emqx/emqtt/blob/783c943f7aa1295b99f4a0c20436978eb6b70053/src/emqtt.erl#L105), but they are different, so use the type defs in this library
 * `opts.ssl_opts` are erlang's [`:ssl.option()`](https://erlang.org/doc/man/ssl.html#type-tls_client_option)
 * `opts.start_when` is for controller the GenServer's `handle_continue/2` callback, so you can add an
 init condition. This is handy for example if you need to wait for the network to be ready before you try to connect to the MQTT broker. The value is a tuple `{start_when, retry_in}` where `start_when` is a `{module, function, arguments}` (MFA) tuple for a function that resolves to a `boolean` which determines when we actually finish `init`, and `retry_in` is the time to sleep (in ms) before we try again.

## Example:

See the test_client directory.
