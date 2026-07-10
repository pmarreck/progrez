# Mistakes

- 2026-07-10: Two duplicate `./test` processes were started while diagnosing a
  long-running CLI suite because an asynchronous terminal session identifier
  was not retained. Both were allowed to finish safely; future long commands
  retain and poll the session identifier instead of restarting the command.
