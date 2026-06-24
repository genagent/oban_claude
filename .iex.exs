# .iex.exs -- convenience for exploring oban_claude in `iex -S mix`.
alias ClaudeWrapper.{Result, Error}

# One-shot live run (real, paid ~2c): returns {verdict, %Result{} | %Error{}}.
oc = fn prompt -> ObanClaude.run(%{"prompt" => prompt, "model" => "haiku"}) end

# A local SQLite-backed queue you can drive interactively (a "Claude console").
Code.require_file("examples/console.exs", __DIR__)

IO.puts(:stderr, """
oban_claude:
  oc.("reply with hi")            one-shot live run (no queue)
  ObanClaude.Console.start()      boot a local SQLite-backed queue
  ObanClaude.Console.run("...")   enqueue a prompt (prints the result when it finishes)
  ObanClaude.Console.jobs()       list recent jobs
""")
