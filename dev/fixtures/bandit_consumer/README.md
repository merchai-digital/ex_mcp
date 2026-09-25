This small project proves that a Bandit host can select and run ExMCP without
PlugCowboy or the Cowboy/Cowlib/Ranch family. It has its own dependency graph;
the root ExMCP test graph deliberately includes test-only Bypass and Cowboy.

From this directory, run `mix deps.get`, `mix test`, and `mix hex.audit` with
separate `MIX_BUILD_PATH` and `MIX_DEPS_PATH` from the ExMCP checkout.
