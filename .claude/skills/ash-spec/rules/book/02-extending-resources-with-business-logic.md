# 2. Extending Resources with Business Logic

##  Chapter 2 Extending Resources with Business Logic

In the first chapter, we learned how to set up Ash within our Phoenix app, created our first resource for Artists within a domain, and built out a full web interface so that we could create, read, update, and delete Artist records. This would be a great starting point for any application, to pick your most core domain model concept and build it out.

Now we can start fleshing out the domain model for Tunez a bit more because one resource does not a full application make. Having multiple resources and connecting them together will allow us to do things like querying and filtering based on related data. So, in the real world, artists release albums, right? Let’s build a second resource representing an Album with a more complex structure, link them together, and learn some other handy features of working with declarative resources.

## Resources and Relationships

Similar to how we generated our Artist resource, we can start by using Ash’s generators to create our basic Album resource. It’s music-related, so it should also be part of the Tunez.Music domain:

```elixir
 $ mix  ash.gen.resource  Tunez.Music.Album  --extend  postgres
```

This will generate the resource file in lib/tunez/music/album.ex, as well as add the new resource to the list of resources in the Tunez.Music domain module.

The next step, just like when we built our first resource, is to consider what kinds of attributes our new resource needs. What information should we record about an Album? Right now, we probably care about these things:

- The artist who released the album
- The album name
- The year the album was released
- An image of the album cover (which will make Tunez look really nice!)

Ash has a lot of inbuilt data types that can let you model just about anything. If we were building a resource for a product in a clothing store, we might want attributes for things like the item size, color, brand name, and price. A listing on a real estate app might want to store the property address, the number of bedrooms and bathrooms, and the property size.

 

|  |  |
|----|----|
|  | If none of the inbuilt data types cover what you need, you can also create custom or composite data types. These can neatly wrap logic around discrete units of data, such as phone numbers, URLs, or latitude/longitude coordinates. |

 

In the attributes block of the Album resource, we can start adding our new attributes:

