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
            extensions: [AshHateoas.Resource]

      Then mount the Hydra plug to serve those resources as a Hydra / JSON-LD
      API (`application/ld+json`):

          defmodule MyAppWeb.HydraRouter do
            use Plug.Builder

            plug AshHateoas.Hydra.Plug,
              domains: [MyApp.MyDomain],
              prefix: "/api",
              doc_path: "/doc"
          end

      Every route is derived from the resource's actions; a resource declares a
      `hateoas` `type` (or lets one be inferred from its module name) and nothing
      else.
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
