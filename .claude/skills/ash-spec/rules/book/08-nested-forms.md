# 8. Having Fun With Nested Forms

##  Chapter 8 Having Fun With Nested Forms

In the last chapter, we learned all about how we can test the applications we build with Ash. The framework can do a lot for us, but at the end of the day, we own the code we write and the apps we build. With testing tools and know-how in our arsenal, we can be more confident that our apps will continue to behave as we expect.

Now we can get back to the fun stuff: more features! Knowing which artists released which albums is great, but albums don’t exist in a vacuum—they have tracks on them. (You might even be listening to some tracks from your favorite album right now as you read this.) Let’s build a resource to model a Track and then learn how to manage them.

## Setting Up a Track Resource

A track is a music-related resource, so we’ll add it to the Tunez.Music domain using the ash.gen.resource Mix task:

```elixir
 $ mix  ash.gen.resource  Tunez.Music.Track  --extend  postgres
```

This will create a basic empty Track resource in lib/tunez/music/track.ex, as well as list it as a resource in the Tunez.Music domain. What attributes should a track have? We’re probably interested in the following:

- The order of tracks on the album
- The name of each track
- The duration of each track, which we’ll store as a number of seconds
- The album that the tracks belong to

We’ll also add an id and some timestamps for informational reasons.

All of the fields will be required, so we can add them to the Tunez.Music.Track resource and mark them all as allow_nil? false:

[08/lib/tunez/music/track.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Ftrack.ex)

```elixir
 defmodule Tunez.Music.Track do
 # ...

 attributes do
 uuid_primary_key :id

 attribute :order, :integer do
 allow_nil? false
 end

 attribute :name, :string do
 allow_nil? false
 end

 attribute :duration_seconds, :integer do
 allow_nil? false
 constraints min: 1
 end

 create_timestamp :inserted_at
 update_timestamp :updated_at
 end

 relationships do
 belongs_to :album, Tunez.Music.Album do
 allow_nil? false
 end
 end
 end
```

The order field will be an integer, representing its place in the album’s track list. The first track will have order 1, the second track order 2, and so on.

The relationship between tracks and albums can go both ways: an album can have many tracks, and that’s how we’ll work with them most of the time. We’ll add that relationship to the Tunez.Music.Album resource:

