# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2021 The Elixir Team
# SPDX-FileCopyrightText: 2012 Plataformatec

defmodule Function do
  @moduledoc """
  A set of functions for working with functions.

  Anonymous functions are typically created by using `fn`:

      iex> add = fn a, b -> a + b end
      iex> add.(1, 2)
      3

  Anonymous functions can also have multiple clauses. All clauses
  should expect the same number of arguments:

      iex> negate = fn
      ...>   true -> false
      ...>   false -> true
      ...> end
      iex> negate.(false)
      true

  ## The capture operator

  It is also possible to capture public module functions and pass them
  around as if they were anonymous functions by using the capture
  operator `&/1`:

      iex> add = &Kernel.+/2
      iex> add.(1, 2)
      3

      iex> length = &String.length/1
      iex> length.("hello")
      5

  To capture a definition within the current module, you can skip the
  module prefix, such as `&my_fun/2`. In those cases, the captured
  function can be public (`def`) or private (`defp`).

  The capture operator can also be used to create anonymous functions
  that expect at least one argument:

      iex> add = &(&1 + &2)
      iex> add.(1, 2)
      3

  In such cases, using the capture operator is no different than using `fn`.

  ## Internal and external functions

  We say that functions that point to definitions residing in modules, such
  as `&String.length/1`, are **external** functions. All other functions are
  **local** and they are always bound to the file or module that defined them.

  Besides the functions in this module to work with functions, `Kernel` also
  has an `apply/2` function that invokes a function with a dynamic number of
  arguments, as well as `is_function/1` and `is_function/2`, to check
  respectively if a given value is a function or a function of a given arity.
  """

  @type information ::
          :arity
          | :env
          | :index
          | :module
          | :name
          | :new_index
          | :new_uniq
          | :pid
          | :type
          | :uniq

  @doc """
  Captures the given function.

  Inlined by the compiler.

  ## Examples

      iex> Function.capture(String, :length, 1)
      &String.length/1

  """
  @doc since: "1.7.0"
  @spec capture(module, atom, arity) :: fun
  def capture(module, function_name, arity) do
    :erlang.make_fun(module, function_name, arity)
  end

  @doc """
  Returns a keyword list with information about a function.

  The returned keys (with the corresponding possible values) for
  all types of functions (local and external) are the following:

    * `:type` - `:local` (for anonymous functions) or `:external` (for
      named functions).

    * `:module` - an atom which is the module where the function is defined when
    anonymous or the module which the function refers to when it's a named function.

    * `:arity` - (integer) the number of arguments the function is to be called with.

    * `:name` - (atom) the name of the function.

    * `:env` - a list of the environment or free variables. For named
      functions, the returned list is always empty.

  When `fun` is an anonymous function (that is, the type is `:local`), the following
  additional keys are returned:

    * `:pid` - PID of the process that originally created the function.

    * `:index` - (integer) an index into the module function table.

    * `:new_index` - (integer) an index into the module function table.

    * `:new_uniq` - (binary) a unique value for this function. It's
      calculated from the compiled code for the entire module.

    * `:uniq` - (integer) a unique value for this function. This integer is
      calculated from the compiled code for the entire module.

  **Note**: this function must be used only for debugging purposes.

  Inlined by the compiler.

  ## Examples

      iex> fun = fn x -> x end
      iex> info = Function.info(fun)
      iex> Keyword.get(info, :arity)
      1
      iex> Keyword.get(info, :type)
      :local

      iex> fun = &String.length/1
      iex> info = Function.info(fun)
      iex> Keyword.get(info, :type)
      :external
      iex> Keyword.get(info, :name)
      :length

  """
  @doc since: "1.7.0"
  @spec info(fun) :: [{information, term}]
  def info(fun), do: :erlang.fun_info(fun)

  @doc """
  Returns a specific information about the function.

  The returned information is a two-element tuple in the shape of
  `{info, value}`.

  For any function, the information asked for can be any of the atoms
  `:module`, `:name`, `:arity`, `:env`, or `:type`.

  For anonymous functions, there is also information about any of the
  atoms `:index`, `:new_index`, `:new_uniq`, `:uniq`, and `:pid`.
  For a named function, the value of any of these items is always the
  atom `:undefined`.

  For more information on each of the possible returned values, see
  `info/1`.

  Inlined by the compiler.

  ## Examples

      iex> f = fn x -> x end
      iex> Function.info(f, :arity)
      {:arity, 1}
      iex> Function.info(f, :type)
      {:type, :local}

      iex> fun = &String.length/1
      iex> Function.info(fun, :name)
      {:name, :length}
      iex> Function.info(fun, :pid)
      {:pid, :undefined}

  """
  @doc since: "1.7.0"
  @spec info(fun, item) :: {item, term} when item: information
  def info(fun, item), do: :erlang.fun_info(fun, item)

  @doc """
  Returns its input `value`. This function can be passed as an anonymous function
  to transformation functions.

  ## Examples

      iex> Function.identity("Hello world!")
      "Hello world!"

      iex> ~c"abcdaabccc" |> Enum.sort() |> Enum.chunk_by(&Function.identity/1)
      [~c"aaa", ~c"bb", ~c"cccc", ~c"d"]

      iex> Enum.group_by(~c"abracadabra", &Function.identity/1)
      %{97 => ~c"aaaaa", 98 => ~c"bb", 99 => ~c"c", 100 => ~c"d", 114 => ~c"rr"}

      iex> Enum.map([1, 2, 3, 4], &Function.identity/1)
      [1, 2, 3, 4]

  """
  @doc since: "1.10.0"
  @spec identity(value) :: value when value: var
  def identity(value), do: value
end
