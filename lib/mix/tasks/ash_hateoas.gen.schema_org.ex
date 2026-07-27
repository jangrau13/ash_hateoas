if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshHateoas.Gen.SchemaOrg do
    @moduledoc """
    Generates an Ash resource from a schema.org type, fetched live.

        mix ash_hateoas.gen.schema_org Person --domain MyApp.People
        mix ash_hateoas.gen.schema_org https://schema.org/Recipe --domain MyApp.Cookbook

    The generated resource carries `AshHateoas.Resource`, declares
    `semantic_type "<Type>"`, and adds one attribute per schema.org property with
    a matching `semantic_property` mapping — so every field is published under its
    well-known IRI with no hand-transcription.

    ## Options

      * `--domain` — the Ash domain module the resource belongs to (required).
      * `--resource` — the resource module name. Defaults to `<domain>.<Type>`.
      * `--inherited` — also include properties inherited from ancestor types.
      * `--data-layer` — `ets` (default) or `none`.
    """
    @shortdoc "Generate an Ash resource from a schema.org type"

    use Igniter.Mix.Task

    alias AshHateoas.SchemaOrg

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        positional: [:type],
        example: "mix ash_hateoas.gen.schema_org Person --domain MyApp.People",
        schema: [
          domain: :string,
          resource: :string,
          inherited: :boolean,
          data_layer: :string
        ]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      %{positional: %{type: type}, options: options} = igniter.args

      domain = options[:domain]

      cond do
        is_nil(domain) ->
          Igniter.add_issue(
            igniter,
            "--domain is required (the Ash domain module for the resource)."
          )

        not Code.ensure_loaded?(Req) ->
          Igniter.add_issue(
            igniter,
            "This generator needs the :req dependency. Add {:req, \"~> 0.5\"} and run mix deps.get."
          )

        true ->
          generate(igniter, type, domain, options)
      end
    end

    defp generate(igniter, type, domain, options) do
      case SchemaOrg.resolve(type, inherited: options[:inherited] || false) do
        {:ok, type_def} ->
          resource = resource_module(options[:resource], domain, type_def.label)
          contents = resource_source(resource, domain, type_def, options)

          igniter
          |> Igniter.Project.Module.create_module(resource, contents)
          |> Igniter.add_notice("""
          Generated #{inspect(resource)} from #{type_def.iri}
          (#{length(type_def.properties)} properties).

          Register it in #{domain}'s `resources` block, review the attributes
          (schema.org ranges are broad — several map to :string), and mount
          AshHateoas.Hydra.Plug to serve it.
          """)

        {:error, {:type_not_found, label}} ->
          Igniter.add_issue(igniter, "schema.org has no type named #{inspect(label)}.")

        {:error, reason} ->
          Igniter.add_issue(igniter, "Could not fetch schema.org: #{inspect(reason)}.")
      end
    end

    defp resource_module(nil, domain, label) do
      Module.concat(domain, Macro.camelize(label))
    end

    defp resource_module(name, _domain, _label) when is_binary(name) do
      Igniter.Project.Module.parse(name)
    end

    defp resource_source(_resource, domain, type_def, options) do
      data_layer = data_layer(options[:data_layer])
      snake = Macro.underscore(type_def.label)

      """
      use Ash.Resource,
        domain: #{inspect(Igniter.Project.Module.parse(domain))},#{data_layer}
        extensions: [AshHateoas.Resource]
      #{ets_block(options[:data_layer])}
      hateoas do
        type "#{snake}"
        semantic_type "#{type_def.label}"
      #{semantic_properties(type_def.properties)}
      end

      attributes do
        uuid_primary_key :id

      #{attributes(type_def.properties)}
      end

      actions do
        defaults [:read, :destroy, create: #{inspect(accept(type_def.properties))}, update: #{inspect(accept(type_def.properties))}]
      end
      """
    end

    defp data_layer("none"), do: ""
    defp data_layer(_), do: "\n  data_layer: Ash.DataLayer.Ets,"

    defp ets_block("none"), do: ""

    defp ets_block(_) do
      """

        ets do
          private? true
        end
      """
    end

    defp semantic_properties(properties) do
      Enum.map_join(properties, "\n", fn p ->
        ~s(    semantic_property :#{p.name}, "#{p.iri}")
      end)
    end

    defp attributes(properties) do
      Enum.map_join(properties, "\n", fn p ->
        doc = doc_string(p)
        "    attribute :#{p.name}, #{type_expr(p.ash_type)}, public?: true#{doc}"
      end)
    end

    # A scalar Ash type renders as an atom (`:string`); the resource-link type is
    # a module reference, so it is rendered as the module itself.
    defp type_expr(AshHateoas.Type.ResourceLink), do: "AshHateoas.Type.ResourceLink"
    defp type_expr(ash_type), do: ":#{ash_type}"

    # A link to another schema.org type is noted in the attribute's description,
    # so the author knows what the followable IRI is expected to point at.
    defp doc_string(%{links_to: linked} = p) when is_binary(linked) do
      base = p.description && one_line(p.description)
      note = "Links to a schema.org #{linked}."
      text = if base, do: base <> " " <> note, else: note
      ", description: #{inspect(text)}"
    end

    defp doc_string(%{description: description}) when is_binary(description) do
      ", description: #{inspect(one_line(description))}"
    end

    defp doc_string(_), do: ""

    defp accept(properties), do: Enum.map(properties, &String.to_atom(&1.name))

    defp one_line(text) do
      text |> String.replace(~r/\s+/, " ") |> String.trim()
    end
  end
else
  defmodule Mix.Tasks.AshHateoas.Gen.SchemaOrg do
    @moduledoc "Generate an Ash resource from a schema.org type. Requires igniter."
    @shortdoc @moduledoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      'ash_hateoas.gen.schema_org' requires igniter. Add {:igniter, "~> 0.8"} and
      {:req, "~> 0.5"}, then try again.
      """)

      exit({:shutdown, 1})
    end
  end
end
