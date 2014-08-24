defmodule Kernel.ParallelCompiler do
  @moduledoc """
  A module responsible for compiling files in parallel.
  """

  @doc """
  Compiles the given files.

  Those files are compiled in parallel and can automatically
  detect dependencies between them. Once a dependency is found,
  the current file stops being compiled until the dependency is
  resolved.

  If there is an error during compilation or if `warnings_as_errors`
  is set to `true` and there is a warning, this function will fail
  with an exception.

  This function accepts the following options:

    * `:each_file` - for each file compiled, invokes the callback passing the
      file

    * `:each_module` - for each module compiled, invokes the callback passing
      the file, module and the module bytecode

    * `:dest` - the destination directory for the beam files. When using `files/2`,
      this information is only used to properly annotate the beam files before
      they are loaded into memory. If you want a file to actually be writen to
      `dest`, use `files_to_path/3` instead.

  Returns the modules generated by each compiled file.
  """
  def files(files, options \\ [])

  def files(files, options) when is_list(options) do
    spawn_compilers(files, nil, options)
  end

  @doc """
  Compiles the given files to the given path.
  Read `files/2` for more information.
  """
  def files_to_path(files, path, options \\ [])

  def files_to_path(files, path, options) when is_binary(path) and is_list(options) do
    spawn_compilers(files, path, options)
  end

  defp spawn_compilers(files, path, options) do
    true = Code.ensure_loaded?(Kernel.ErrorHandler)
    compiler_pid = self()
    :elixir_code_server.cast({:reset_warnings, compiler_pid})
    schedulers = max(:erlang.system_info(:schedulers_online), 2)

    result = spawn_compilers(files, files, path, options, [], [], schedulers, [])

    # In case --warning-as-errors is enabled and there was a warning,
    # compilation status will be set to error and we fail with CompileError
    case :elixir_code_server.call({:compilation_status, compiler_pid}) do
      :ok    -> result
      :error -> exit({:shutdown, 1})
    end
  end

  # We already have 4 currently running, don't spawn new ones
  defp spawn_compilers(entries, original, output, options, waiting, queued, schedulers, result) when
      length(queued) - length(waiting) >= schedulers do
    wait_for_messages(entries, original, output, options, waiting, queued, schedulers, result)
  end

  # Release waiting processes
  defp spawn_compilers([h|t], original, output, options, waiting, queued, schedulers, result) when is_pid(h) do
    {_kind, ^h, ref, _module} = List.keyfind(waiting, h, 1)
    send h, {ref, :ready}
    waiting = List.keydelete(waiting, h, 1)
    spawn_compilers(t, original, output, options, waiting, queued, schedulers, result)
  end

  # Spawn a compiler for each file in the list until we reach the limit
  defp spawn_compilers([h|t], original, output, options, waiting, queued, schedulers, result) do
    parent = self()

    {pid, ref} =
      :erlang.spawn_monitor fn ->
        # Notify Code.ensure_compiled/2 that we should
        # attempt to compile the module by doing a dispatch.
        :erlang.put(:elixir_ensure_compiled, true)

        # Set the elixir_compiler_pid used by our custom Kernel.ErrorHandler.
        :erlang.put(:elixir_compiler_pid, parent)
        :erlang.process_flag(:error_handler, Kernel.ErrorHandler)

        exit(try do
          _ = if output do
            :elixir_compiler.file_to_path(h, output)
          else
            :elixir_compiler.file(h, Keyword.get(options, :dest))
          end
          {:compiled, h}
        catch
          kind, reason ->
            {:failure, kind, reason, System.stacktrace}
        end)
      end

    spawn_compilers(t, original, output, options, waiting,
                    [{pid, ref, h}|queued], schedulers, result)
  end

  # No more files, nothing waiting, queue is empty, we are done
  defp spawn_compilers([], _original, _output, _options, [], [], _schedulers, result) do
    for {:module, mod} <- result, do: mod
  end

  # Queued x, waiting for x: POSSIBLE ERROR! Release processes so we get the failures
  defp spawn_compilers([], original, output, options, waiting, queued, schedulers, result) when length(waiting) == length(queued) do
    Enum.each queued, fn {child, _, _} ->
      {_kind, ^child, ref, _module} = List.keyfind(waiting, child, 1)
      send child, {ref, :release}
    end
    wait_for_messages([], original, output, options, waiting, queued, schedulers, result)
  end

  # No more files, but queue and waiting are not full or do not match
  defp spawn_compilers([], original, output, options, waiting, queued, schedulers, result) do
    wait_for_messages([], original, output, options, waiting, queued, schedulers, result)
  end

  # Wait for messages from child processes
  defp wait_for_messages(entries, original, output, options, waiting, queued, schedulers, result) do
    receive do
      {:struct_available, module} ->
        available = for {:struct, pid, _, waiting_module} <- waiting,
                        module == waiting_module,
                        not pid in entries,
                        do: pid

        spawn_compilers(available ++ entries, original, output, options,
                        waiting, queued, schedulers, [{:struct, module}|result])

      {:module_available, child, ref, file, module, binary} ->
        if callback = Keyword.get(options, :each_module) do
          callback.(file, module, binary)
        end

        # Release the module loader which is waiting for an ack
        send child, {ref, :ack}

        available = for {_kind, pid, _, waiting_module} <- waiting,
                        module == waiting_module,
                        not pid in entries,
                        do: pid

        spawn_compilers(available ++ entries, original, output, options,
                        waiting, queued, schedulers, [{:module, module}|result])

      {:waiting, kind, child, ref, on} ->
        defined = fn {k, m} -> on == m and k in [kind, :module] end

        # Oops, we already got it, do not put it on waiting.
        if :lists.any(defined, result) do
          send child, {ref, :ready}
        else
          waiting = [{kind, child, ref, on}|waiting]
        end

        spawn_compilers(entries, original, output, options, waiting, queued, schedulers, result)

      {:DOWN, _down_ref, :process, down_pid, {:compiled, file}} ->
        if callback = Keyword.get(options, :each_file) do
          callback.(file)
        end

        # Sometimes we may have spurious entries in the waiting
        # list because someone invoked try/rescue UndefinedFunctionError
        new_entries = List.delete(entries, down_pid)
        new_queued  = List.keydelete(queued, down_pid, 0)
        new_waiting = List.keydelete(waiting, down_pid, 1)
        spawn_compilers(new_entries, original, output, options, new_waiting, new_queued, schedulers, result)

      {:DOWN, down_ref, :process, _down_pid, reason} ->
        handle_failure(down_ref, reason, entries, waiting, queued)
        wait_for_messages(entries, original, output, options, waiting, queued, schedulers, result)
    end
  end

  defp handle_failure(ref, reason, entries, waiting, queued) do
    if file = find_failure(ref, queued) do
      print_failure(file, reason)
      if all_missing?(entries, waiting, queued) do
        collect_failures(queued, length(queued) - 1)
      end
      exit({:shutdown, 1})
    end
  end

  defp find_failure(ref, queued) do
    case List.keyfind(queued, ref, 1) do
      {_child, ^ref, file} -> file
      _ -> nil
    end
  end

  defp print_failure(_file, {:compiled, _}) do
    :ok
  end

  defp print_failure(file, {:failure, kind, reason, stacktrace}) do
    IO.puts "\n== Compilation error on file #{Path.relative_to_cwd(file)} =="
    IO.puts Exception.format(kind, reason, prune_stacktrace(stacktrace))
  end

  defp print_failure(file, reason) do
    IO.puts "\n== Compilation error on file #{Path.relative_to_cwd(file)} =="
    IO.puts Exception.format(:exit, reason, [])
  end

  @elixir_internals [:elixir_compiler, :elixir_module, :elixir_translator, :elixir_expand]

  defp prune_stacktrace([{mod, _, _, _}|t]) when mod in @elixir_internals do
    prune_stacktrace(t)
  end

  defp prune_stacktrace([h|t]) do
    [h|prune_stacktrace(t)]
  end

  defp prune_stacktrace([]) do
    []
  end

  defp all_missing?(entries, waiting, queued) do
    entries == [] and waiting != [] and
      length(waiting) == length(queued)
  end

  defp collect_failures(_queued, 0), do: :ok

  defp collect_failures(queued, remaining) do
    receive do
      {:DOWN, down_ref, :process, _down_pid, reason} ->
        if file = find_failure(down_ref, queued) do
          print_failure(file, reason)
          collect_failures(queued, remaining - 1)
        else
          collect_failures(queued, remaining)
        end
    after
      # Give up if no failure appears in 5 seconds
      5000 -> :ok
    end
  end
end