[02/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 attributes do
 uuid_primary_key :id

 attribute :name, :string do
 allow_nil? false
 end

 attribute :year_released, :integer do
 allow_nil? false
 end

 attribute :cover_image_url, :string

 create_timestamp :inserted_at
 update_timestamp :updated_at
 end
```

The name and year_released attributes will be required, but the cover_image_url will be optional. We might not have high-quality photos on hand for every album, but we can add them later when we get them.

We haven’t added any field to represent the artist, though, and that’s because it’s not going to be just a normal attribute. It’s going to be a relationship.

### Defining Relationships

Relationships, also known as associations, are how we describe connections between resources in Ash. There are a couple of different relationship types we can choose from, based on the number of resources involved on each side:

- has_many relationships relate one resource to many other resources. These are common, for example, a User can have many Posts or a Book can have many Chapters. These don’t store any data on the one side of the relationship, but each of the items on the many side will have a reference back to the one.

- belongs_to relationships relate one resource to one parent/containing resource. They are usually the inverse of a has_many; in the previous examples, the resource on the many side would typically belong to the one resource. A Chapter belongs to a Book, and a Post belongs to a User. The resource belonging to another will have a reference to the related resource, for example, a Chapter will have a book_id attribute, referencing the id field of the Book resource.

- has_one relationships are less common but are similar to belongs_to relationships. They relate one resource to one other resource but differ in which end of the relationship holds the reference to the related record. For a has_one relationship, the related resource will have the reference. A common example of a has_one relationship is Users and Profiles—a User could have one Profile, but the Profile resource is what holds a user_id attribute.

- many_to_many relationships, as the name suggests, relate many resources to many other resources. These are where you have two pools of different objects, and can link any two resources between the pools. Tags are a common example—a Post can have many Tags applied to it, and a Tag can also apply to many different Posts.

In our case, we’ll be using the belongs_to and has_many relationships, for example, an Artist has_many albums, and an Album belongs_to an artist.

In code, we define these in a separate top-level relationships block in each resource. In the Artist resource, in lib/tunez/music/artist.ex, we can add a relationship with Albums:

[02/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 relationships do
 has_many :albums, Tunez.Music.Album
 end
```

And in the Album resource in lib/tunez/music/album.ex, we add a relationship back to the Artist resource:

[02/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 relationships do
 belongs_to :artist, Tunez.Music.Artist do
 allow_nil? false
 end
 end
```

Now that our resource is set up, generate a database migration for it, using the ash.codegen mix task.

```elixir
 $ mix  ash.codegen  create_albums
```

This will generate a new Ecto migration in priv/repo/migrations/[timestamp]_create_albums.exs to create the albums table in the database, including a foreign key representing the relationship. This will link an artist_id field on the albums table to the id field on the artists table. A snapshot JSON file will also be created, representing the current state of the Album resource.

The migration doesn’t contain a function call to create a database index for the foreign key, though, and PostgreSQL doesn’t create indexes for foreign keys by default. To tell Ash to create an index for the foreign key, you can customize the reference of the relationship as part of the postgres block in the resource.

[02/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 postgres do
 # ...
 references do
 reference :artist, index?: true
 end
 end
```

This changes the database, so you’ll need to codegen another migration for it (or delete the CreateAlbums migration and snapshot that we just generated and generate them again).

If you’re happy with the migrations, run them:

```elixir
 $ mix  ash.migrate
```

And now we can start adding functionality. A lot of this will seem pretty familiar from building out the Artist interface, so we’ll cover it quickly. But there are a few new interesting parts due to the added relationship, so let’s dig right in.

### Album Actions

If we look at an Artist’s profile page in the app, we can see a list of their albums, so we’re going to need some kind of read action on the Album resource to read the data to display. There’s also a button to add a new album, at the top of the album list, so we’ll need a create action; and each album has Edit and Delete buttons next to the title, so we’ll write some update and destroy actions as well.

We can add those to the Album resource pretty quickly:

[02/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 actions do
 defaults [:read, :destroy]

 create :create do
 accept [:name, :year_released, :cover_image_url, :artist_id]
 end

 update :update do
 accept [:name, :year_released, :cover_image_url]
 end
 end
```

We don’t have any customizations to make to the default implementation of read or destroy, so we can define those as default actions. You might be thinking, but won’t we need to customize the read action to only show albums for a specific artist? We actually don’t! When we load an artist’s albums on their profile page, which we’ll see how to do shortly, we won’t be calling this action directly; we’ll be asking Ash to load the albums through the albums relationship on the Artist resource, which will automatically apply the correct filter.

We do have tweaks for the create and update actions—specifically, for the accept list of attributes that can be set when calling those actions. When creating a record, it makes sense to set the artist_id for an album; otherwise, it won’t be set at all! But when updating an album, does it need to be changeable? Can we see ourselves creating an album via the wrong artist profile and then needing to change it later? It seems unlikely, so we don’t need to accept the artist_id attribute in the update action.

We’ll also add code interface definitions for our actions to make them easier to use in an iex console and easier to read in our liveviews. Again, these go in our Tunez.Music domain module with the resource definition.

[02/lib/tunez/music.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic.ex)

```elixir
 resources do
 # ...
 resource Tunez.Music.Album do
 define :create_album, action: :create
 define :get_album_by_id, action: :read, get_by: :id
 define :update_album, action: :update
 define :destroy_album, action: :destroy
 end
 end
```

As in the case of artists, we’ve provided some sample album content for you to play around with. To import it, you can run the following on the command line:

```elixir
 $ mix  run  priv/repo/seeds/02-albums.exs
```

This will populate a handful of albums for each of the sample artists we seeded in the [code](#f_0019.xhtml_ch01_artist_seeds)[](#f_0019.xhtml_ch01_artist_seeds).

You can also uncomment the second seed file in the mix seed alias, in the aliases function in mix.exs:

[02/mix.exs](http://media.pragprog.com/titles/ldash/code/02%2Fmix.exs)

```elixir
 defp aliases do
 [
 setup: ["deps.get", "ash.setup", "assets.setup", "assets.build", ...],
 "ecto.setup": ["ecto.create", "ecto.migrate"],
 seed: [
 "run priv/repo/seeds/01-artists.exs",
 "run priv/repo/seeds/02-albums.exs",
 # "run priv/repo/seeds/08-tracks.exs"
 ],
 # ...
```

Now you can run mix seed to reset the seeded artist and album data in your database. Currently, the seed scripts aren’t idempotent (you can’t rerun them repeatedly) due to how we’ve set up our Album -> Artist relationship, but we’ll address that in [*Deleting All of the Things*](#f_0025.xhtml_ch02.deleting). And now we can start connecting the pieces to view and manage the album data in our liveviews.

### Creating and Updating Albums

Our Artist page has a button on it to add a new album for that artist. This links to the TunezWeb.Albums.FormLive liveview module and renders a form template similar to the artist form, with text fields for entering data. We can use AshPhoenix to make this template functional, the same way we did for artists.

First, we construct a new form for the Album.create action, in mount/3:

[02/lib/tunez_web/live/albums/form_live.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez_web%2Flive%2Falbums%2Fform_live.ex)

```elixir
 def mount(_params, _session, socket) do
 form = Tunez.Music.form_to_create_album()

 socket =
 socket
 |> assign(:form, to_form(form))
 ...
```

We validate the form data and update the form in the liveview’s state, in the “validate” handle_event/3 event handler:

[02/lib/tunez_web/live/albums/form_live.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez_web%2Flive%2Falbums%2Fform_live.ex)

```elixir
 def handle_event("validate", %{"form" => form_data}, socket) do
 socket =
 update(socket, :form, fn form ->
 AshPhoenix.Form.validate(form, form_data)
 end)

 {:noreply, socket}
 end
```

We submit the form in the “save” handle_event/3 event handler and process the return value:

[02/lib/tunez_web/live/albums/form_live.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez_web%2Flive%2Falbums%2Fform_live.ex)

```elixir
 def handle_event("save", %{"form" => form_data}, socket) do
 case AshPhoenix.Form.submit(socket.assigns.form, params: form_data) do
 {:ok, album} ->
 socket =
 socket
 |> put_flash(:info, "Album saved successfully")
 |> push_navigate(to: ~p"/artists/#{album.artist_id}")

 {:noreply, socket}

 {:error, form} ->
 socket =
 socket
 |> put_flash(:error, "Could not save album data")
 |> assign(:form, form)

 {:noreply, socket}
 end
 end
```

And finally, we add another function head for mount/3, so we can differentiate between viewing the form to add an album and viewing the form to edit an album, based on whether or not album_id is present in the params:

[02/lib/tunez_web/live/albums/form_live.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez_web%2Flive%2Falbums%2Fform_live.ex)

```elixir
 def mount(%{"id" => album_id}, _session, socket) do
 album = Tunez.Music.get_album_by_id!(album_id)
 form = Tunez.Music.form_to_update_album(album)

 socket =
 socket
 |> assign(:form, to_form(form))
 |> assign(:page_title, "Update Album")

 {:ok, socket}
 end

 def mount(_params, _session, socket) do
 form = Tunez.Music.form_to_create_album()
 ...
```

If this was a bit too fast, you can find a much more thorough rundown on how this code works in [*Creating Artists with AshPhoenix.Form*](#f_0020.xhtml_ch01.ashphoenix_form).

#### Using Artist Data on the Album Form

There’s one thing missing from this form that will stop it from working as we expect to manage Album records: there’s no mention at all of the Artist that the album should belong to. There’s a field to enter an artist on the form, but it’s disabled.

We do know which artist the album should belong to, though. We clicked the button to add an album on a specific artist page, and the album should be for that artist! In the server logs in your terminal, you’ll see that we do have the artist ID as part of the params to the FormLive liveview:

```elixir
 [debug] MOUNT TunezWeb.Albums.FormLive
 Parameters: %{"artist_id" => "an-artist-id"}
```

We can use this ID to load the artist record, show the artist details on the form, and relate the artist to the album in the form.

In the second mount/3 function head, for the create action, we can load the artist record using Tunez.Music.get_artist_by_id, as we do on the artist profile page. The artist can be assigned to the socket alongside the form.

[02/lib/tunez_web/live/albums/form_live.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez_web%2Flive%2Falbums%2Fform_live.ex)

```elixir
 def mount(%{"artist_id" => artist_id}, _session, socket) do
 artist = Tunez.Music.get_artist_by_id!(artist_id)
 form = Tunez.Music.form_to_create_album()

 socket =
 socket
 |> assign(:form, to_form(form))
 |> assign(:artist, artist)
 ...
```

In the first mount/3 function head, for the update action, we have the artist ID stored on the album record we load. We can use it to load the Artist record in a similar way:

[02/lib/tunez_web/live/albums/form_live.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez_web%2Flive%2Falbums%2Fform_live.ex)

```elixir
 def mount(%{"id" => album_id}, _session, socket) do
 album = Tunez.Music.get_album_by_id!(album_id)
 artist = Tunez.Music.get_artist_by_id!(album.artist_id)
 form = Tunez.Music.form_to_update_album(album)

 socket =
 socket
 |> assign(:form, to_form(form))
 |> assign(:artist, artist)
 ...
```

Now that we have an artist record assigned in the liveview, we can show the artist name in the disabled field, in render/3:

[02/lib/tunez_web/live/albums/form_live.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez_web%2Flive%2Falbums%2Fform_live.ex)

```elixir
 <.input name="artist_id" label="Artist" value={@artist.name} disabled />
```

This doesn’t actually add the artist info to the form params, so we’ll still get an error when submitting the form for a new album even if all of the data is valid. There are two ways we can address this. In one approach, we could manually update the form data before submitting the form, adding the artist_id from the artist record already in the socket.

```elixir
 def handle_event("save", %{"form" => form_data}, socket) do
 form_data = Map.put(form_data, "artist_id", socket.assigns.artist.id)
 ...
```

This is easy to reason about but feels messy. This code also runs when submitting the form for both creating and updating an album, and the update action on our Album resource specifically does not accept an artist_id attribute. Submitting the form won’t raise an error—AshPhoenix throws away any data that won’t be accepted by the underlying action—but it’s a sign that we’re probably doing things wrong.

Instead, we’ll look at building the form for creating an album slightly differently to pre-populate the artist ID. The form_to_create_album function is auto-generated from our create_album code interface, defined in the Tunez.Music domain module:

[02/lib/tunez/music.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic.ex)

```elixir
 resource Tunez.Music.Album do
 define :create_album, action: :create
 # ...
 end
```

Any changes we make to the code interface won’t only affect the generated form_to_ function but also update the create_album function. We’re not currently using that function, but we might want to later! Instead, we can customize only the form_to_create_album action by using the forms DSL from the AshPhoenix domain extension.

By specifying a form with the same name as the code interface, we can then add a list of args that are required when building the form that will be submitted with the rest of the form data.

[02/lib/tunez/music.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic.ex)

```elixir
 defmodule Tunez.Music do
 use Ash.Domain, otp_app: :tunez, extensions: [AshPhoenix]

 forms do
 form :create_album, args: [:artist_id]
 end

 # ...
```

This changes the signature of the generated function, which you can see if you recompile your app in iex:

```elixir
 iex(1)> h Tunez.Music.form_to_create_album

 def form_to_create_album(artist_id, form_opts \ [])

 Creates a form for the create action on Tunez.Music.Album.
```

We can now update how we call form_to_create_album, specifying the artist ID as the first argument, and it will be used when submitting the form.

[02/lib/tunez_web/live/albums/form_live.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez_web%2Flive%2Falbums%2Fform_live.ex)

```elixir
 def mount(%{"artist_id" => artist_id}, _session, socket) do
 artist = Tunez.Music.get_artist_by_id!(artist_id)
 form = Tunez.Music.form_to_create_album(artist.id)
 ...
```

This is a common pattern to use when you want to provide data to an action via a form, but it shouldn’t be editable by the user. Even if users are being sneaky in their browser dev tools and adding form fields with data they shouldn’t be editing, they get overwritten with the correct value we specified earlier, so nothing nefarious can happen. And now our TunezWeb.Album.FormLive form should work properly for creating album data.

## Loading Related Resource Data

On the profile page for an Artist in TunezWeb.Artists.ShowLive, we want to show a list of albums released by that artist. It’s currently populated with placeholder data:

And this data is defined in the handle_params/3 callback:

[02/lib/tunez_web/live/artists/show_live.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez_web%2Flive%2Fartists%2Fshow_live.ex)

```elixir
 def handle_params(%{"id" => artist_id}, _url, socket) do
 artist = Tunez.Music.get_artist_by_id!(artist_id)

 albums = [
 %{
 id: "test-album-1",
 name: "Test Album",
 year_released: 2023,
 cover_image_url: nil
 }
 ]

 socket =
 socket
 |> assign(:artist, artist)
 |> assign(:albums, albums)
 |> assign(:page_title, artist.name)

 {:noreply, socket}
 end
```

The Edit button for the album will still take you to the form we just built, but it will result in an error because the album ID doesn’t match a valid album in the database!

Because we’ve defined albums as a relationship in our Artist resource, we can automatically load the data in that relationship, similar to an Ecto preload. All actions support an extra argument of options, and one of the options for read actions is load—a list of relationships we want to load alongside the requested data. This will use the primary read action that we defined on the Album resource but will include the correct filter to only load albums for the artist specified.

To do this, update the call to get_artist_by_id! to include loading the albums relationship and remove the hardcoded albums:

[02/lib/tunez_web/live/artists/show_live.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez_web%2Flive%2Fartists%2Fshow_live.ex)

```elixir
 def handle_params(%{"id" => artist_id}, _url, socket) do
 artist = Tunez.Music.get_artist_by_id!(artist_id, load: [:albums])

 socket =
 socket
 |> assign(:artist, artist)
 |> assign(:page_title, artist.name)

 {:noreply, socket}
 end
```

We do also need to update a little bit of the template, as it referred to the @albums assign (which is now deleted). In the render/1 function, we currently iterate over @albums and render album details for each. This needs to be updated to render albums from the @artist instead:

[02/lib/tunez_web/live/artists/show_live.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez_web%2Flive%2Fartists%2Fshow_live.ex)

```elixir
 <li :for={album <- @artist.albums}>
 <.album_details album={album} />
 </li>
```

Now, when we view the profile page for one of our sample artists, we should be able to see their actual albums, complete with album covers. Neat!

We can use load to simplify how we loaded the artist for the album on the Album edit form, as well. Instead of making a second request to load the artist after loading the album, they can be combined into one call:

[02/lib/tunez_web/live/albums/form_live.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez_web%2Flive%2Falbums%2Fform_live.ex)

```elixir
 def mount(%{"id" => album_id}, _session, socket) do
 album = Tunez.Music.get_album_by_id!(album_id, load: [:artist])
 form = Tunez.Music.form_to_update_album(album)

 socket =
 socket
 |> assign(:form, to_form(form))
 |> assign(:artist, album.artist)
 ...
```

The album data on the artist profile looks a little bit funny, though—the albums aren’t in any kind of order on the page. We should probably show them in chronological order, with the most recent album release listed first. We can do this by defining a sort for the album relationship, using the sort option on the :albums relationship in Tunez.Music.Artist.

[02/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 relationships do
 has_many :albums, Tunez.Music.Album do
 sort year_released: :desc
 end
 end
```

This takes a list of fields to sort by, and it will sort in ascending order by default. To flip the order, you can use a keyword list instead, with the field names as keys and either :asc or :desc as the value for each key, just like Ecto.

Now, if we reload an artist’s profile, we should see the albums being displayed in chronological order, with the most recent first. That’s much more informative!

## Structured Data with Validations and Identities

Tunez can now accept form data that should be more structured, instead of just text. We’re also looking at data in a smaller scope. Instead of “any artist in the world that ever was”, which is a massive data set, we’re looking at albums for any individual artist, which is a much smaller and well-defined list.

Let’s set some stricter rules for this data, for better data integrity.

### Consistent Data with Validations

With Albums, we want users to enter a valid year for an album’s year_released attribute, instead of any old integer, and a valid-looking image URL for the cover_image_url attribute. We can enforce these rules with validations.

Any defined validations are checked when calling an action, before the core functionality (for example, saving or deleting) is run, and if any of the validations fail, the action will abort and return an error. We’ve seen implicit cases of this already when we declared that some attributes were allow_nil? false. Ash sets the database field for these attributes to be non-nullable, but also validates that the value is present before it even gets to the database.

Validations can be added to resources either for an individual action or globally for the entire resource. In our case, we want to ensure that the data is valid at all times, so we’ll add global validations by adding a new top-level validations block in the Album resource:

[02/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 defmodule Tunez.Music.Album do
 # ...

 validations do
 # Validations will go in here
 end
 end
```

We’ll add two validations to this block, one for year_released and one for cover_image_url. Ash provides a lot of built-in validations, and two of them are relevant here: numericality and match.

For year_released, we want to validate that the user enters a number between, say, 1950 (an arbitrarily chosen year) and the next year (to allow for albums that have been announced but not released), but we should only validate the field if the user has actually entered data. This is written like so:

[02/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 validations do
 validate numericality(:year_released,
 greater_than: 1950,
 less_than_or_equal_to: &__MODULE__.next_year/0
 ),
 where: [present(:year_released)],
 message: "must be between 1950 and next year"
 end
```

Ash will accept any zero-arity (no-argument) function reference here. The next_year function doesn’t exist, so we’ll add it to the very end of the Album module:

[02/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 def next_year, do: Date.utc_today().year + 1
```

For cover_image_url, we’ll add a regular expression to make sure the user enters what looks like an image URL—either a fully qualified URL or a path to one of the sample album covers in the priv/static/images folder. This isn’t comprehensive by any means. In a real-world app, we’d likely be implementing a file uploader, verifying that the uploaded files were valid images, but for our use case, it’ll address users making copy-paste mistakes or entering nonsense.

[02/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 validations do
 # ...
 validate match(:cover_image_url,
 ~r"^(https://|/images/).+(\png|\jpg)$"
 ),
 where: [changing(:cover_image_url)],
 message: "must start with https:// or /images/"
 end
```

For a little optimization, we’ll also add a check that only runs the validation if the value is changing, using the changing/1 function in the where condition of the validation.

> If you want to run a validation only for one specific action, you can put the validation directly in the action instead of in the global validations block.
> To run validations for all actions of a specific type, for example, all create actions, you can put them in the global validations block and use the on option[30] to specify the types of actions it should apply to.

We don’t need to do anything to integrate these validations into Album actions or into the forms in our views. Because they’re global validations, they apply to every create and update action, and because the forms in our liveviews are built for actions, they’ll automatically be included. Entering invalid data in the album form will now show validation errors to our users, letting them know what to fix:

### Unique Data with Identities

There’s one last feature we can add for a better user experience on this form. Some artists have a lot of albums, and it would be good to ensure that duplicate albums don’t accidentally get entered. Maintaining data integrity, especially with user-editable data, is important—sites like Wikipedia don’t allow multiple pages with the exact same name, for example; they have to be disambiguated in some way.

Tunez will consider an album to be a duplicate if it has the same name as another album by the same artist, that is, the combination of name and artist_id should be unique for every album in the database. (We’ll assume that separate versions of albums with the same name get suffixes attached, like “Remastered” or “Live” or “Taylor’s Version”.) To ensure this uniqueness, we can use an identity on our resource.

Ash defines an identity as any attribute, or combination of attributes, that can uniquely identify a record. A primary key is a natural and automatically generated identity, but our data may lend itself to other identities as well.

To add the new identity to our resource, add a new top-level identities block to the Album resource. An identity has a name and a list of attributes that make up that identity. We can also specify a message to display on identity violations:

[02/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 identities do
 identity :unique_album_names_per_artist, [:name, :artist_id],
 message: "already exists for this artist"
 end
```

The way identities are handled depends on the data layer being used. Because we’re using AshPostgres, the identity will be handled at the database level as a unique index on the two database fields, albums.name and albums.artist_id.

To create the index in the database, we can generate migrations after adding the identity to the Album resource:

```elixir
 $ mix  ash.codegen  add_unique_album_names_per_artist
```

This is the first time we’ve modified a resource and then generated migrations, so it’s worth taking a bit of a closer look.

Like the previous times we’ve generated migrations, AshPostgres has generated a snapshot file representing the current state of the Album resource. It also created a new migration, which has all of the differences between the last snapshot from when we created the resource and the brand-new snapshot:

[02/priv/repo/migrations/[timestamp]_add_unique_album_names_per_artist.exs](http://media.pragprog.com/titles/ldash/code/02%2Fpriv%2Frepo%2Fmigrations%2F%5Btimestamp%5D_add_unique_album_names_per_artist.exs)

```elixir
 def up do
 create unique_index(:albums, [:name, :artist_id],
 name: "albums_unique_album_names_per_artist_index"
 )
 end

 def down do
 drop_if_exists unique_index(:albums, [:name, :artist_id],
 name: "albums_unique_album_names_per_artist_index"
 )
 end
```

Ash correctly worked out that the only difference that required database changes was the new identity, so it created the correct migration to add and remove the unique index we need. Awesome!

Run the migration generated:

```elixir
 $ mix  ash.migrate
```

And now we can test out the changes on the album form. Create an album with a specific name, and then try to create another one for the same artist with the same name. You should get a validation error on the name field, with the message we specified for the identity.

## Deleting All of the Things

We’ll round out the CRUD interface for Albums with the destroy action. We might not need to invoke it too much while using Tunez, but keeping our data clean and accurate is always an important priority.

While building the Album resource, we’ve also accidentally introduced a bug around Artist deletion, so we should address that as well.

### Deleting Album Data

Deleting albums is done from the artist’s profile page, TunezWeb.Artists.ShowLive, via a button next to the name of the album.

Clicking the icon will send the “destroy-album” event to the liveview. In the event handler, we’ll fetch the album record from the list of albums we already have in memory and then delete it. It’s a little bit verbose, but it saves another round trip to the database to look up the album record. Like with artists, we also need to handle both the success and error cases:

[02/lib/tunez_web/live/artists/show_live.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez_web%2Flive%2Fartists%2Fshow_live.ex)

```elixir
 def handle_event("destroy-album", %{"id" => album_id}, socket) do
 case Tunez.Music.destroy_album(album_id) do
 :ok ->
 socket =
 socket
 |> update(:artist, fn artist ->
 Map.update!(artist, :albums, fn albums ->
 Enum.reject(albums, &(&1.id == album_id))
 end)
 end)
 |> put_flash(:info, "Album deleted successfully")

 {:noreply, socket}

 {:error, error} ->
 Logger.info("Could not delete album '#{album_id}': #{inspect(error)}")

 socket =
 socket
 |> put_flash(:error, "Could not delete album")

 {:noreply, socket}
 end
 end
```

We’ve almost finished the initial implementation for albums! But there’s a bug in our Album implementation. If you try to delete an artist that has albums, you’ll see what we mean. This also affects our seed scripts: we can’t reseed the database because we can’t delete the seeded artists that have albums. We’ll fix that now!

### Cascading Deletes with AshPostgres

When we defined our Album resource, we added a belongs_to relationship to relate it to Artists:

[02/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 relationships do
 belongs_to :artist, Tunez.Music.Artist do
 allow_nil? false
 end
 end
```

When we generated the migration for this resource in [*Defining Relationships*](#f_0022.xhtml_ch02.defining_relationships), it created a foreign key in the database, linking the artist_id field on the albums table to the id field on the artists table:

[02/priv/repo/migrations/[timestamp]_create_albums.exs](http://media.pragprog.com/titles/ldash/code/02%2Fpriv%2Frepo%2Fmigrations%2F%5Btimestamp%5D_create_albums.exs)

```elixir
 def up do
 create table(:albums, primary_key: false) do
 # ...
 add :artist_id,
 references(:artists,
 column: :id,
 name: "albums_artist_id_fkey",
 type: :uuid,
 prefix: "public"
 )
 end
 end
```

But what we didn’t define was what should happen with this foreign key value when artists are deleted, for example, if there are three albums with artist_id = "abc123" and artist abc123 is deleted, what happens to those albums?

The default behavior, as we have seen, is to prevent the deletion from happening. This is verified by looking at the server logs when you try to delete one of the artists that this affects:

```elixir
 [info] Could not delete artist 'uuid': %Ash.Error.Invalid{bread_crumbs:
 ["Error returned from: Tunez.Music.Artist.destroy"], changeset: "#Changeset<>",
 errors: [%Ash.Error.Changes.InvalidAttribute{field: :id, message: "would leave
 records behind", private_vars: [constraint: "albums_artist_id_fkey", ...], ...
```

Because an album doesn’t make sense without an artist (we can say the albums are dependent on the artist), we should delete all of an artist’s albums when we delete an artist. There are two ways we can go about this, each with its own pros and cons:

- We can delete the dependent records in code—in the destroy action for an artist, we can call the destroy action on all of the artist’s albums as well. It’s very explicit what’s going on, but it can be really slow (relatively speaking). But sometimes it’s a necessary evil if you need to run business logic in each of the dependent destroy actions.

- Or we can delete the dependent records in the database, by specifying the ON DELETE behavior of the foreign key that raised the error. This is superfast, but it can be a little unexpected if you don’t know it’s happening. You don’t get the chance to run any business logic in your app’s code—but if you don’t need to, this is easily the preferred option.

Which one you use depends on the requirements of the app you’re building, and as the requirements of your app change, you might need to change the behavior. For now, we’ll go with the quick ON DELETE option, which is to delete the dependent records in the database (the second option).

AshPostgres lets us specify the ON DELETE behavior for a foreign key by configuring the custom reference in the postgres block of our resource. This goes on the resource that has the foreign key, which is, in this case, the Tunez.Music.Album resource:

[02/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 postgres do
 # ...

 references do
 reference :artist, index?: true, on_delete: :delete
 end
 end
```

This will make a structural change to our database, so we need to generate migrations and run them:

```elixir
 $ mix  ash.codegen  configure_reference_for_album_artist_id
 $ mix  ash.migrate
```

This will generate a migration that modifies the existing foreign key, setting on_delete: :delete_all. Running the migration sets the ON DELETE clause on the artist_id field:

```elixir
 tunez_dev=# \d albums
 definition of the columns and indexes of the table
 Foreign-key constraints:
 "albums_artist_id_fkey" FOREIGN KEY (artist_id) REFERENCES
 artists(id) ON DELETE CASCADE
```

And now we can delete artists again, even if they have albums; no error occurs, and no data is left behind.

Our albums are shaping up! They’re not complete—we’ll look at adding track listings in Chapter 8, [*Having Fun With Nested Forms*](#f_0055.xhtml_ch08.start)—but for now they’re pretty good, so we can step back and revisit our artist form.

What if we needed to make changes to the data we call an action with, before saving it into the data layer? The UI in our form might not exactly match the attributes we want to store, or we might need to format the data or conditionally set attributes based on other attributes. We can look at making these kinds of modifications with changes.

## Changing Data Within Actions

We’ve been using some built-in changes already in Tunez, without even realizing it, for inserted_at and updated_at timestamps on our resources. We didn’t write any code for them, but Ash takes care of setting them to the current time. Both timestamps are set when calling any create action, and updated_at is set when calling any update action.

Like validations, changes can be defined at both the top level of a resource and at an individual action level. The implementation for timestamps could look like this:

```elixir
 changes do
 change set_attribute(:inserted_at, &DateTime.utc_now/0), on: [:create]
 change set_attribute(:updated_at, &DateTime.utc_now/0)
 end
```

|  |  |
|----|----|
|  | By default, global changes will run on any create or update action, which is why we wouldn’t have to specify an action type for :updated_at here. They can be run on destroy actions, but only when opting-in by specifying on: [:destroy] on the change. |

There are quite a few built-in changes you can use in your resources, or you can add your own, either inline or with a custom module. We’ll go through what it looks like to build one inline and then how it can be extracted to a module for reuse.

### Defining an Inline Change

Over time, artists go through phases, and sometimes change their names after rebranding, lawsuits, or lineup changes. Let’s track updates to an artist’s name over time by keeping a list of all of the previous values that the name field has had, with a new change function.

This list will be stored in a new attribute called previous_names, so we’ll list it as an attribute in the Artist resource. It’ll be a list, or array, of the previous names and default to an empty list for new artists:

[02/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 attributes do
 # ...
 attribute :previous_names, {:array, :string} do
 default []
 end
 # ...
 end
```

Generate a migration to add the new attribute to the database, and run it:

```elixir
 $ mix  ash.codegen  add_previous_names_to_artists
 $ mix  ash.migrate
```

We only need to run this change when the Artist form is submitted to update an Artist, so we’ll add the change within the update action. (If your Artist resource is using defaults to define its actions, you’ll need to remove :update from that list and define the action separately.) The change macro can take a few different forms of arguments, the simplest being a two-argument anonymous function that takes and returns an Ash.Changeset:

[02/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 actions do
 # ...
 update :update do
 accept [:name, :biography]

 change fn changeset, _context ->
 changeset
 end
 end
 end
```

Inside this anonymous function, we can make any changes to the changeset we want, including deleting data, changing relationships, adding errors, and more. If we set any errors in the changeset, they will stop the rest of the action from taking place and return the changeset to the user.

To implement the logic we want, we will use some of the functions from Ash.Changeset to read both the old and new name values from the changeset and update the previous_names attribute where applicable:

[02/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 change fn changeset, _context ->
 new_name = Ash.Changeset.get_attribute(changeset, :name)
 previous_name = Ash.Changeset.get_data(changeset, :name)
 previous_names = Ash.Changeset.get_data(changeset, :previous_names)

 names =
 [previous_name | previous_names]
 |> Enum.uniq()
 |> Enum.reject(fn name -> name == new_name end)

 Ash.Changeset.change_attribute(changeset, :previous_names, names)
 end
```

Like calling actions, the change macro also accepts an optional second argument of options for the change. Because we only need to update previous_names if the name field is actually being modified, we’ll add a changing/1 validation for the change function with a where check:

[02/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 change fn changeset, _context ->
 # ...
 end,
 where: [changing(:name)]
```

If the validation fails, the change function is skipped and the previous names won’t be updated. That’ll save a few CPU cycles!

There’s one other small adjustment we need to make for this change function to work. By default, Ash will try to do as much work as possible in the data layer instead of in memory, via a concept called atomics. Because we have written our change functionality as imperative code, instead of in a data-layer-compatible way, we’ll need to disable atomics for this update action with the require_atomic? option.

[02/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 update :update do
 require_atomic? false

 # ...
 end
```

We’ll dig into atomics and how to write changes atomically later in [Chapter 10,](#f_0070.xhtml_ch10.atomics).

### Defining a Change Module

The inline version of the previous_names change works, but it’s a bit long and imperative, smack-dab in the middle of our declarative resource. Imagine if we had a complex resource with a lot of attributes and changes; it’d be hard to navigate and handle! And what if we wanted to apply this same record-previous-values logic to something else, like users who can change their usernames? Let’s extract the logic out into a change module.

A change module is a standalone module that uses Ash.Resource.Change. Its main access point is the change/3 function, which has a similar function signature as the anonymous change function we defined earlier, but with an added second opts argument. We can move the content of the anonymous change function and insert it directly into a new change/3 function in a new change module:

[02/lib/tunez/music/changes/update_previous_names.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic%2Fchanges%2Fupdate_previous_names.ex)

```elixir
 defmodule Tunez.Music.Changes.UpdatePreviousNames do
 use Ash.Resource.Change

 @impl true
 def change(changeset, _opts, _context) do
 # The code previously in the body of the anonymous change function
 end
 end
```

And we can update the change call in the update action to point to the new module instead:

[02/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 update :update do
 require_atomic? false
 accept [:name, :biography]

 change Tunez.Music.Changes.UpdatePreviousNames, where: [changing(:name)]
 end
```

A shorter and easier-to-read resource isn’t the only reason to extract changes into their own modules. Change modules can define their own options and interface and validate their usage at compile time. To reuse the current UpdatePreviousNames module, we might want to make the field names configurable instead of hardcoded to name and previous_names and have a flag for allowing duplicate values or not. Change modules also have a performance benefit during development, by breaking compile-time dependencies between the resources and the code in the change functions. This makes it faster to recompile your app after modification!

Details on configuring and validating the interface for change modules using the Spark library are a bit too much to go into here, but built-in changes like Ash.Resource.Change.SetAttribute are a great way to see how they can be implemented.

### Changes Run More Often than You Might Think!

Changes aren’t only run when actions are called. When forms are tied to actions, like our update action is tied to the Artist edit form in the web interface, the pre-persistence steps, like validations and changes, are run multiple times:

- When building the initial form

- During any authorization checks (covered in [*Introducing Policies*](#f_0043.xhtml_ch06.policies_intro))

- On every validation of the form

- When actually submitting the form or calling the action

Because of this, changes that are time-consuming or have side effects, such as calling external APIs, should be wrapped in hooks such as Ash.Changeset.before_action or Ash.Changeset.after_action—these will only be called immediately before or after the action is run.

If we wanted to do this for the UpdatePreviousNames change module, it would look like this:

```elixir
 def change(changeset, _opts, _context) do
 Ash.Changeset.before_action(changeset, fn changeset ->
 # The code previously in the body of the function
 # It can still use any `opts` or `context` passed in to the top-level
 # change function, as well.
 end)
 end
```

The anonymous function set as the before_action would only run once—when the form is submitted—but it would still have the power to set errors on the changeset to prevent the changes from being saved, if necessary.

> **Setting Attributes in a before_action Hook Will Bypass Validations!**
> Setting Attributes in a before_action Hook Will Bypass Validations!
> A function defined as a before_action will only run right before save—after validations of the action have been run—so it’s possible to get your data into an invalid state in the database. If you validate that an album’s year_released must be in the past, but then call Ash.Changeset.change_attribute(changeset, :year_released, 2050) in your before_action function, that year 2050 will happily be saved into the database. Ash will show a warning at runtime if you do this, which is helpful.
> If you want to force any validation to run after before_action hooks, you can use the before_action?[41] option on the validation. Or, if you simply want to silence the warning because you’re fine with skipping the validation, replace your call to change_attribute with force_change_attribute instead.

### Rendering the Previous Names in the UI

To finish this feature off, we’ll show any previous names that an artist has had on their profile page.

In TunezWeb.Artists.ShowLive, we’ll add the names printed out as part of the <header> block in the render/1 function:

[02/lib/tunez_web/live/artists/show_live.ex](http://media.pragprog.com/titles/ldash/code/02%2Flib%2Ftunez_web%2Flive%2Fartists%2Fshow_live.ex)

```elixir
 <.header>
 <.h1>...</.h1>
 <:subtitle :if={@artist.previous_names != []}>
 formerly known as: {Enum.join(@artist.previous_names, ", ")}
 </:subtitle>
 ...
 </.header>
```

And now our real Artist pages, complete with their real Album listings, are complete! We’ve learned about the tools Ash provides for relating resources together and how we can work with related data for efficient data loading, preparations, and data integrity. These are core building blocks that you can use when building out your own applications and that we’ll be using more of in the future as well.

And we still haven’t needed to write a lot of code—the small snippets we’ve written, like validations and changes, have been very targeted and specific, but have been usable throughout the whole app, from seeding data in the database to rendering errors in the UI.

We’re only scratching the surface, though. In the next chapter, we’ll make the Artist catalog useful, giving users the ability to search, sort, and page through artists, using more of Ash’s built-in functionality. We’ll also see how we can use calculations and aggregates to perform some sophisticated queries, without even breaking a sweat. This is where things will really get interesting!

Footnotes

<https://hexdocs.pm/ash/Ash.Type.html#module-built-in-types>

<https://hexdocs.pm/ash/Ash.Type.html#module-defining-custom-types>

<https://hexdocs.pm/ash_phoenix/dsl-ashphoenix.html#forms>

<https://hexdocs.pm/ash/Ash.html#read/2>

<https://hexdocs.pm/ash/dsl-ash-resource.html#relationships-has_many-sort>

<https://hexdocs.pm/ash/Ash.Resource.Validation.Builtins.html>

<https://hexdocs.pm/ash/Ash.Resource.Validation.Builtins.html#changing/1>

<https://hexdocs.pm/ash/dsl-ash-resource.html#validations-validate-on>

<https://hexdocs.pm/ash/identities.html>

<https://www.postgresql.org/docs/current/sql-createtable.html#SQL-CREATETABLE-PARMS-REFERENCES>

<https://hexdocs.pm/ash_postgres/dsl-ashpostgres-datalayer.html#postgres-references>

<https://hexdocs.pm/ash/Ash.Resource.Change.Builtins.html>

<https://hexdocs.pm/ash/Ash.Changeset.html>

<https://hexdocs.pm/ash/Ash.Resource.Validation.Builtins.html#changing/1>

<https://hexdocs.pm/ash/dsl-ash-resource.html#actions-update-require_atomic?>

<https://hexdocs.pm/ash/Ash.Resource.Change.html>

<https://hexdocs.pm/spark/>

<https://github.com/ash-project/ash/blob/main/lib/ash/resource/change/set_attribute.ex>

<https://hexdocs.pm/ash/dsl-ash-resource.html#validations-validate-before_action?>

Copyright © 2025, The Pragmatic Bookshelf.
