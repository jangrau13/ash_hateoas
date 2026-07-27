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
          data_layer: :string,
          internal: :string,
          yes: :boolean
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

          # A link whose range is another schema.org type is INTERNAL — a real
          # `belongs_to` — when this domain already serves that type (or it is a
          # self-reference to the type being generated); otherwise EXTERNAL, a
          # followable `ResourceLink`. Only a genuinely ambiguous case prompts.
          served = served_types(domain, type_def.label, resource, options)
          properties = Enum.map(type_def.properties, &classify(&1, served, options))

          contents = resource_source(resource, domain, type_def, properties, options)

          igniter
          |> Igniter.Project.Module.create_module(resource, contents)
          |> Igniter.add_notice(notice(resource, domain, type_def, properties))

        {:error, {:type_not_found, label}} ->
          Igniter.add_issue(igniter, "schema.org has no type named #{inspect(label)}.")

        {:error, reason} ->
          Igniter.add_issue(igniter, "Could not fetch schema.org: #{inspect(reason)}.")
      end
    end

    # `%{schema_type_label => resource_module}` for every resource the domain
    # serves, plus the type being generated (a self-reference resolves to it),
    # plus any `--internal` types the author forced. Read from each resource's
    # `hateoas` `semantic_type`/`type`; a resource may not have compiled yet, so
    # failures are skipped rather than fatal.
    defp served_types(domain, label, resource, options) do
      base =
        domain
        |> Igniter.Project.Module.parse()
        |> domain_resources()
        |> Enum.flat_map(&served_label(&1))
        |> Map.new()
        |> Map.put(label, resource)

      forced =
        (options[:internal] || "")
        |> String.split(",", trim: true)
        |> Enum.map(&{String.trim(&1), :forced})
        |> Map.new()

      Map.merge(base, forced)
    end

    defp domain_resources(domain) do
      Ash.Domain.Info.resources(domain)
    rescue
      _ -> []
    end

    defp served_label(resource) do
      case AshHateoas.Resource.Info.semantic_type(resource) do
        iri when is_binary(iri) -> [{iri |> String.split("/") |> List.last(), resource}]
        _ -> []
      end
    rescue
      _ -> []
    end

    # Decide internal vs external for a type-range property, asking only when the
    # scan is genuinely ambiguous (a served type maps to no usable module).
    defp classify(%{links_to: nil} = property, _served, _options), do: property

    defp classify(%{links_to: linked} = property, served, options) do
      case Map.get(served, linked) do
        nil ->
          # Not served — external. This is the common, unambiguous case.
          property

        :forced ->
          # `--internal` named it but the domain does not serve it yet: we have
          # no destination module. Ambiguous — ask (default external).
          if ask_internal?(property, linked, options) do
            Map.put(property, :relationship, :unknown_destination)
          else
            property
          end

        module ->
          # Served — a real internal relationship to that resource.
          Map.put(property, :relationship, module)
      end
    end

    defp ask_internal?(property, linked, options) do
      if options[:yes] do
        false
      else
        Igniter.Util.IO.yes?(
          "`#{property.name}` links to #{linked}, which #{inspect(linked)} is not served here yet. " <>
            "Generate it as an internal relationship anyway?"
        )
      end
    rescue
      _ -> false
    end

    defp resource_module(nil, domain, label) do
      Module.concat(domain, Macro.camelize(label))
    end

    defp resource_module(name, _domain, _label) when is_binary(name) do
      Igniter.Project.Module.parse(name)
    end

    defp resource_source(_resource, domain, type_def, properties, options) do
      data_layer = data_layer(options[:data_layer])
      snake = Macro.underscore(type_def.label)

      {internal, plain} = Enum.split_with(properties, &Map.get(&1, :relationship))

      """
      use Ash.Resource,
        domain: #{inspect(Igniter.Project.Module.parse(domain))},#{data_layer}
        extensions: [AshHateoas.Resource]
      #{ets_block(options[:data_layer])}
      hateoas do
        type "#{snake}"
        semantic_type "#{type_def.label}"
      #{semantic_properties(plain)}
      end

      attributes do
        uuid_primary_key :id

      #{attributes(plain)}
      end
      #{relationships_block(internal)}
      actions do
        defaults [:read, :destroy, create: #{inspect(accept(plain))}, update: #{inspect(accept(plain))}]
      end
      """
    end

    # An internal link becomes a `belongs_to` — a to-one reference to a resource
    # this domain serves. (A conceptually to-many schema.org property, e.g.
    # `children`, still generates a `belongs_to`; adjust to `has_many` by hand if
    # the far side owns the key.)
    defp relationships_block([]), do: ""

    defp relationships_block(internal) do
      entries =
        Enum.map_join(internal, "\n", fn p ->
          "    belongs_to :#{p.name}, #{destination(p.relationship)}, public?: true"
        end)

      """

        relationships do
      #{entries}
        end
      """
    end

    defp destination(:unknown_destination), do: "# TODO: the resource for this type"
    defp destination(module), do: inspect(module)

    defp notice(resource, domain, type_def, properties) do
      {internal, plain} = Enum.split_with(properties, &Map.get(&1, :relationship))
      links = Enum.filter(plain, & &1.links_to)

      """
      Generated #{inspect(resource)} from #{type_def.iri} \
      (#{length(type_def.properties)} properties).

        internal relationships (belongs_to): #{names(internal)}
        external links (ResourceLink):       #{names(links)}

      Register it in #{domain}'s `resources` block, review the attributes
      (schema.org ranges are broad — several map to :string), and mount
      AshHateoas.Hydra.Plug to serve it.
      """
    end

    defp names([]), do: "—"
    defp names(properties), do: Enum.map_join(properties, ", ", & &1.name)

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
