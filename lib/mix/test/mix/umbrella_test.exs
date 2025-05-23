# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec

Code.require_file("../test_helper.exs", __DIR__)

defmodule Mix.UmbrellaTest do
  use MixTest.Case

  test "apps_paths and parent_umbrella_project_file" do
    in_fixture("umbrella_dep/deps/umbrella", fn ->
      assert Mix.Project.apps_paths() == nil
      assert Mix.Project.parent_umbrella_project_file() == nil

      Mix.Project.in_project(:umbrella, ".", fn _ ->
        assert Mix.Project.apps_paths() == %{bar: "apps/bar", foo: "apps/foo"}
        assert Mix.Project.parent_umbrella_project_file() == nil

        assert_received {:mix_shell, :error,
                         ["warning: path \"apps/dont_error_on_missing_mixfile\"" <> _]}

        refute_received {:mix_shell, :error, ["warning: path \"apps/dont_error_on_files\"" <> _]}
      end)
    end)
  end

  test "apps_paths with selection" do
    in_fixture("umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project(:umbrella, ".", [apps: [:foo, :bar]], fn _ ->
        File.mkdir_p!("apps/errors")
        File.write!("apps/errors/mix.exs", "raise :oops")
        assert Mix.Project.apps_paths() == %{bar: "apps/bar", foo: "apps/foo"}
      end)
    end)
  end

  test "umbrella app dir and the app name defined in mix.exs should be equal" do
    in_fixture("umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project(:umbrella, ".", fn _ ->
        File.write!("apps/bar/mix.exs", """
        defmodule Bar.MixProject do
          use Mix.Project

          def project do
            [app: :baz,
             version: "0.1.0",
             deps: []]
          end
        end
        """)

        assert_raise Mix.Error, ~r/^Umbrella app :baz is located at directory bar/, fn ->
          Mix.Task.run("deps")
        end
      end)
    end)
  end

  test "compiles umbrella" do
    in_fixture("umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project(:umbrella, ".", fn _ ->
        Mix.Task.run("deps")
        assert_received {:mix_shell, :info, ["* bar (apps/bar) (mix)"]}
        assert_received {:mix_shell, :info, ["* foo (apps/foo) (mix)"]}

        # Ensure we can compile and run checks
        Mix.Task.run("deps.compile")
        Mix.Task.run("deps.loadpaths")
        Mix.Task.run("compile", ["--verbose"])

        # Extra applications are picked even for umbrellas
        assert :code.where_is_file(~c"runtime_tools.app") != :non_existing
        assert :code.where_is_file(~c"observer.app") == :non_existing

        assert_received {:mix_shell, :info, ["==> bar"]}
        assert_received {:mix_shell, :info, ["Generated bar app"]}
        assert File.regular?("_build/dev/lib/bar/ebin/Elixir.Bar.beam")
        assert_received {:mix_shell, :info, ["==> foo"]}
        assert_received {:mix_shell, :info, ["Generated foo app"]}
        assert File.regular?("_build/dev/lib/foo/ebin/Elixir.Foo.beam")

        # Ensure foo was loaded and in the same env as Mix.env
        assert_received {:mix_shell, :info, [":foo env is dev"]}
        assert_received {:mix_shell, :info, [":bar env is dev"]}

        Mix.Task.clear()
        Mix.Task.run("app.start", ["--no-compile"])
      end)
    end)
  end

  test "compiles umbrella with protocol consolidation" do
    in_fixture("umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project(:umbrella, ".", fn _ ->
        Mix.Task.run("compile", ["--verbose"])
        assert_received {:mix_shell, :info, ["Generated bar app"]}
        assert_received {:mix_shell, :info, ["Generated foo app"]}
        assert File.regular?("_build/dev/consolidated/Elixir.Enumerable.beam")
        purge([Enumerable])

        assert Mix.Tasks.App.Start.run([])
        assert Protocol.consolidated?(Enumerable)
      end)
    end)
  end

  test "recursively compiles umbrella with protocol consolidation" do
    in_fixture("umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project(:umbrella, ".", fn _ ->
        defmodule Elixir.Mix.Tasks.Umbrella.Recur do
          use Mix.Task
          @recursive true

          def run(_) do
            assert Mix.Task.recursing?()
            Mix.Task.run("compile", ["--verbose"])
          end
        end

        Mix.Task.run("umbrella.recur")
        assert_received {:mix_shell, :info, ["Generated bar app"]}
        assert_received {:mix_shell, :info, ["Generated foo app"]}
        assert File.regular?("_build/dev/consolidated/Elixir.Enumerable.beam")
        purge([Enumerable])

        assert Mix.Tasks.App.Start.run([])
        assert Protocol.consolidated?(Enumerable)
      end)
    end)
  end

  defmodule UmbrellaDeps do
    def project do
      [apps_path: "apps", deps: [{:some_dep, path: "deps/some_dep"}]]
    end
  end

  test "loads umbrella dependencies" do
    in_fixture("umbrella_dep/deps/umbrella", fn ->
      Mix.Project.push(UmbrellaDeps)

      File.mkdir_p!("deps/some_dep/ebin")
      File.mkdir_p!("_build/dev/lib/some_dep/ebin")
      File.mkdir_p!("_build/dev/lib/foo/ebin")
      File.mkdir_p!("_build/dev/lib/bar/ebin")

      Mix.Task.run("loadpaths", ["--no-deps-check", "--no-elixir-version-check"])
      assert to_charlist(Path.expand("_build/dev/lib/some_dep/ebin")) in :code.get_path()
      assert to_charlist(Path.expand("_build/dev/lib/foo/ebin")) in :code.get_path()
      assert to_charlist(Path.expand("_build/dev/lib/bar/ebin")) in :code.get_path()
    end)
  end

  test "loads umbrella child dependencies in all environments" do
    in_fixture("umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project(:umbrella, ".", fn _ ->
        File.write!("apps/bar/mix.exs", """
        defmodule Bar.MixProject do
          use Mix.Project

          def project do
            [app: :bar,
             version: "0.1.0",
             deps: [{:git_repo, git: MixTest.Case.fixture_path("git_repo"), only: :other}]]
          end
        end
        """)

        # Does not fetch when filtered
        Mix.Tasks.Deps.Get.run(["--only", "dev"])
        refute_received {:mix_shell, :info, ["* Getting git_repo" <> _]}

        # But works across all environments
        Mix.Tasks.Deps.Get.run([])
        assert_received {:mix_shell, :info, ["* Getting git_repo" <> _]}

        # Does not show by default
        Mix.Tasks.Deps.run([])
        refute_received {:mix_shell, :info, ["* git_repo" <> _]}

        # But shows on proper environment
        Mix.env(:other)
        Mix.Tasks.Deps.run([])
        assert_received {:mix_shell, :info, ["* git_repo " <> _]}
      end)
    end)
  after
    Mix.env(:test)
  end

  test "loads umbrella child optional dependencies" do
    in_fixture("umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project(:umbrella, ".", fn _ ->
        File.write!("apps/bar/mix.exs", """
        defmodule Bar.MixProject do
          use Mix.Project

          def project do
            [app: :bar,
             version: "0.1.0",
             deps: [{:git_repo, git: MixTest.Case.fixture_path("git_repo"), optional: true}]]
          end
        end
        """)

        Mix.Tasks.Deps.run([])
        assert_received {:mix_shell, :info, ["* git_repo " <> _]}
      end)
    end)
  end

  test "loads umbrella sibling dependencies with :in_umbrella" do
    in_fixture("umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project(:umbrella, ".", fn _ ->
        File.write!("apps/bar/mix.exs", """
        defmodule Bar.MixProject do
          use Mix.Project

          def project do
            [app: :bar,
             version: "0.1.0",
             deps: [{:foo, in_umbrella: true}]]
          end
        end
        """)

        # Running from umbrella should not cause conflicts
        Mix.Tasks.Deps.Get.run([])
        Mix.Tasks.Run.run([])
      end)
    end)
  end

  test "conflicts with umbrella sibling dependencies in :in_umbrella" do
    in_fixture("umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project(:umbrella, ".", fn _ ->
        File.write!("apps/bar/mix.exs", """
        defmodule Bar.MixProject do
          use Mix.Project

          def project do
            [app: :bar,
             version: "0.1.0",
             deps: [{:foo, in_umbrella: true, env: :unknown}]]
          end
        end
        """)

        assert_raise Mix.Error, fn ->
          Mix.Tasks.Deps.Get.run([])
        end

        assert_received {:mix_shell, :error, ["Dependencies have diverged:"]}

        assert_received {:mix_shell, :error,
                         ["  the dependency foo in mix.exs is overriding a child" <> message]}

        assert message =~ "Please remove the conflicting options from your definition"
      end)
    end)
  end

  test "list deps for umbrella as dependency" do
    in_fixture("umbrella_dep", fn ->
      Mix.Project.in_project(:umbrella_dep, ".", fn _ ->
        Mix.Task.run("deps")
        assert_received {:mix_shell, :info, ["* umbrella (deps/umbrella) (mix)"]}
        assert_received {:mix_shell, :info, ["* foo (apps/foo) (mix)"]}
      end)
    end)
  end

  # Bar.bar is loaded dynamically
  @compile {:no_warn_undefined, {Bar, :bar, 0}}

  test "compile for umbrella as dependency" do
    in_fixture("umbrella_dep", fn ->
      Mix.Project.in_project(:umbrella_dep, ".", fn _ ->
        Mix.Task.run("compile")
        assert Bar.bar() == "hello world"
      end)
    end)
  end

  test "compile for umbrella as dependency with os partitions" do
    System.put_env("MIX_OS_DEPS_COMPILE_PARTITION_COUNT", "2")

    in_fixture("umbrella_dep", fn ->
      Mix.Project.in_project(:umbrella_dep, ".", fn _ ->
        output = ExUnit.CaptureIO.capture_io(fn -> Mix.Task.run("compile") end)
        assert output =~ ~r/\d> :foo env is prod/
        assert output =~ ~r/\d> :bar env is prod/

        assert_received {:mix_shell, :info, ["mix deps.compile running across 2 OS processes"]}
        assert Bar.bar() == "hello world"
      end)
    end)
  after
    System.delete_env("MIX_OS_DEPS_COMPILE_PARTITION_COUNT")
  end

  defmodule CycleDeps do
    def project do
      [
        app: :umbrella_dep,
        deps: [
          {:bar, path: "deps/umbrella/apps/bar"},
          {:umbrella, path: "deps/umbrella"}
        ]
      ]
    end
  end

  test "handles dependencies with cycles" do
    in_fixture("umbrella_dep", fn ->
      Mix.Project.push(CycleDeps)

      assert Enum.map(Mix.Dep.Converger.converge([]), & &1.app) == [:foo, :bar, :umbrella]
    end)
  end

  test "handles dependencies with cycles and overridden deps" do
    in_fixture("umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project(:umbrella, ".", fn _ ->
        File.write!("apps/foo/mix.exs", """
        defmodule Foo.MixProject do
          use Mix.Project

          def project do
            # Ensure we have the proper environment
            :dev = Mix.env()

            [app: :foo,
             version: "0.1.0",
             deps: [{:bar, in_umbrella: true}]]
          end
        end
        """)

        File.write!("apps/bar/mix.exs", """
        defmodule Bar.MixProject do
          use Mix.Project

          def project do
            # Ensure we have the proper environment
            :dev = Mix.env()

            [app: :bar,
             version: "0.1.0",
             deps: [{:a, path: "deps/a"},
                    {:b, path: "deps/b"}]]
          end
        end
        """)

        assert Enum.map(Mix.Dep.Converger.converge([]), & &1.app) == [:a, :b, :bar, :foo]
      end)
    end)
  end

  test "uses dependency aliases" do
    in_fixture("umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project(:umbrella, ".", fn _ ->
        File.write!("apps/bar/mix.exs", """
        defmodule Bar.MixProject do
          use Mix.Project

          def project do
            [app: :bar,
             version: "0.1.0",
             aliases: ["compile.elixir": fn _ -> Mix.shell().info "no compile bar" end]]
          end
        end
        """)

        Mix.Task.run("compile", ["--verbose"])
        assert_receive {:mix_shell, :info, ["no compile bar"]}
        refute_receive {:mix_shell, :info, ["Compiled lib/bar.ex"]}, 100
      end)
    end)
  end

  test "halts when sibling fails to compile" do
    in_fixture("umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project(:umbrella, ".", fn _ ->
        File.write!("apps/foo/lib/foo.ex", "raise ~s[oops]")

        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert catch_exit(Mix.Task.run("compile", ["--verbose"]))
        end)

        refute_received {:mix_shell, :info, ["Generated foo app"]}
        refute_received {:mix_shell, :info, ["Generated bar app"]}
        refute Code.ensure_loaded?(Bar)
      end)
    end)
  end

  test "recompiles when compile-time path dependencies change" do
    in_fixture("umbrella_dep/deps/umbrella/apps", fn ->
      Mix.Project.in_project(:bar, "bar", fn _ ->
        Mix.Task.run("compile", [])

        # Add compile time dependency
        File.write!("lib/bar.ex", "defmodule Bar, do: Foo.foo()")

        Mix.Task.clear()
        assert Mix.Task.run("compile", ["--verbose"]) == {:ok, []}
        assert_receive {:mix_shell, :info, ["Compiled lib/bar.ex"]}

        # Compile-time dependencies are recompiled
        File.write!("../foo/lib/foo.ex", File.read!("../foo/lib/foo.ex") <> "\n")
        ensure_touched("../foo/lib/foo.ex", "_build/dev/lib/bar/.mix/compile.elixir")

        Mix.Task.clear()
        assert Mix.Task.run("compile", ["--verbose"]) == {:ok, []}
        assert_received {:mix_shell, :info, ["Compiled lib/bar.ex"]}
      end)

      # Now let's add a new file to foo
      Mix.Project.in_project(:foo, "foo", fn _ ->
        File.write!("lib/foo_bar.ex", """
        defmodule Foo.Bar do
          def baz, do: "from bar"
        end
        """)

        Mix.Task.clear()
        assert Mix.Tasks.Compile.run(["--verbose", "--ignore-module-conflict"]) == {:ok, []}
        Application.unload(:foo)
        Application.load(:foo)
      end)

      # And bar can use it without warnings
      Mix.Project.in_project(:bar, "bar", fn _ ->
        File.write!("lib/bar.ex", "defmodule Bar, do: Foo.Bar.baz()")

        mtime = File.stat!("_build/dev/lib/bar/.mix/compile.elixir").mtime
        ensure_touched("_build/dev/lib/foo/.mix/compile.elixir", mtime)
        ensure_touched("_build/dev/lib/foo/ebin/foo.app", mtime)
        ensure_touched("lib/bar.ex", mtime)

        assert Mix.Tasks.Compile.Elixir.run(["--verbose"]) == {:ok, []}
        assert_receive {:mix_shell, :info, ["Compiled lib/bar.ex"]}
      end)
    end)
  end

  test "recompiles after struct path dependency changes" do
    in_fixture("umbrella_dep/deps/umbrella/apps", fn ->
      Mix.Project.in_project(:bar, "bar", fn _ ->
        File.write!("../foo/lib/foo.ex", "defmodule Foo, do: defstruct [:bar]")

        # Add struct dependency
        File.write!("lib/bar.ex", """
        defmodule Bar do
          def is_foo_bar(%Foo{bar: true}), do: true
        end
        """)

        Mix.Task.run("compile", ["--verbose"])
        assert_received {:mix_shell, :info, ["Compiled lib/bar.ex"]}

        # Does not recompiles if export dependency does not change
        File.write!("../foo/lib/foo.ex", File.read!("../foo/lib/foo.ex") <> "\n")
        ensure_touched("../foo/lib/foo.ex", "_build/dev/lib/bar/.mix/compile.elixir")

        Mix.Task.clear()
        assert Mix.Task.run("compile", ["--verbose"]) == {:ok, []}
        refute_received {:mix_shell, :info, ["Compiled lib/bar.ex"]}

        # Recompiles if export dependency changes
        File.write!("../foo/lib/foo.ex", "defmodule Foo, do: defstruct [:bar, :baz]")
        ensure_touched("../foo/lib/foo.ex", "_build/dev/lib/bar/.mix/compile.elixir")

        Mix.Task.clear()
        assert Mix.Task.run("compile", ["--verbose"]) == {:ok, []}
        assert_received {:mix_shell, :info, ["Compiled lib/bar.ex"]}

        # Recompiles if export dependency is removed
        File.write!("../foo/lib/foo.ex", "")
        ensure_touched("../foo/lib/foo.ex", "_build/dev/lib/bar/.mix/compile.elixir")
        Mix.Task.clear()

        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          assert {:error, _} = Mix.Task.run("compile", ["--verbose", "--return-errors"])
        end)
      end)
    end)
  end

  test "recompiles after compile through runtime path dependency changes" do
    in_fixture("umbrella_dep/deps/umbrella/apps", fn ->
      Mix.Project.in_project(:bar, "bar", fn _ ->
        File.write!("../foo/lib/foo.bar.ex", """
        defmodule Foo.Bar do
          def hello, do: Foo.Baz.hello()
        end
        """)

        File.write!("../foo/lib/foo.baz.ex", """
        defmodule Foo.Baz do
          def hello, do: "from bar"
        end
        """)

        # Add compile time to Foo.Bar
        File.write!("lib/bar.ex", "defmodule Bar, do: Foo.Bar.hello()")
        Mix.Task.run("compile", ["--verbose"])
        assert_received {:mix_shell, :info, ["Compiled lib/bar.ex"]}

        # Recompiles for due to compile dependency via runtime dependencies
        File.write!("../foo/lib/foo.baz.ex", File.read!("../foo/lib/foo.baz.ex") <> "\n")
        ensure_touched("../foo/lib/foo.ex", "_build/dev/lib/bar/.mix/compile.elixir")

        Mix.Task.clear()
        assert Mix.Task.run("compile", ["--verbose"]) == {:ok, []}
        assert_received {:mix_shell, :info, ["Compiled lib/bar.ex"]}
      end)
    end)
  end

  test "reverifies when path dependency is added" do
    in_fixture("umbrella_dep/deps/umbrella/apps", fn ->
      Mix.Project.in_project(:bar, "bar", [deps: []], fn _ ->
        File.write!("lib/bar.ex", """
        defmodule Bar do
          def foo, do: Foo.foo()
        end
        """)

        assert ExUnit.CaptureIO.capture_io(:stderr, fn ->
                 Mix.Task.run("compile", ["--verbose"])
               end) =~ "Foo.foo/0 is undefined"

        refute Code.ensure_loaded?(Foo)
        assert_receive {:mix_shell, :info, ["Compiled lib/bar.ex"]}
      end)

      Mix.Task.clear()

      Mix.Project.in_project(:bar, "bar", fn _ ->
        Mix.Task.run("deps.compile")
        assert Mix.Task.run("compile", ["--verbose", "--all-warnings"]) == {:ok, []}
      end)
    end)
  end

  test "reloads app in app cache if .app changes" do
    in_fixture("umbrella_dep/deps/umbrella/apps", fn ->
      deps = [{:foo, in_umbrella: true}]

      Mix.Project.in_project(:bar, "bar", [deps: deps], fn _ ->
        Mix.Task.run("compile", ["--verbose"])

        File.write!("../foo/lib/foo.ex", """
        defmodule Foo.VeryNew do
          def hello, do: :ok
        end
        """)

        File.write!("lib/bar.ex", """
        defmodule Bar.VeryNew do
          def hello, do: Foo.VeryNew.hello()
        end
        """)

        Mix.Task.clear()
        Application.unload(:foo)
        ensure_touched("../foo/lib/foo.ex", "_build/dev/lib/bar/.mix/compile.app_cache")

        assert Mix.Task.run("compile", ["--verbose"]) == {:ok, []}
        assert_receive {:mix_shell, :info, ["Compiled lib/bar.ex"]}
      end)
    end)
  end

  test "reconsolidates after path dependency changes" do
    in_fixture("umbrella_dep/deps/umbrella/apps", fn ->
      Mix.Project.in_project(:bar, "bar", fn _ ->
        # Add a protocol dependency
        File.write!("../foo/lib/foo.ex", """
        defprotocol Foo do
          def foo(arg)
        end
        defimpl Foo, for: List do
          def foo(list), do: list
        end
        """)

        Mix.Task.run("compile")
        assert File.regular?("_build/dev/lib/bar/consolidated/Elixir.Foo.beam")
        assert Mix.Tasks.Compile.Elixir.run([]) == {:noop, []}

        # Mark protocol as outdated
        File.touch!("_build/dev/lib/bar/consolidated/Elixir.Foo.beam", {{2010, 1, 1}, {0, 0, 0}})
        force_recompilation("../foo/lib/foo.ex")
        ensure_touched("../foo/lib/foo.ex", "_build/dev/lib/bar/.mix/compile.elixir")
        Mix.Task.clear()
        Mix.Task.run("compile")

        # Check new timestamp
        mtime = File.stat!("_build/dev/lib/bar/consolidated/Elixir.Foo.beam").mtime
        assert mtime > {{2010, 1, 1}, {0, 0, 0}}
      end)
    end)
  end

  test "reconsolidates using umbrella parent information on shared _build" do
    in_fixture("umbrella_dep/deps/umbrella", fn ->
      File.write!("apps/bar/lib/bar.ex", """
      defprotocol Bar do
        def bar(arg)
      end
      defimpl Bar, for: List do
        def bar(list), do: list
      end
      """)

      Mix.Project.in_project(:foo, "apps/foo", [build_path: "../../_build"], fn _ ->
        Mix.Task.run("compile.protocols")
        refute Code.ensure_loaded?(Bar)
      end)

      Mix.Project.in_project(:umbrella, ".", fn _ ->
        Mix.Task.run("compile")
        assert Protocol.consolidated?(Bar)
      end)
    end)
  end

  test "reconsolidates using umbrella child information on shared _build" do
    in_fixture("umbrella_dep/deps/umbrella", fn ->
      File.write!("apps/bar/lib/bar.ex", """
      defprotocol Bar do
        def foo(arg)
      end
      defimpl Bar, for: List do
        def foo(list), do: list
      end
      """)

      Mix.Project.in_project(:umbrella, ".", fn _ ->
        Mix.Task.run("compile.protocols")
      end)

      # Emulate the dependency being removed
      Mix.Project.in_project(:foo, "apps/foo", [build_path: "../../_build", deps: []], fn _ ->
        File.rm_rf("../../_build/dev/lib/bar")
        Mix.Task.run("compile.protocols")
      end)
    end)
  end

  test "apps cannot refer to themselves as a dep" do
    in_fixture("umbrella_dep/deps/umbrella", fn ->
      Mix.Project.in_project(:umbrella, ".", fn _ ->
        File.write!("apps/bar/mix.exs", """
        defmodule Bar.MixProject do
          use Mix.Project

          def project do
            [app: :bar,
             version: "0.1.0",
             deps: [{:bar, in_umbrella: true}]]
          end
        end
        """)

        assert_raise Mix.Error, "App bar lists itself as a dependency", fn ->
          Mix.Task.run("deps.get", ["--verbose"]) == [:ok, :ok]
        end
      end)
    end)
  end
end
