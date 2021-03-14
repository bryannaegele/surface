defmodule Mix.Tasks.Compile.Surface do
  @moduledoc """
  Generate CSS and JS assets for components.
  """

  use Mix.Task
  @recursive true

  @default_hooks_output_dir "assets/js/_hooks"
  @hooks_extension ".hooks.js"

  @doc false
  def run(_args) do
    case get_colocated_assets() |> generate_files() do
      "" -> {:noop, []}
      _ -> {:ok, []}
    end
  end

  @doc false
  def generate_files({js_files, _css_files}) do
    opts = Application.get_env(:surface, :compiler, [])

    hooks_output_dir = Keyword.get(opts, :hooks_output_dir, @default_hooks_output_dir)
    js_output_dir = Path.join([File.cwd!(), hooks_output_dir])
    index_file = Path.join([js_output_dir, "index.js"])

    File.mkdir_p!(js_output_dir)

    unused_hooks_files = delete_unused_hooks_files!(js_output_dir, js_files)

    index_file_time =
      case File.stat(index_file) do
        {:ok, %File.Stat{mtime: time}} -> time
        _ -> nil
      end

    update_index? =
      for {src_file, dest_file_name} <- js_files,
          dest_file = Path.join(js_output_dir, dest_file_name),
          {:ok, %File.Stat{mtime: time}} <- [File.stat(src_file)],
          !File.exists?(dest_file) or time > index_file_time,
          reduce: false do
        _ ->
          File.cp!(src_file, dest_file)
          true
      end

    if !index_file_time or update_index? or unused_hooks_files != [] do
      File.write!(index_file, index_content(js_files))
    end
  end

  defp get_colocated_assets() do
    for [app] <- applications(),
        mod <- app_modules(app),
        module_loaded?(mod),
        function_exported?(mod, :component_type, 0),
        reduce: {[], []} do
      {js_files, css_files} ->
        base_file = mod.module_info() |> get_in([:compile, :source]) |> Path.rootname()
        js_file = "#{base_file}#{@hooks_extension}"
        base_name = inspect(mod)
        dest_js_file = "#{base_name}#{@hooks_extension}"
        css_file = "#{base_file}.css"
        dest_css_file = "#{base_name}.css"

        js_files =
          if File.exists?(js_file), do: [{js_file, dest_js_file} | js_files], else: js_files

        css_files =
          if File.exists?(css_file), do: [{css_file, dest_css_file} | css_files], else: css_files

        {js_files, css_files}
    end
  end

  defp index_content([]) do
    """
    /* This file was generated by the Surface compiler */

    export default {}
    """
  end

  defp index_content(js_files) do
    files = js_files |> Enum.sort() |> Enum.with_index(1)

    {hooks, imports} =
      for {{_file, dest_file}, index} <- files, reduce: {[], []} do
        {hooks, imports} ->
          namespace = Path.basename(dest_file, @hooks_extension)
          var = "c#{index}"
          hook = ~s[ns(#{var}, "#{namespace}")]
          imp = ~s[import * as #{var} from "./#{namespace}.hooks"]
          {[hook | hooks], [imp | imports]}
      end

    hooks = Enum.reverse(hooks)
    imports = Enum.reverse(imports)

    """
    /* This file was generated by the Surface compiler */

    function ns(hooks, nameSpace) {
      const updatedHooks = {}
      Object.keys(hooks).map(function(key) {
        updatedHooks[`${nameSpace}#${key}`] = hooks[key]
      })
      return updatedHooks
    }

    #{Enum.join(imports, "\n")}

    let hooks = Object.assign(
      #{Enum.join(hooks, ",\n  ")}
    )

    export default hooks
    """
  end

  defp delete_unused_hooks_files!(js_output_dir, js_files) do
    used_files = Enum.map(js_files, fn {_, dest_file} -> Path.join(js_output_dir, dest_file) end)

    all_files =
      js_output_dir
      |> Path.join("*#{@hooks_extension}")
      |> Path.wildcard()

    unsused_files = all_files -- used_files
    Enum.each(unsused_files, &File.rm!/1)
    unsused_files
  end

  defp app_modules(app) do
    app
    |> Application.app_dir()
    |> Path.join("ebin/Elixir.*.beam")
    |> Path.wildcard()
    |> Enum.map(&beam_to_module/1)
  end

  defp beam_to_module(path) do
    path |> Path.basename(".beam") |> String.to_atom()
  end

  defp applications do
    # If we invoke :application.loaded_applications/0,
    # it can error if we don't call safe_fixtable before.
    # Since in both cases we are reaching over the
    # application controller internals, we choose to match
    # for performance.
    apps = :ets.match(:ac_tab, {{:loaded, :"$1"}, :_})

    # Make sure we have the project's app (it might not be there when first compiled)
    apps = [[Mix.Project.config()[:app]] | apps]

    apps
    |> MapSet.new()
    |> MapSet.to_list()
  end

  defp module_loaded?(module) do
    match?({:module, _mod}, Code.ensure_compiled(module))
  end
end