[08/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 relationships do
 # ...

 has_many :tracks, Tunez.Music.Track do
 sort order: :asc
 end
 end
```

Like artists and their albums, we’ve specified a sort for the relationship, to always sort tracks on an album by their order attribute using the sort option.

Storing the track duration as a number instead of as a formatted string (for example, “3:32”) might seem strange, but it will allow us to do some neat calculations. We can calculate the duration of a whole album by adding up the track durations, or the average track duration for an artist or album. We don’t have to show the raw number to the user, but having it will be very useful.

Before generating a migration for this new resource, there’s one other thing to add. As we saw in [Chapter 2,](#f_0025.xhtml_ch02.cascade_delete), albums don’t make sense without an associated artist, and neither do tracks without their album. If an album gets deleted, all of its tracks should be deleted too. To do this, we’ll customize the reference to the albums table, in the postgres block of the Tunez.Artist.Track resource. We’ll add an index to the foreign key as well, with index? true.

[08/lib/tunez/music/track.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Ftrack.ex)

```elixir
 postgres do
 # ...

 references do
 reference :album, index?: true, on_delete: :delete
 end
 end
```

Now we can generate a migration to create the database table, and run it:

```elixir
 $ mix  ash.codegen  add_album_tracks
 $ mix  ash.migrate
```

### Reading and Writing Track Data

At the moment, the Tunez.Music.Track resource has no actions at all. So what do we need to add? Our end goal is something like the following:

On a form like this, we can edit all of the tracks of an album at once via the form for creating or updating an album. We won’t be manually calling any actions on the Track resource to do this—Ash will handle it for us, once configured—but the actions still need to exist for Ash to call.

The actions we define will be pretty similar to those we would define for any other resource. The fact that our primary interface for tracks will be via an album doesn’t mean that we won’t also be able to manage tracks on their own, but we won’t build a UI to do so. So we’ll add four actions for our basic CRUD functionality:

[08/lib/tunez/music/track.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Ftrack.ex)

```elixir
 defmodule Tunez.Music.Track do
 # ...

 actions do
 defaults [:read, :destroy]

 create :create do
 primary? true
 accept [:order, :name, :duration_seconds, :album_id]
 end

 update :update do
 primary? true
 accept [:order, :name, :duration_seconds]
 end
 end
 end
```

These actions do need to be explicitly marked with primary? true. When Ash manages the records for us, it needs to know which actions to use. By default, Ash will look for primary actions of the type it needs, for example, a primary action of type create to insert new data.

“Wait! Wait!” we hear you cry. “Didn’t you say that users wouldn’t have to deal with track durations as a number of seconds?” Yes, we did, but we’ll add that feature after we get the basic form UI up and running.

## Managing Relationships for Related Resources

We want to manage tracks via the form for managing an album, so a lot of the code we’ll be writing will be in the TunezWeb.Albums.FormLive liveview module. There’s a track_inputs/1 function component already defined in the liveview, for rendering a table of tracks for the album using Phoenix’s standard inputs_for component. This component will iterate over the data in @form[:tracks] and render a row of input fields for each item in the list.

Add the track_inputs/1 component to the form at the bottom of the main render/1 action, right above the Save button:

[08/lib/tunez_web/live/albums/form_live.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez_web%2Flive%2Falbums%2Fform_live.ex)

```elixir
 <% # ... %>
 <.input field={form[:cover_image_url]} label="Cover Image URL" />

 <.track_inputs form={form} />

 <:actions>
 <% # ... %>
```

In a browser, if you now try to create or edit an album, you’ll see an error telling you that you need to do a bit more configuration first:

```elixir
 tracks at path [] must be configured in the form to be used with
 `inputs_for`. For example:

 There is a relationship called `tracks` on the resource `Tunez.Music.Album`.

 Perhaps you are missing an argument with `change manage_relationship` in
 the action Tunez.Music.Album.update?
```

This is a pretty helpful error message, more so than it might first appear. Ash doesn’t know what to do with our attempt to render inputs for an album’s tracks. They’re not something that the actions for the form, create and update on the Tunez.Music.Album resource, know how to process.

tracks isn’t an attribute of the resource, so we can’t add it to the accept list in the actions. They’re a relationship! To handle tracks in an action, we need to add them as an argument to the action, as the error suggests, and then process them with the built-in manage_relationship change function.

### Managing Relationships with … err … manage_relationship

Using the manage_relationship function is getting its own section because it’s so flexible and powerful. Some even say that mastering it is the ultimate challenge of learning Ash. If you’re looking to deal with relationship data in an action, it’s likely going to be some invocation of manage_relationship, with varying options.

The full set of options is defined in the same-named function on Ash.Changeset. (Be warned, there are a lot of options.) The most common option is the type option: this is a shortcut to different behaviors depending on the data provided. The two most common type values you’ll see for forms in the wild are append_and_remove and direct_control.

#### Using Type append_and_remove

append_and_remove is a way of saying “replace the existing links in this relationship with these new links, adding and removing records where necessary.” This typically works with IDs of existing records, either singular or as a list. A common example of using this is with tagging. If you provide a list of tag IDs as the argument, Ash can handle the rest.

append_and_remove can also be used for managing belongs_to relationships. In Tunez, we’ve allowed the foreign key relationships to be written directly, such as the artist_id attribute when creating an Album resource. The create action on Tunez.Music.Album could also be written as follows:

```elixir
 create :create do
 accept [:name, :year_released, :cover_image_url]

 argument :artist_id, :uuid, allow_nil?: false
 change manage_relationship(:artist_id, :artist, type: :append_and_remove)
 end
```

This code will take the named argument (artist_id) and use it to update the named relationship (artist), using the append_and_remove strategy.

Writing the code using manage_relationship this way does have an extra benefit. Ash will verify that the provided artist_id belongs to a valid artist that the current user is authorized to read, before writing the record into the data layer. This could be pretty important! If you’re building a form for users to join groups, for example, you wouldn’t want a malicious user to edit the form, add the group ID of the secret_admin_group (if they know it), and then join that group!

### Using Type direct_control

direct_control maps more to what we want to do on our Album form: manage relationship data by editing all of the related records. As the name implies, it gives us direct control over the relationship and the full data of each of the records within it.

While append_and_remove focuses on managing the links between existing records, direct_control is about creating and destroying the related records themselves. If we edit an album and remove a track, that track shouldn’t be unlinked from the album; it should be deleted.

Following the instructions from the error message we saw previously, we can add a tracks argument and a manage_relationship change to the create and update actions in the Tunez.Music.Album resource. We’ll be submitting data for multiple tracks in a list, and each list item will be a map of attributes:

[08/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 create :create do
 accept [:name, :year_released, :cover_image_url, :artist_id]
 argument :tracks, {:array, :map}
 change manage_relationship(:tracks, type: :direct_control)
 end

 update :update do
 accept [:name, :year_released, :cover_image_url]
 require_atomic? false
 argument :tracks, {:array, :map}
 change manage_relationship(:tracks, type: :direct_control)
 end
```

Because the name of the argument and the name of the relationship to be managed are the same (tracks), we can omit one when calling manage_relationship. Every little bit helps!

> **Another Mention of Atomics ...**
> Another Mention of Atomics ...
> Like our implementation of previous names for artists, we also need to mark this update action as require_atomic? false. Because Ash needs to figure out which related records to update, which to add, and which to delete when updating a record, calls to manage_relationship in update actions currently can’t be converted into logic to be pushed into the data layer.
> In the future, manage_relationship will be improved to support atomic updates for most of the option arrangements that you can provide, but for now, it requires us to set require_atomic? false.

Trying to create or edit an album should now render the form without error. You should see an empty-tracks table with a button to add a new track. (That won’t work yet because we haven’t implemented it.) Our two actions can now actually fully manage relationship data for tracks! To prove this, in iex, you can build some data in the shape that the album create action expects, with an existing artist_id, and then call the action:

```elixir
 iex(1)> tracks = [
 %{order: 1, name: "Test Track 1", duration_seconds: 120},
 %{order: 3, name: "Test Track 3", duration_seconds: 150},
 %{order: 2, name: "Test Track 2", duration_seconds: 55}
 ]
 [...]
 iex(2)> Tunez.Music.create_album!(%{name: "Test Album", artist_id: uuid,
 year_released: 2025, tracks: tracks}, authorize?: false)
 SQL queries to create the album and each of the tracks
 #Tunez.Music.Album<
 tracks: [
 #Tunez.Music.Track<order: 1, ...>
 #Tunez.Music.Track<order: 2, ...>,
 #Tunez.Music.Track<order: 3, ...>
 ],
 name: "Test Album", ...
 >
```

Note that we don’t have to provide the album_id for any of the maps of track data—we can’t because we’re creating a new album and it doesn’t have an ID yet. Ash takes care of that, creating the album record first, and then adding the new album ID to each of the tracks.

To make these tracks appear in the form when editing the album, we need to load them. Not loading the track data is the same as saying there are no tracks at all. We can update the mount/3 function in TunezWeb.Albums.FormLive when we load the album and artist to also load the tracks for the album.

[08/lib/tunez_web/live/albums/form_live.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez_web%2Flive%2Falbums%2Fform_live.ex)

```elixir
 def mount(%{"id" => album_id}, _session, socket) do
 album =
 Tunez.Music.get_album_by_id!(album_id,
 load: [:artist, :tracks],
 actor: socket.assigns.current_user
 )
 # ...
```

And voilà, the tracks will appear on the form! You can edit the existing tracks and save the album, and the data will be updated. All of the built-in validations from defining constraints and allow_nil? false on the track’s attributes will be run. You won’t be able to save tracks without a name or with a duration of less than one second.

### Adding and Removing Tracks via the Form

To make the form usable, though, we need to be able to add new tracks and delete existing ones. The UI is already in place for it; the form has an Add Track button, and each row has a little trash can button to delete it. Currently, the buttons send the events “add-track” and “remove-track” to the FormLive liveview, but the event handlers don’t do anything … yet.

#### Adding New Rows for Track Data

AshPhoenix.Form provides helpers that we can use for adding and removing nested rows in our form, namely add_form and remove_form. In the “add-track” event handler, update the form reference stored in the socket and add a form at the specified path, or layer of nesting:

[08/lib/tunez_web/live/albums/form_live.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez_web%2Flive%2Falbums%2Fform_live.ex)

```elixir
 def handle_event("add-track", _params, socket) do
 socket =
 update(socket, :form, fn form ->
 AshPhoenix.Form.add_form(form, :tracks)
 end)

 {:noreply, socket}
 end
```

If you’re more familiar with the Phoenix method of adding form inputs using a hidden checkbox, AshPhoenix supports that as well. It’s a little less obvious as to what’s going on, though, which is why we’d generally opt for the more direct event handler way.

We can also auto-populate data in the added form rows, using the params option to add_form. For example, if we wanted to pre-populate the order when adding new tracks, we could use AshPhoenix.Form.value to introspect the form and set the value:

```elixir
 update(socket, :form, fn form ->
 order = length(AshPhoenix.Form.value(form, :tracks) || []) + 1
 AshPhoenix.Form.add_form(form, :tracks, params: %{order: order})
 end)
```

#### Removing Existing Rows of Track Data

Oops, we pressed the Add Track button one too many times! Abort, abort!

We can implement the event handler for removing a track form in a similar way to adding a track form. The only real difference is that we need to know which track to remove. So the button for each row has a phx-value-path attribute on it to pass the name of the current form to the event handler as the path parameter:

[08/lib/tunez_web/live/albums/form_live.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez_web%2Flive%2Falbums%2Fform_live.ex)

```elixir
 <.button_link phx-click="remove-track" phx-value-path={track_form.name}
 kind="error" size="xs" inverse>
 Delete
 <.icon name="hero-trash" class="size-5" />
 </.button_link>
```

This path will be form[tracks][2] if we click the delete button for the third track in the list (zero-indexed). That path can be passed directly to AshPhoenix.Form.remove_form to update the parent and delete the form at that path.

[08/lib/tunez_web/live/albums/form_live.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez_web%2Flive%2Falbums%2Fform_live.ex)

```elixir
 def handle_event("remove-track", %{"path" => path}, socket) do
 socket =
 update(socket, :form, fn form ->
 AshPhoenix.Form.remove_form(form, path)
 end)

 {:noreply, socket}
 end
```

AshPhoenix also supports the checkbox method for deleting forms, as well.

And that’s it for the basic usability of our track forms! AshPhoenix provides a nice API for working with forms, making most of what we need to do in our views straightforward.

### What About Policies?!

If you spotted that we didn’t write any policies for our new Track resource, that’s a gold star for you! (Gold star even if you didn’t. You’ve earned it.)

Tunez is secure, authorization-wise, as it is right now, but there’s no guarantee that it will stay that way. We’re not currently running any actions manually for tracks, so they’re inheriting policies from the context they’re called in. That could change in the future, though: we might add a form for managing individual tracks, and without specific policies on the Tunez.Music.Track resource, it would be wide open.

Let’s codify a version of our implicit rule of tracks inheriting policies from their parent album, with an accessing_from policy check:

[08/lib/tunez/music/track.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Ftrack.ex)

```elixir
 defmodule Tunez.Music.Track do
 use Ash.Resource,
 otp_app: :tunez,
 domain: Tunez.Music,
 data_layer: AshPostgres.DataLayer,
 authorizers: [Ash.Policy.Authorizer]

 policies do
 policy always() do
 authorize_if accessing_from(Tunez.Music.Album, :tracks)
 end
 end
```

This can be read as “if tracks are being read/created/updated/deleted through a :tracks relationship on the Tunez.Music.Album resource, then the request is authorized”. Reading track lists via a load statement to show on the artist profile? A-OK. Ash will run authorization checks for all of the loaded resources—the artist, the albums, and the tracks—and if they all pass, the artist profile will be rendered.

Updating a single album with an included list of track data? Policies will be checked for both the album and the tracks, and the track policy will always pass in this scenario.

Fetching an individual track record in iex, via its ID? Nope, it wouldn’t be allowed by this policy. Hmmm … that doesn’t sound right. We’ll fix that by adding another check in the policy:

[08/lib/tunez/music/track.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Ftrack.ex)

```elixir
 policy always() do
 authorize_if accessing_from(Tunez.Music.Album, :tracks)
 authorize_if action_type(:read)
 end
```

This looks different than the policies we wrote in Chapter 6. Those policies used action_type in the policy condition, not in individual checks, but both ways will work. This could have been written as two separate policies:

```elixir
 policies do
 policy accessing_from(Tunez.Music.Album, :tracks) do
 authorize_if always()
 end

 policy action_type(:read) do
 authorize_if always()
 end
 end
```

Our initial version is much more succinct, though, and more readable.

Testing these policies is a little trickier than those in our Artist/Album resources. We don’t have code interfaces for the Track actions, and we have to test them through the album resource. This is a good candidate for using seeds to generate test data to clearly separate creating the data from testing what we can do with it.

There are a few tests in the test/tunez/music/track_test.exs file to cover these new policies—you’ll also need to uncomment the track() generator function in the Tunez.Generator module.

## Reorder All of the Tracks!!!

Now that we can add tracks to an album, we can display nicely formatted track lists for each album on the artist’s profile page. Currently, we have a “track data coming soon” placeholder display coming from the track_details function component in TunezWeb.Artists.ShowLive. This is because when the track_details function component is rendered at the bottom of the album_details function component, the provided tracks is a hardcoded empty list.

To put the real track data in there, first, we need to load the tracks when we load album data, up in the handle_params/3 function. We already have :albums as a single item in the list of data to load, so to load tracks for each of the albums, we turn it into a keyword list:

[08/lib/tunez_web/live/artists/show_live.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez_web%2Flive%2Fartists%2Fshow_live.ex)

```elixir
 defmodule TunezWeb.Artists.ShowLive do
 # ...

 def handle_params(%{"id" => artist_id}, _url, socket) do
 artist =
 Tunez.Music.get_artist_by_id!(artist_id,
 load: [albums: [:tracks]],
 actor: socket.assigns.current_user
 )

 # ...
```

Because we’ve added a sort for the tracks relationship, we’ll always get tracks in the correct order, ordered by order. Then we need to replace the hardcoded empty list in the album_details function component with a reference to the real tracks, loaded on the @album struct.

[08/lib/tunez_web/live/artists/show_live.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez_web%2Flive%2Fartists%2Fshow_live.ex)

```elixir
 </.header>
 <.track_details tracks={@album.tracks} />
 
 
```

Depending on the kinds of data you’ve been entering while testing, you might now see something like the following when looking at your test album:

This doesn’t look great. We don’t have any validations to make sure the track numbers entered are a sequential list, with no duplicates, or anything! But do we really want to write validations for that to put the onus on the user to enter the right numbers? It’d be better if we could automatically order them based on the data in the form. The first track in the list should be track 1, the second track should be track 2, and so on. That way, there’d be no chance of mistakes.

### Automatic Track Numbering

This automatic numbering can be done with a tweak to our manage_relationship call, in the create and update actions in the Tunez.Music.Album resource. The order_is_key option will do what we want: take the position of the record in the list and set it as the value of the attribute we specify.

[08/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 create :create do
 # ...
 change manage_relationship(:tracks, type: :direct_control,
 order_is_key: :order)
 end

 update :update do
 # ...
 change manage_relationship(:tracks, type: :direct_control,
 order_is_key: :order)
 end
```

With this change, we don’t want users to be editing the track order on the form anymore. As the reordering is only done when submitting the form, it would be weird to let them set a number only to change it later. For now, remove the order field from its table cell in the track_inputs function component in TunezWeb.Albums.FormLive, but leave the empty table cell—we’ll reuse it in a moment.

[08/lib/tunez_web/live/albums/form_live.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez_web%2Flive%2Falbums%2Fform_live.ex)

```elixir
 
 
 
```

Now, when editing an album, the form will look odd with the missing field, but saving it will set the order attribute on each track to the index of the record in the list. There is one tiny caveat: the list starts from zero, as our automatic database indexing starts from zero. No one counts tracks from zero!

We could update our track list display to add one to the order field, but this doesn’t fix the real problem. Any other views of track data, such as in our APIs, would use the zero-offset value and be off by one. To solve this, we can keep our zero-indexed order field, but we won’t expose it anywhere. Instead, we can separate the concepts of ordering and numbering and add a calculation for the number to display in the UI.

### Ordering, Numbering, What’s the Difference?

We’re programmers, so we’re used to counting things starting at zero, but most people aren’t. When we talk about music or any list of items, we count things starting at one. We even said when we created the order attribute that the first track would have order 1, and so on, … and then we didn’t actually do that. We’ll fix that.

In our Tunez.Music.Track resource, add a top-level block for calculations, and define a new calculation:

[08/lib/tunez/music/track.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Ftrack.ex)

```elixir
 defmodule Tunez.Music.Track do
 # ...

 calculations do
 calculate :number, :integer, expr(order + 1)
 end
 end
```

This uses the same expression syntax we’ve seen when writing filters, policies, and calculations in the past, to add a new number calculation. It’s a pretty simple one, incrementing the order attribute to make it one-indexed.

We’ll always want this number calculation loaded when loading track data. To do that, we can use a custom preparation. Similar to how changes add functionality to create and update actions, preparations are used to customize read actions.

Add a new preparations block in the Tunez.Music.Track resource, and add a preparation that uses the build/1 built-in preparation.

[08/lib/tunez/music/track.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Ftrack.ex)

```elixir
 defmodule Tunez.Music.Track do
 use Ash.Resource, # ...

 preparations do
 prepare build(load: [:number])
 end

 # ...
```

Then we can use the number calculation when rendering track details, in the track_details function component:

[08/lib/tunez_web/live/artists/show_live.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez_web%2Flive%2Fartists%2Fshow_live.ex)

```elixir
 
 
 {String.pad_leading("#{track.number}", 2, "0")}.
 
```

Perfect! Everything is now in place for the last set of seed data to be imported for Tunez: tracks for all of the seeded albums. To import the track data, run the following on the command line:

```elixir
 $ mix  run  priv/repo/seeds/08-tracks.exs
```

You can also uncomment the last line of the mix seed alias, in the aliases/0 function in mix.exs:

[08/mix.exs](http://media.pragprog.com/titles/ldash/code/08%2Fmix.exs)

```elixir
 defp aliases do
 [
 setup: ["deps.get", "ash.setup", "assets.setup", "assets.build", ...],
 "ecto.setup": ["ecto.create", "ecto.migrate"],
 seed: [
 "run priv/repo/seeds/01-artists.exs",
 "run priv/repo/seeds/02-albums.exs",
 "run priv/repo/seeds/08-tracks.exs"
 ],
 # ...
```

You can run mix seed at any time to fully reset the sample artist, album, and track data in your database. Now, each album will have a full set of tracks. Tunez is looking good!

### Drag n’ Drop Sorting Goodness

We have this awesome form: we can add and remove tracks, and everything works well. Managing the order of the tracks is still an issue, though. What if we make a mistake in data entry and forget track 2? We’d have to remove all the later tracks and then re-add them after putting track 2 in. It’d be better if we could drag and drop tracks to reorder the list as necessary.

Okay, so our example is a little bit contrived, and reordering track lists isn’t something that needs to be done often. But reordering lists in general comes up in apps all the time—in checklists or to-do lists, in your GitHub project board, in your top 5 favorite Zombie Kittens!! albums. So let’s add it in.

AshPhoenix broadly supports two ways of reordering records in a form: stepping single items up or down the list or reordering the whole list based on a new order. Both would work for what we want our form to do, but in our experience, the latter is a bit more common and definitely more flexible.

#### Integrating a SortableJS Hook

Interactive functionality like drag and drop generally means integrating a JavaScript library. There are several choices out there, such as Draggable, Interact.js, Pragmatic drag and drop, or you can even build your own using the HTML drag and drop API. We prefer SortableJS.

To that end, we’ve already set a Phoenix phx-hook up on the tracks table, in the track_inputs component in TunezWeb.Albums.FormLive, which has a basic SortableJS implementation:

[08/lib/tunez_web/live/albums/form_live.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez_web%2Flive%2Falbums%2Fform_live.ex)

```elixir
 
 <.inputs_for :let={track_form} field={@form[:tracks]}>
 
 
 
 
 
```

This SortableJS setup is defined in assets/js/trackSort.js. It takes the element that the hook is defined on, makes its children tr elements draggable, and when a drag takes place, pushes a “reorder-tracks” event to our liveview with the list of data-ids from the draggable elements.

Note that in our previous form, we’ve also added an icon where the order number input previously sat to act as a drag handle. This is what you click to drag the rows around and reorder them.

With the handle added to the form, you should now be able to drag the rows around by their handles to reorder them. When you drop a row in its new position, your Phoenix server logs will show you that an event was received from the callback defined in the JavaScript hook:

```elixir
 [debug] HANDLE EVENT "reorder-tracks" in TunezWeb.Albums.FormLive
 Parameters: %{"order" => ["0", "1", "3", "4", "5", "2", "6", ...]}
 [debug] Replied in 433µs
```

This order is the order we’ve requested that the tracks be ordered in, which, in this example, means dragging the third item (index 2) to be placed in the sixth position.

In that “reorder-tracks” event handler, we can use AshPhoenix’s sort_forms/3 function to reorder the tracks, based on the new order.

[08/lib/tunez_web/live/albums/form_live.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez_web%2Flive%2Falbums%2Fform_live.ex)

```elixir
 def handle_event("reorder-tracks", %{"order" => order}, socket) do
 socket = update(socket, :form, fn form ->
 AshPhoenix.Form.sort_forms(form, [:tracks], order)
 end)
 {:noreply, socket}
 end
```

Give it a try—drag and drop tracks, save the album, and the changed order will be saved. The order (and therefore the number) of each track will be recalculated correctly, and everything is awesome!

## Automatic Conversions Between Seconds and Minutes

As we suggested earlier, we don’t want to show a track duration as a number of seconds to users—and that’s any users, whether they’re reading the data on the artist’s profile page or editing track data via a form. Users should be able to enter durations of tracks as a string like “3:13”, and then Tunez should convert that to a number of seconds before saving it to the database.

### Calculating the Minutes and Seconds of a Track

We already have a lot of track data in the database stored in seconds, so the first step is to convert it to a minutes-and-seconds format for display.

We’ve seen calculations written inline with expressions, such as when we added a number calculation for tracks earlier. Like changes, calculations can also be written using anonymous functions or extracted out to separate calculation modules for reuse. A duration calculation for our Track resource using an anonymous function is written as follows:

```elixir
 calculations do
 # ...

 calculate :duration, :string, fn tracks, context ->
 # Code to calculate duration for each track in the list of tracks
 end
 end
```

The main difference here is that a calculation function always receives a list of records to calculate data for. Even if you’re fetching a record by primary key and loading a calculation on the result so there will only ever be one record, the function will still receive a list.

The same behavior occurs if we define a separate calculation module instead—a module that uses Ash.Resource.Calculation and implements the calculate/3 callback:

[08/lib/tunez/music/calculations/seconds_to_minutes.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Fcalculations%2Fseconds_to_minutes.ex)

```elixir
 defmodule Tunez.Music.Calculations.SecondsToMinutes do
 use Ash.Resource.Calculation

 @impl true
 def calculate(tracks, _opts, _context) do
 # Code to calculate duration for each track in the list of tracks
 end
 end
```

This module can then be used as the calculation implementation in the Tunez.Music.Track resource:

[08/lib/tunez/music/track.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Ftrack.ex)

```elixir
 calculations do
 calculate :number, :integer, expr(order + 1)
 calculate :duration, :string, Tunez.Music.Calculations.SecondsToMinutes
 end
```

The calculate/3 function in the calculation module should iterate over the tracks and generate nicely formatted strings representing the number of minutes and seconds of each track. This function should also always return a list, where each item of the list is the value of the calculation for the corresponding record in the input list.

[08/lib/tunez/music/calculations/seconds_to_minutes.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Fcalculations%2Fseconds_to_minutes.ex)

```elixir
 def calculate(tracks, _opts, _context) do
 Enum.map(tracks, fn %{duration_seconds: duration} ->
 seconds =
 rem(duration, 60)
 |> Integer.to_string()
 |> String.pad_leading(2, "0")

 "#{div(duration, 60)}:#{seconds}"
 end)
 end
```

We would always err on the side of using separate modules to write logic in, instead of anonymous functions. Separate modules allow you to define calculation dependencies using the load/3 callback, document the functionality using describe/1, or even add an alternative implementation of the calculation that can run in the database using expression/2.

An alternative implementation? When would that be useful?

#### Two Implementations for Every Calculation

The way Ash handles calculations is remarkable. Calculations written using Ash’s expression syntax can be run either in the database or in code. Let’s start with a calculation on the Album resource like this:

```elixir
 calculate :description, :string, expr(name <> " :: " <> year_released)
```

This could be run in the database using SQL if the calculation is loaded at the same time as the data:

```elixir
 iex(1)> Tunez.Music.get_album_by_id!(uuid, load: [:description])
 SELECT a0."id", the other album fields, (a0."name"::text || ($1 ||
 a0."year_released"::bigint))::text FROM "albums" AS a0 WHERE (a0."id"::uuid
 = $2::uuid) [" :: ", uuid]
 %Tunez.Music.Album{description: "Chronicles :: 2022", ...}
```

It can also be run in code using Elixir, if the calculation is loaded on an album already in memory, using Ash.load. By default, Ash will always try to fetch the value from the database to ensure it’s up-to-date, but you can force Ash to use the data in memory and run the calculation in memory using the reuse_values?: true option:

```elixir
 iex(2)> album = Tunez.Music.get_album_by_id!(uuid)
 SELECT a0."id", a0."name", a0."cover_image_url", a0."created_by_id", ...
 %Tunez.Music.Album{description: #Ash.NotLoaded<...>, ...}
 iex(3)> Ash.load!(album, :description, reuse_values?: true)
 %Tunez.Music.Album{description: "Chronicles :: 2022", ...}
```

Why does this matter? Imagine if, instead of doing a quick string manipulation for our calculation, we were doing something complicated for every track on an album, and we were loading a lot of records at once, such as a band with a huge discography. We’d be running calculations in a big loop that would be slow and inefficient. The database is generally a much more optimized place for running logic with its query planning and indexing; nearly anything that we can push into the database, we should.

Why are we talking about this now? Because writing calculations in Elixir using calculate/3 is useful, but it’s not the optimal approach. And our calculation for converting a number of seconds to minutes-and-seconds can be written using an expression, instead of using Elixir code. It’s not an entirely portable expression, though; it uses a database fragment to call PostgreSQL’s to_char number formatting function.

To use an expression in a calculation module, instead of defining a calculate/3 function, we define an expression/2 function:

[08/lib/tunez/music/calculations/seconds_to_minutes.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Fcalculations%2Fseconds_to_minutes.ex)

```elixir
 defmodule Tunez.Music.Calculations.SecondsToMinutes do
 use Ash.Resource.Calculation

 @impl true
 def expression(_opts, _context) do
 expr(
 fragment("? / 60 || to_char(? \ interval '1s', ':SS')"*,
 duration_seconds, duration_seconds)
 )
 end
 end
```

This expression takes the duration_seconds column, converts it to a time, and then formats it. It works pretty well. You can test it in iex by loading a single track and the duration calculation on it:

```elixir
 iex(7)> Ash.get!(Tunez.Music.Track, uuid, load: [:duration])
 SELECT t0."id", t0."name", t0."order", t0."inserted_at", t0."updated_at",
 t0."duration_seconds", t0."album_id", (t0."order"::bigint + $1::bigint)
 ::bigint, (t0."duration_seconds"::bigint / 60 || to_char(t0."duration_seconds"
 ::bigint * interval '1s', ':SS'))::text FROM "tracks" AS t0 WHERE
 (t0."id"::uuid = $2::uuid) LIMIT $3 [1, uuid, 2]
 #Tunez.Music.Track<duration: "5:04", duration_seconds: 304, ...>
```

 

> **Calculations like This Are a Good Candidate for Testing!**
> Calculations like This Are a Good Candidate for Testing!
> There’s a test in Tunez for this calculation, covering various durations and verifying the result, in test/tunez/music/calculations/seconds_to_minutes_test.exs. This test proved invaluable because our own initial implementation of the expression didn’t properly account for tracks over one hour long!

 

This expression is pretty short and could be dropped back into our Tunez.Music.Track resource, but keeping it in the module has one distinct benefit—we can reuse it!

### Updating the Track List with Formatted Durations

We can also use our SecondsToMinutes calculation module to generate durations for entire albums, with the help of an aggregate. Way back in [*Relationship Calculations as Aggregates*](#f_0032.xhtml_ch03.aggregates), we wrote aggregates like first and count for an artist’s related albums. Ash also provides a sum aggregate type for, you guessed it, summing up data from related records.

So, to generate the duration of an album, we can add an aggregate in our Album resource to add up the duration_seconds of all of its tracks and then reuse the SecondsToMinutes calculation we just wrote to format it!

[08/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 defmodule Tunez.Music.Album do
 # ...

 aggregates do
 sum :duration_seconds, :tracks, :duration_seconds
 end

 calculations do
 calculate :duration, :string, Tunez.Music.Calculations.SecondsToMinutes
 end
 end
```

Now that we have nicely formatted durations for an album and its tracks, let’s update the track list on the artist profile to show them. We can load the track duration calculation as part of the default preparation for Tracks, alongside the number calculation:

[08/lib/tunez/music/track.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Ftrack.ex)

```elixir
 preparations do
 prepare build(load: [:number, :duration])
 end
```

Album durations are less critical—for now, we probably only need them on this artist profile page. In Tunez.Artists.ShowLive, load the duration for each album:

[08/lib/tunez_web/live/artists/show_live.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez_web%2Flive%2Fartists%2Fshow_live.ex)

```elixir
 def handle_params(%{"id" => artist_id}, _url, socket) do
 artist =
 Tunez.Music.get_artist_by_id!(artist_id,
 load: [albums: [:duration, :tracks]],
 actor: socket.assigns.current_user
 )
```

The album_details function component can then be updated to include the duration of the album:

[08/lib/tunez_web/live/artists/show_live.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez_web%2Flive%2Fartists%2Fshow_live.ex)

```elixir
 <.h2>
 {@album.name} ({@album.year_released})
 ({@album.duration})
 </.h2>
```

And the track_details function component can be updated to use the duration field instead of duration_seconds.

[08/lib/tunez_web/live/artists/show_live.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez_web%2Flive%2Fartists%2Fshow_live.ex)

```elixir
 
 <% # ... %>
 {track.duration}
 
```

And it looks awesome!

There’s only one last thing we need to make better: the Album form, so users can enter human-readable durations, instead of seconds.

### Calculating the Seconds of a Track

At the moment, the actions in the Tunez.Music.Track resource will accept data for the duration_seconds attribute, in both the create and update actions, and save it to the data layer. Instead of accepting the attribute directly, we can pass in the formatted version of the duration as an argument to the action, and then use a change to process that argument. To prevent the change from running when no duration argument is provided, use the only_when_valid? option when configuring the change.

Again, the update action should be marked with require_atomic?: false. This change could be written in an atomic way (more on that in [*We Need to Talk About Atomics*](#f_0070.xhtml_ch10.atomics)), but because these actions are already running non-atomically via the album, we’ll leave it as-is.

[08/lib/tunez/music/track.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Ftrack.ex)

```elixir
 actions do
 # ...

 create :create do
 primary? true
 accept [:order, :name, :album_id]
 argument :duration, :string, allow_nil?: false
 change Tunez.Music.Changes.MinutesToSeconds, only_when_valid?: true
 end

 update :update do
 primary? true
 accept [:order, :name]
 require_atomic? false
 argument :duration, :string, allow_nil?: false
 change Tunez.Music.Changes.MinutesToSeconds, only_when_valid?: true
 end
 end
```

This means that we can call the actions with a map of data, including a duration key, and the outside world doesn’t need to know anything about the internal representation or storage of the data.

Now we need to implement the MinutesToSeconds change module, which should be in a new file at lib/tunez/music/changes/minutes_to_seconds.ex. Like the UpdatePreviousNames module we created for artists in [*Defining a Change Module*](#f_0026.xhtml_ch02.change_module), this will be a separate module that uses Ash.Resource.Change, and defines a change/3 action:

[08/lib/tunez/music/changes/minutes_to_seconds.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Fchanges%2Fminutes_to_seconds.ex)

```elixir
 defmodule Tunez.Music.Changes.MinutesToSeconds do
 use Ash.Resource.Change

 @impl true
 def change(changeset, _opts, _context) do
 end
 end
```

This change function can have any Elixir code in it, so we can extract the duration argument from the provided changeset, validate the format and value, and convert it to a number:

[08/lib/tunez/music/changes/minutes_to_seconds.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Fchanges%2Fminutes_to_seconds.ex)

```elixir
 def change(changeset, _opts, _context) do
 {:ok, duration} = Ash.Changeset.fetch_argument(changeset, :duration)

 with :ok <- ensure_valid_format(duration),
 :ok <- ensure_valid_value(duration) do
 changeset
 |> Ash.Changeset.change_attribute(:duration_seconds, to_seconds(duration))
 else
 {:error, :format} ->
 Ash.Changeset.add_error(changeset, field: :duration,
 message: "use MM:SS format"
 )

 {:error, :value} ->
 Ash.Changeset.add_error(changeset, field: :duration,
 message: "must be at least 1 second long"
 )
 end
 end

 defp ensure_valid_format(duration) do
 if String.match?(duration, ~r/^\d+:\d{2}$/) do
 :ok
 else
 {:error, :format}
 end
 end

 defp ensure_valid_value(v) when v in ["0:00", "00:00"], do: {:error, :value}
 defp ensure_valid_value(_value), do: :ok

 defp to_seconds(duration) do
 [minutes, seconds] = String.split(duration, ":", parts: 2)
 String.to_integer(minutes) * 60 + String.to_integer(seconds)
 end
```

It’s a little bit long, but it neatly encapsulates our requirements.

These checks in the change module might feel a bit like validations that belong in the Track resource. We’d argue that they specifically relate to the duration argument being processed, and not any attributes on the resource itself. If we wanted to add support for other duration formats later, such as “2m12s” or “five minutes”, we’d only have to update the code in one place—here, in this change module, to validate and parse the value.

You can test the change out in iex by building a changeset for a track. You don’t need to submit it or even validate it, but you’ll see the conversion:

```elixir
 iex(4)> Tunez.Music.Track
 Tunez.Music.Track
 iex(5)> |> Ash.Changeset.for_create(:create, %{duration: "02:12"})
 #Ash.Changeset<
 attributes: %{duration_seconds: 132},
 arguments: %{duration: "02:12"},
 ...
```

Invalid values will report the “use MM:SS format” error, and missing values will report that the field is required.

The last thing left to do is to update our Album form to use the duration attribute of tracks, instead of duration_seconds. For existing tracks, this will display the formatted value (which is auto-loaded via the load preparation) and then convert it back to seconds on save. The UI is none the wiser!

[08/lib/tunez_web/live/albums/form_live.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez_web%2Flive%2Falbums%2Fform_live.ex)

```elixir
 
 <% # ... %>
 
 <label for={track_form[:duration].id} class="hidden">Duration</label>
 <.input field={track_form[:duration]} />
 
```

## Adding Track Data to API Responses

We can’t forget about our API users; they’d like to be able to see track information for albums, too! To support the Track resource in the APIs, use the ash.extend Mix task to add the extensions and the basic configuration:

```elixir
 $ mix  ash.extend  Tunez.Music.Track  json_api
 $ mix  ash.extend  Tunez.Music.Track  graphql
```

Because we will always be reading or updating tracks in the context of an album, we don’t need to add any JSON API endpoints or GraphQL queries or mutations for them: the existing album endpoints will be good enough. But we do need to mark relationships and attributes as public?: true if we want them to be readable. This includes the tracks relationship in the Tunez.Music.Album resource:

[08/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 relationships do
 # ...

 has_many :tracks, Tunez.Music.Track do
 sort order: :asc
 public? true
 end
```

And the attributes to show for each track, in the Tunez.Music.Track resource. This doesn’t have to include our internal order or duration_seconds attributes!

[08/lib/tunez/music/track.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Ftrack.ex)

```elixir
 attributes do
 # ...

 attribute :name, :string do
 allow_nil? false
 public? true
 end

 # ...
 end

 calculations do
 calculate :number, :integer, expr(order + 1) do
 public? true
 end

 calculate :duration, :string, Tunez.Music.Calculations.SecondsToMinutes do
 public? true
 end
 end
```

This is all we need to do for GraphQL. As you only fetch the fields you specify, consumers of the API can automatically fetch tracks of an album and can read all, some, or none of the track attributes if they want to. You may want to disable automatic filterability and sortability with derive_filter? false and derive_sort? false in the Track resource, but that’s about it.

### Special Treatment for the JSON API

Our JSON API needs a little more work, though. To allow tracks to be included when reading an album, we need to manually configure that with the includes option in the Tunez.Music.Album resource:

[08/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 json_api do
 type "album"
 includes [:tracks]
 end
```

This will allow users to add the include=tracks query parameter to their requests to Album-related endpoints, and the track data will be included. If you want to allow tracks to be includable when reading artists, for example, when searching or fetching an artist by ID, that includes option must be set separately as part of the Tunez.Music.Artist json_api configuration.

[08/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 defmodule Tunez.Music.Artist do
 # ...

 json_api do
 type "artist"
 includes albums: [:tracks]
 derive_filter? false
 end
```

With this config, users can request either albums to be included for an artist with include=albums in the query string, or albums and their tracks with include=albums.tracks. Neat!

As we learned in [*What Data Gets Included in API Responses?*](#f_0035.xhtml_ch04.included_attributes), by default, only public attributes will be fetched and returned via the JSON API. This isn’t great for tracks because only the name is a public attribute—number and duration are both calculations! For tracks, it would make more sense to configure the default_fields that are always returned for every response; this way we can include the attributes and calculations we want.

[08/lib/tunez/music/track.ex](http://media.pragprog.com/titles/ldash/code/08%2Flib%2Ftunez%2Fmusic%2Ftrack.ex)

```elixir
 json_api do
 type "track"
 default_fields [:number, :name, :duration]
 end
```

Now our API users also have a good experience! They can access and manage track data for albums, just like web UI users can.

We covered a lot in this chapter, and there are so many little fiddly details about forms to make them just right. It’ll take practice getting used to, especially if you want to build forms with different UIs such as adding/removing tags, but the principles will stay the same.

In our next chapter, we’ll start adding some personalization to Tunez, using everything we’ve learned so far to let users follow their favorite artists. And we’ll make it smart—building code interfaces that speak our domain language and uncovering insights like who the most popular artists are. It’ll be fun!

Footnotes

<https://hexdocs.pm/ash/dsl-ash-resource.html#relationships-has_many-sort>

<https://hexdocs.pm/ash_postgres/dsl-ashpostgres-datalayer.html#postgres-references-reference>

<https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html#inputs_for/1>

<https://hexdocs.pm/ash/Ash.Resource.Change.Builtins.html#manage_relationship/3>

<https://hexdocs.pm/ash/Ash.Changeset.html#manage_relationship/4>

<https://hexdocs.pm/ash_phoenix/AshPhoenix.Form.html#add_form/3>

<https://hexdocs.pm/ash_phoenix/AshPhoenix.Form.html#remove_form/3>

<https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html#inputs_for/1-dynamically-adding-and-removing-inputs>

<https://hexdocs.pm/ash_phoenix/nested-forms.html#the-_add_-checkbox>

<https://hexdocs.pm/ash_phoenix/AshPhoenix.Form.html#value/2>

<https://hexdocs.pm/ash_phoenix/nested-forms.html#using-the-_drop_-checkbox>

<https://hexdocs.pm/ash/Ash.Policy.Check.Builtins.html#accessing_from/2>

<https://hexdocs.pm/ash/Ash.Changeset.html#manage_relationship/4>

<https://hexdocs.pm/ash/expressions.html>

<https://hexdocs.pm/ash/preparations.html>

<https://hexdocs.pm/ash/Ash.Resource.Preparation.Builtins.html#build/1>

<https://shopify.github.io/draggable/>

<https://interactjs.io/>

<https://atlassian.design/components/pragmatic-drag-and-drop/about>

<https://sortablejs.github.io/Sortable/>

<https://hexdocs.pm/ash_phoenix/AshPhoenix.Form.html#sort_forms/3>

<https://hexdocs.pm/ash/Ash.Resource.Calculation.html>

<https://hexdocs.pm/ash/Ash.html#load/3>

<https://www.postgresql.org/docs/current/functions-formatting.html>

<https://hexdocs.pm/ash/aggregates.html#aggregate-types>

<https://hexdocs.pm/ash/Ash.Resource.Change.html>

<https://hexdocs.pm/ash_json_api/dsl-ashjsonapi-resource.html#json_api-default_fields>

Copyright © 2025, The Pragmatic Bookshelf.
