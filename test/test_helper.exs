# `:live` tests make a real, paid `claude` call. Excluded by default; run them
# explicitly with `mix test --only live`.
ExUnit.start(exclude: [:live])
