if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshHateoas.Install do
    @moduledoc "Installs AshHateoas. Should be run with `mix igniter.install ash_hateoas`"
    @shortdoc @moduledoc

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        example: "mix igniter.install ash_hateoas"
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter
      |> Igniter.Project.Formatter.import_dep(:ash_hateoas)
      |> Spark.Igniter.prepend_to_section_order(:"Ash.Resource", [:hateoas])
      |> Igniter.add_notice("""
      AshHateoas installed.

      Add the extension to the resources that should expose affordances:

          use Ash.Resource,
            extensions: [AshJsonApi.Resource, AshHateoas.Resource]

      For the JSON:API rendering, wire the transform into your router and
      pipeline:

          defmodule MyAppWeb.JsonApiRouter do
            use AshJsonApi.Router,
              domains: [MyApp.MyDomain],
              before_dispatch: {AshHateoas.JsonApi.Transform, :before_dispatch, []}
          end

          # then, ahead of the router in your pipeline:
          plug AshHateoas.JsonApi.Transform

      Both halves are required — without the before_dispatch capture the
      transform cannot resolve route context and becomes a no-op.
      """)
    end
  end
else
  defmodule Mix.Tasks.AshHateoas.Install do
    @moduledoc "Installs AshHateoas. Should be run with `mix igniter.install ash_hateoas`"
    @shortdoc @moduledoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_hateoas.install' requires igniter. Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
