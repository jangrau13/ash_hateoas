defmodule AshHateoas.Type.ResourceLink do
  @moduledoc """
  A string attribute whose value is the URL of another hypermedia resource.

      attribute :order, AshHateoas.Type.ResourceLink, public?: true

  Ash relationships are in-process: they name a resource module and resolve
  through a shared data layer. There is no way to declare "this points at a
  resource served by a different application", and the Hydra plug builds every
  link from the *incoming* request's host, so a document can only ever link
  within its own API.

  This type is the escape hatch. The value is an ordinary URL, stored like any
  other string, but the type says it is **followable** — which is the part a
  client cannot otherwise know.

  ## Why the type rather than sniffing the value

  A consumer could look for attribute values that parse as URLs, but that
  guesses: a `homepage` or `source_url` is a URL and is not a resource you can
  dereference as one. Guessing wrong means a client follows a link into
  something that is not a hypermedia resource at all — and for a consumer that
  attaches credentials to outbound requests, guessing is also how you build an
  SSRF vector.

  Declaring the type moves that from inference to statement: the wire format
  says `"type": "link"`, and a client follows only what the server marked.

  ## What a consumer must still do

  Marking a value followable does not make it safe to follow. A URL stored in
  application data is application data — a consumer MUST check the host against
  its own allowlist before dereferencing, and MUST NOT attach a credential
  belonging to one host to a request bound for another.
  """

  use Ash.Type.NewType, subtype_of: :string
end
