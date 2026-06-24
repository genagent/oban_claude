# .iex.exs -- convenience for exploring oban_claude in `iex -S mix`.
alias ClaudeWrapper.{Result, Error}

# Quick live run (real, paid ~2c). Returns {oban_verdict, %Result{} | %Error{}}.
oc = fn prompt -> ObanClaude.run(%{"prompt" => prompt, "model" => "haiku"}) end

IO.puts(:stderr, "oban_claude: `oc.(\"reply with hi\")` for a quick live run, or ObanClaude.run/2 directly")
