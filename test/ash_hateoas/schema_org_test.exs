defmodule AshHateoas.SchemaOrgTest do
  @moduledoc """
  Resolution logic against a small in-memory graph — no network.
  """

  use ExUnit.Case, async: true

  alias AshHateoas.SchemaOrg

  # A minimal slice of the schema.org shape: a Person class, a scalar property,
  # a property whose range is another type, and one whose range is both.
  @graph [
    %{"@id" => "schema:Person", "@type" => "rdfs:Class", "rdfs:comment" => "A person."},
    %{"@id" => "schema:Organization", "@type" => "rdfs:Class"},
    %{"@id" => "schema:PostalAddress", "@type" => "rdfs:Class"},
    %{
      "@id" => "schema:additionalName",
      "@type" => "rdf:Property",
      "rdfs:label" => "additionalName",
      "rdfs:comment" => "An additional name.",
      "schema:domainIncludes" => %{"@id" => "schema:Person"},
      "schema:rangeIncludes" => %{"@id" => "schema:Text"}
    },
    %{
      "@id" => "schema:affiliation",
      "@type" => "rdf:Property",
      "rdfs:label" => "affiliation",
      "schema:domainIncludes" => %{"@id" => "schema:Person"},
      "schema:rangeIncludes" => %{"@id" => "schema:Organization"}
    },
    %{
      "@id" => "schema:birthDate",
      "@type" => "rdf:Property",
      "rdfs:label" => "birthDate",
      "schema:domainIncludes" => %{"@id" => "schema:Person"},
      "schema:rangeIncludes" => %{"@id" => "schema:Date"}
    },
    %{
      "@id" => "schema:address",
      "@type" => "rdf:Property",
      "rdfs:label" => "address",
      "schema:domainIncludes" => %{"@id" => "schema:Person"},
      # both a type and a scalar — the scalar wins
      "schema:rangeIncludes" => [%{"@id" => "schema:PostalAddress"}, %{"@id" => "schema:Text"}]
    },
    %{
      "@id" => "schema:legalName",
      "@type" => "rdf:Property",
      "rdfs:label" => "legalName",
      "schema:domainIncludes" => %{"@id" => "schema:Organization"},
      "schema:rangeIncludes" => %{"@id" => "schema:Text"}
    }
  ]

  defp resolve(type, opts \\ []), do: SchemaOrg.resolve(type, Keyword.put(opts, :graph, @graph))

  test "resolves a type by label or URL" do
    assert {:ok, by_label} = resolve("Person")
    assert {:ok, by_url} = resolve("https://schema.org/Person")

    assert by_label.iri == "https://schema.org/Person"
    assert by_label.description == "A person."
    assert Map.keys(by_url) == Map.keys(by_label)
  end

  test "collects only the type's own domain properties" do
    {:ok, person} = resolve("Person")
    names = Enum.map(person.properties, & &1.name)

    assert "additional_name" in names
    assert "affiliation" in names
    refute "legal_name" in names, "legalName belongs to Organization, not Person"
  end

  test "maps a scalar range to an Ash scalar type" do
    {:ok, person} = resolve("Person")

    birth = Enum.find(person.properties, &(&1.name == "birth_date"))
    assert birth.ash_type == :date
    assert birth.links_to == nil
    assert birth.iri == "https://schema.org/birthDate"
  end

  test "maps a type range to a resource link, recording the linked type" do
    {:ok, person} = resolve("Person")

    affiliation = Enum.find(person.properties, &(&1.name == "affiliation"))
    assert affiliation.ash_type == AshHateoas.Type.ResourceLink
    assert affiliation.links_to == "Organization"
  end

  test "a scalar range wins over a type range" do
    {:ok, person} = resolve("Person")

    address = Enum.find(person.properties, &(&1.name == "address"))
    assert address.ash_type == :string
    assert address.links_to == nil
  end

  test "an unknown type is an error" do
    assert {:error, {:type_not_found, "Nope"}} = resolve("Nope")
  end
end
