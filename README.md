# Lockring

Lockring is a mutex library for BEAM languages.

Use it when you need exclusive access to a single resource or
one of a pool of resources.

These resources can be static data or GenServers. In the latter case,
GenServer crashes are handled automatically, replacing the crashed server
and releasing its lock.

Lockring uses ETS tables and Erlang `:atomics` to coordinate locking,
providing high scalability without the bottleneck and message-passing
overhead of a GenServer-based system.

## Installation

```elixir
def deps do
  [
    {:lockring, "~> 0.1.0"}
  ]
end
```

