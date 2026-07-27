defmodule AshHateoas.SemanticVocab do
  @moduledoc """
  The well-known vocabulary a bare semantic token resolves against.

  `semantic_type "Person"`, `semantic_property :name, "givenName"` and
  `semantic_action :confirm, "ConfirmAction"` all accept a **bare token** — a
  convenience for the common case. A bare token is expanded against this
  vocabulary; an **absolute IRI** (anything containing `"://"`) is always used
  verbatim, so any ontology works with no configuration at all.

  By default the vocabulary is **schema.org** (`https://schema.org/`, prefix
  `schema`). A customer whose resources are typed by a different ontology can make
  *that* the default a bare token resolves against:

      config :ash_hateoas,
        semantic_vocab: [
          base: "http://www.ease-crc.org/ont/SOMA.owl#",
          prefix: "soma"
        ]

  With this set, `semantic_type "Grasping"` resolves to
  `http://www.ease-crc.org/ont/SOMA.owl#Grasping`, and the emitted `@context`
  declares `"soma"` as the prefix so those IRIs compact. schema.org remains
  available at any time via an absolute IRI (`"https://schema.org/Person"`) or by
  leaving the config unset.

  This changes only what a **bare** token means; absolute IRIs are unaffected, so
  a resource can always mix vocabularies by writing full IRIs.
  """

  @default_base "https://schema.org/"
  @default_prefix "schema"

  @doc """
  The base IRI a bare token is expanded against (default `https://schema.org/`).
  """
  @spec base() :: String.t()
  def base do
    Keyword.get(config(), :base, @default_base)
  end

  @doc """
  The `@context` prefix for the configured vocabulary base (default `schema`).
  """
  @spec prefix() :: String.t()
  def prefix do
    Keyword.get(config(), :prefix, @default_prefix)
  end

  @doc """
  Resolve a bare token or absolute IRI to a full IRI.

  An absolute IRI (contains `"://"`) is returned verbatim; a bare token is
  prepended with the configured `base/0`.
  """
  @spec resolve(String.t()) :: String.t()
  def resolve(value) when is_binary(value) do
    if String.contains?(value, "://") do
      value
    else
      base() <> value
    end
  end

  defp config do
    Application.get_env(:ash_hateoas, :semantic_vocab, [])
  end
end
