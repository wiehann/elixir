# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec

defmodule Mix.Tasks.Cmd do
  use Mix.Task

  @shortdoc "Executes the given command"
  @recursive true

  @moduledoc """
  Executes the given command.

  For example, you can invoke an external command such as make:

      $ mix cmd make

  By passing the `--cd` flag before the command, you can also force
  the command to run in a specific directory:

      $ mix cmd --cd "third-party" make

  This task is also useful in umbrella applications to execute a command
  on each child app:

      $ mix cmd pwd

  You can limit which apps the cmd runs in by using `mix do` with the `--app`
  option:

      $ mix do --app app1 --app app2 cmd pwd

  The tasks aborts whenever a command exits with a non-zero status.

  This task is automatically re-enabled, so it can be called multiple times
  with different arguments.

  ## Command line options

    * `--cd` *(since v1.10.4)* - the directory to run the command in

  ## Orphan operating system processes

  Beware that the Erlang VM does not terminate child processes
  when it shuts down. Therefore, if you use `mix cmd` to start
  long running processes and then shut down the VM, it is likely
  that those child processes won't be terminated with the VM.

  A solution is to make sure the child processes listen to the
  standard input and terminate when standard input is closed.
  We discuss this topic at length in the "Orphan operating system processes"
  of the `Port` module documentation.
  """

  @switches [
    app: :keep,
    cd: :string
  ]

  @impl true
  def run(args) do
    {opts, args} = OptionParser.parse_head!(args, strict: @switches)

    if args == [] do
      Mix.raise("Expected at least one argument in mix cmd")
    end

    apps =
      opts
      |> Keyword.get_values(:app)
      |> Enum.map(&String.to_atom/1)

    if apps != [] do
      IO.warn("the --app in mix cmd is deprecated. Use mix do --app instead.")
    end

    if apps == [] or Mix.Project.config()[:app] in apps do
      cmd_opts = Keyword.take(opts, [:cd])

      case Mix.shell().cmd({hd(args), tl(args)}, cmd_opts) do
        0 -> :ok
        status -> exit(status)
      end
    end

    Mix.Task.reenable("cmd")
  end
end
