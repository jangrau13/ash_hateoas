# 9. Following Your Favorite Artists

##  Chapter 9 Following Your Favorite Artists

Tunez is starting to come together—we’re collecting a lot of useful information about artists, and users can quickly find the information they’re looking for. But the app is completely static. There’s no reason for users to engage in regularly checking back to see what’s new because they can’t easily get updates on things they’re interested in. We need that cool factor. We want users to be able to make Tunez work for them!

As part of that cool factor, we’ll add a notification system to the app, so we can immediately find out when our favorite artists release new albums. But before we can get notified about updates for the artists we follow, we first need Tunez to know who our followed artists are.

## Modelling with a Many-to-Many Relationship

We can model the link between users and their followed artists with a many-to-many relationship—each user can have many followed artists, and each artist can have many ardent followers.

In Ash (and in a lot of other frameworks), this is implemented using a join resource. This join resource will sit in between our two existing resources of Tunez.Music.Artist and Tunez.Accounts.User, joining them together, and have a belongs_to relationship to each of them. Thus, each link between a user and an artist will be a record in the join resource—if ten users each follow ten different artists, then the join table will have 100 records.

### Creating the ArtistFollower Resource

The hardest problem in computer science is always naming things, and resources can be no exception. What should we call this join resource? Some join relationships naturally lend themselves to nice names such as “GroupMembership” or “MailingListSubscription”, but a lot don’t. Ultimately, as long as the name makes sense, it doesn’t really matter. If all else fails, smoosh the two resource names together, as in “ArtistUser”. We’ve chosen ArtistFollower, but it could just as easily have been something like “LikedArtist” or “FavoriteArtist”.

And which domain should it go in? This is our first cross-domain relationship, so should it go in the Tunez.Music or the Tunez.Accounts domain? Again, it doesn’t make a huge difference. We have chosen Tunez.Music, as the relationship will be made in the direction of users -> artists, so it “feels” closer to the music side.

With all the big decisions out of the way, we’ll generate our basic resource:

```elixir
 $ mix  ash.gen.resource  Tunez.Music.ArtistFollower  --extend  postgres
```

Inside the new resource in lib/tunez/music/artist_follower.ex, we won’t be storing any data, so we don’t need any attributes. We do need to add relationships, though, for the user doing the following and the artist they want to follow:

[09/lib/tunez/music/artist_follower.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez%2Fmusic%2Fartist_follower.ex)

```elixir
 defmodule Tunez.Music.ArtistFollower do
 # ...

 relationships do
 belongs_to :artist, Tunez.Music.Artist do
 primary_key? true
 allow_nil? false
 end

 belongs_to :follower, Tunez.Accounts.User do
 primary_key? true
 allow_nil? false
 end
 end
 end
```

There’s something interesting in this snippet: we didn’t add an id attribute to use as a primary key, but we do need some way of uniquely identifying each record of the join resource. The combination of the two belongs_to foreign keys works well for this purpose, as a composite primary key—a user can’t follow the same artist more than once, so the combination of follower_id and artist_id will always be unique. Adding primary_key? true to both relationships will create one primary key with both columns.

If an artist gets deleted, or a user deletes their account, we want to set the on_delete property of the foreign keys to delete all of the follower links, just like we did with an album’s tracks or an artist’s albums:

[09/lib/tunez/music/artist_follower.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez%2Fmusic%2Fartist_follower.ex)

```elixir
 postgres do
 # ...

 references do
 reference :artist, on_delete: :delete, index?: true
 reference :follower, on_delete: :delete
 end
 end
```

Now that the resource is set up, generate a migration for it, and then run the migration:

```elixir
 $ mix  ash.codegen  create_artist_followers
 $ mix  ash.migrate
```

### Using ArtistFollower to Link Artists and Users

With the join resource in place, we can define the many-to-many relationship we’re after. It will go both ways—from a user record, we’ll be able to load all of their followed artists; and from an artist record, we’ll be able to load all of their followers.

In the Tunez.Music.Artist resource, we first define a has_many relationship for the join resource, and then a many_to_many relationship using that has_many relationship:

[09/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 relationships do
 # ...

 has_many :follower_relationships, Tunez.Music.ArtistFollower

 many_to_many :followers, Tunez.Accounts.User do
 join_relationship :follower_relationships
 destination_attribute_on_join_resource :follower_id
 end
 end
```

By default, Ash will look for a foreign key matching the name of the resource we’re linking to, in this case, a user_id because the many-to-many relationship is for a User resource. Because we’ve used follower_id in the join resource, to make it super clear which way the relationship goes, we have to specify that that’s the key to use to link through, using destination_attribute_on_join_resource.

It’s not strictly necessary to define the join relationship—we could have written the many-to-many relationship to go through the join resource directly:

```elixir
 many_to_many :followers, Tunez.Accounts.User do
 through Tunez.Music.ArtistFollower
 destination_attribute_on_join_resource :follower_id
 end
```

Ash would still set up a relationship behind the scenes, named artist_followers_join_assoc, but we wouldn’t have any access to it. This might be okay for your use case, but it wouldn’t allow any customization of the relationship, such as sorting and filtering.

In our use case, most of the questions we’ll be asking can also be answered by the join relationship directly. How many followers does a given artist have? Is the authenticated user one of them? Using the join relationship will save us, well, an extra database join for every query!

Add similar relationships in the Tunez.Accounts.User resource to create the many-to-many with the Tunez.Music.Artist resource:

[09/lib/tunez/accounts/user.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez%2Faccounts%2Fuser.ex)

```elixir
 relationships do
 has_many :follower_relationships, Tunez.Music.ArtistFollower do
 destination_attribute :follower_id
 end

 many_to_many :followed_artists, Tunez.Music.Artist do
 join_relationship :follower_relationships
 source_attribute_on_join_resource :follower_id
 end
 end
```

To be able to use the Tunez.Music.ArtistFollower join resource, it also needs at least a basic read action. We can add a default one, with a policy to allow anyone to read them:

[09/lib/tunez/music/artist_follower.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez%2Fmusic%2Fartist_follower.ex)

```elixir
 defmodule Tunez.Music.ArtistFollower do
 use Ash.Resource,
 # ...
 authorizers: [Ash.Policy.Authorizer]

 # ...

 actions do
 defaults [:read]
 end

 policies do
 policy action_type(:read) do
 authorize_if always()
 end
 end
 end
```

Now we can run a query in iex, and see the follower relationships of an artist:

```elixir
 iex(8)> Tunez.Music.get_artist_by_id!(uuid, load: [:follower_relationships])
 two SQL queries to load the data
 #Tunez.Music.Artist<follower_relationships: [], ...>
```

It appears to work! But it’s not super exciting as no artists have any followers yet. Let’s build the user interface to let users see and update which artists they follow.

## Who Do You Follow?

With our shiny new relationships in place, we can use them to determine if a given user follows a given artist and show that information in the app.

We’ll write this as a custom calculation, as an expression that uses the exists sub-expression. exists lets us check if any records in a relationship match a given condition, so we can use it to check if any of an artist’s followers are the current user, the actor running this query.

This will be loaded as part of an Artist record and shown on the artist profile page, so the calculation can be put on the Tunez.Music.Artist resource:

[09/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 calculations do
 calculate :followed_by_me,
 :boolean,
 expr(exists(follower_relationships, follower_id == ^actor(:id)))
 end
```

This uses the same actor template we used when writing policies based on the current user’s role back in [*Filling Out Policies*](#f_0048.xhtml_ch06.actor_policies). We could write it in a more generic way to check for a user passed in as an argument (because calculations can take arguments!), or a list of users (maybe we add user friends down the track, and we want to see if any of our friends follow an artist), but for now, we only care about who the logged-in user is following.

### Showing the Current Following Status

The option to follow or unfollow an artist will be shown on their profile page, up in the header:

The star will be filled in if the current user is following the artist, and hollow if they’re not. Clicking the star will toggle the follow status, from following to unfollowing and back again.

To show the current follow status (is the user following this artist or not?), we will load the new followed_by_me calculation when we load the artist data in Tunez.Artists.ShowLive. The calculation requires an actor, and we are already supplying the actor when we call Tunez.Music.get_artist_by_id!, so everything will work.

[09/lib/tunez_web/live/artists/show_live.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez_web%2Flive%2Fartists%2Fshow_live.ex)

```elixir
 def handle_params(%{"id" => artist_id}, _url, socket) do
 artist =
 Tunez.Music.get_artist_by_id!(artist_id,
 load: [:followed_by_me, albums: [:duration, :tracks]],
 actor: socket.assigns.current_user
 )
 # ...
```

We’ve preprepared a function component named follow_toggle that will use the value and show the follow status, so add it after the artist name:

[09/lib/tunez_web/live/artists/show_live.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez_web%2Flive%2Fartists%2Fshow_live.ex)

```elixir
 <.h1>
 {@artist.name}
 <.follow_toggle on={@artist.followed_by_me} />
 </.h1>
```

Clicking the star icon to follow the artist will do a little animation and then trigger the “follow” event handler, defined further down in the liveview. It currently doesn’t do anything, but we’ll flesh out the functionality now.

### Following a New Artist

Our liveview doesn’t know anything about how our data is structured or the relationships between our resources. And it doesn’t need to care! If we provide a nice code interface function like Tunez.Music.follow_artist(@artist, actor: current_user), the code in our liveview can be super simple, and we can tuck all the logic away inside our domain and resources.

Our envisaged follow_artist function will take the artist record as an argument and create a new ArtistFollower record. In the Tunez.Music domain module, add the code interface that describes this, pointing to a (not yet defined) create action in the ArtistFollower resource:

[09/lib/tunez/music.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez%2Fmusic.ex)

```elixir
 resources do
 # ...

 resource Tunez.Music.ArtistFollower do
 define :follow_artist, action: :create, args: [:artist]
 end
 end
```

Next, we need the create action in the Tunez.Music.ArtistFollower resource. What arguments should it take?

#### Structs for Action Arguments and Custom Inputs

We could add an argument for the artist record to the create action and validate the type with a constraint to make sure it’s a real Artist:

```elixir
 create :create do
 argument :artist, :struct do
 allow_nil? false
 constraints instance_of: Tunez.Music.Artist
 end
 # ...
```

This would create the function definition we want to use in our web app, but our web app isn’t the only interface that might be using this action. What if we also wanted to allow users to follow artists via the GraphQL API? Let’s add that and see what it looks like.

To enable GraphQL support for the ArtistFollower resource, extend the resource with graphql:

```elixir
 $ mix  ash.extend  Tunez.Music.ArtistFollower  graphql
```

And then add a new mutation for the create action, in the Tunez.Music domain module:

[09/lib/tunez/music.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez%2Fmusic.ex)

```elixir
 graphql do
 # ...

 mutations do
 # ...
 create Tunez.Music.ArtistFollower, :follow_artist, :create
 end
 end
```

In the GraphiQL playground at <http://localhost:4000/gql/playground>, the new followArtist mutation will be listed. It has an input argument of a generated FollowArtistInput! type:

```elixir
 type FollowArtistInput { artist: JsonString! }
```

Oh, gross. The mutation expects a JSON-serialized version of the artist record! Ideally, our APIs would accept the ID of the artist to follow. To get that, we’d have to use the artist ID as the argument to the create action, instead of the full artist record.

```elixir
 create :create do
 argument :artist_id, :uuid do
 allow_nil? false
 end
```

Or because artist_id is an attribute of the resource, via the :artist relationship, we could accept the attribute directly:

[09/lib/tunez/music/artist_follower.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez%2Fmusic%2Fartist_follower.ex)

```elixir
 create :create do
 accept [:artist_id]
```

But now the code interface is wrong, it requires you to pass in an artist ID instead of an artist struct! So annoying.

Way back in the [code](#f_0032.xhtml_ch03.default_options)[](#f_0032.xhtml_ch03.default_options), we saw an example of how we could configure the code interface to add extra functionality to the action, like loading related records. Our APIs for searching would not load the data, but calling the interface would. We can use a similar pattern for preprocessing the arguments to the create action at the code interface layer, using custom inputs.

Our code interface function can still accept the artist argument, which will be the full Artist record. But we’ll define that argument as a custom input for the code interface specifically—this will let us write a transform function to convert it to the artist_id argument that the action expects.

[09/lib/tunez/music.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez%2Fmusic.ex)

```elixir
 resource Tunez.Music.ArtistFollower do
 define :follow_artist do
 action :create
 args [:artist]

 custom_input :artist, :struct do
 constraints instance_of: Tunez.Music.Artist
 transform to: :artist_id, using: & &1.id
 end
 end
 end
```

It’s a little bit verbose, and it requires using the block syntax for all of the options for the code interface, but this is a really powerful (and customizable) technique. The constraint on the artist argument has moved from the action to the code interface, so the code interface function still accepts (and type-checks) an artist:

```elixir
 iex(1)> h Tunez.Music.follow_artist

 def follow_artist(artist, params \ nil, opts \ nil)

 Calls the create action on Tunez.Music.ArtistFollower.
```

But other interfaces that derive directly from our actions, such as the GraphQL API, will use the ID instead:

```elixir
 type FollowArtistInput { artistId: ID! }
```

That’s neat!

We’ve suitably addressed that issue, and the artist relationship will be correctly set on the ArtistFollower record. For the follower relationship, the only other data in this resource, we can use the relate_actor built-in change.

[09/lib/tunez/music/artist_follower.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez%2Fmusic%2Fartist_follower.ex)

```elixir
 create :create do
 accept [:artist_id]

 change relate_actor(:follower, allow_nil?: false)
 end
```

And who should be authorized to run this create action in our resource? Well, anyone, really, as long as they’re logged in so we know who is following whom! We can add a policy for that:

[09/lib/tunez/music/artist_follower.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez%2Fmusic%2Fartist_follower.ex)

```elixir
 policies do
 # ...

 policy action_type(:create) do
 authorize_if actor_present()
 end
 end
```

After adding the policy, you can test out the action in iex. We’ve also added some tests in the Tunez app for it, in test/tunez/accounts/artist_follower_test.exs.

```elixir
 iex(5)> artist = Tunez.Music.get_artist_by_id!(artist_uuid)
 #Tunez.Music.Artist<...>
 iex(6)> user = Tunez.Accounts.get_user_by_email!(email, authorize?: false)
 #Tunez.Accounts.User<...>
 iex(7)> Tunez.Music.follow_artist(artist, actor: user)
 INSERT INTO "artist_followers" ("artist_id","follower_id") VALUES ($1,$2)
 RETURNING "follower_id","artist_id" [artist_uuid, user_uuid]
 {:ok, %Tunez.Music.ArtistFollower{...}}
```

In the “follow” event handler in our TunezWeb.Artists.ShowLive, we’ll use the new function to make the current user follow the artist being shown and handle the response accordingly. In the successful case, we don’t need to show a flash message, but we can update the loaded artist record to say that yes, we now follow them!

[09/lib/tunez_web/live/artists/show_live.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez_web%2Flive%2Fartists%2Fshow_live.ex)

```elixir
 def handle_event("follow", _params, socket) do
 socket =
 case Tunez.Music.follow_artist(socket.assigns.artist,
 actor: socket.assigns.current_user
 ) do
 {:ok, _} ->
 update(socket, :artist, & %{&1 | followed_by_me: true})

 {:error, _} ->
 put_flash(socket, :error, "Could not follow artist")
 end

 {:noreply, socket}
 end
```

Clicking the follow star will now do a little spin and then fill in, showing that the artist is now followed. Awesome! Follow all of the artists!!!

### Unfollowing an Old Artist

But maybe we’re just not digging some of this music anymore and want to unfollow some of these artists. Clicking the star icon again should unfollow them, reverting back to our previous state.

Unfollowing, or deleting the relevant ArtistFollower record, is a little trickier to implement than following. To make a similar API to following artists, we’d define a code interface like Tunez.Music.unfollow_artist(@artist, actor: current_user) that pointed to a destroy action in the Tunez.Music.ArtistFollower resource. But the first argument to a typical destroy action is the record to be destroyed—which we don’t have here.

Ash has our back as usual. If we add the require_reference? option to our code interface, we can skip providing a record to be deleted, and write some logic in the action to find the correct record instead.

Using the same idea with a custom input for the artist, our code interface would look like this:

[09/lib/tunez/music.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez%2Fmusic.ex)

```elixir
 resource Tunez.Music.ArtistFollower do
 # ...
 define :unfollow_artist do
 action :destroy
 args [:artist]
 require_reference? false

 custom_input :artist, :struct do
 constraints instance_of: Tunez.Music.Artist
 transform to: :artist_id, using: & &1.id
 end
 end
 end
```

What would the action look like, though? If we had an empty action that just accepted the artist_id argument (after the custom input transformation) but didn’t do anything with it, the action would look like this:

```elixir
 destroy :destroy do
 argument :artist_id, :uuid do
 allow_nil? false
 end
 end
```

The result (if it wasn’t currently prevented by missing policies!) would be surprising—it would delete all ArtistFollower records! When we provide a single record to a destroy action to be destroyed, it’s used as a filter by Ash internally to delete the record in the data layer with the same primary key. Without that filter, Ash will try and delete eeeeeeverything. This is clearly not what we want.

To fix this, we’ll add our own filter to the action the same way we do when filtering read actions. The only difference is that we have to apply the filter as a change instead of calling it directly:

[09/lib/tunez/music/artist_follower.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez%2Fmusic%2Fartist_follower.ex)

```elixir
 destroy :destroy do
 argument :artist_id, :uuid do
 allow_nil? false
 end

 change filter(expr(artist_id == ^arg(:artist_id) &&
 follower_id == ^actor(:id)))
 end
```

For an authorization policy, we’ll use the same actor_present built-in check—our filter already accounts for the actor—to ensure that they can only delete their own followed artists:

[09/lib/tunez/music/artist_follower.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez%2Fmusic%2Fartist_follower.ex)

```elixir
 policies do
 # ...

 policy action_type(:destroy) do
 authorize_if actor_present()
 end
 end
```

This behaves as expected and will delete only the record we want, but the return type is slightly odd:

```elixir
 iex(8)> Tunez.Music.unfollow_artist!(artist, actor: user)
 SQL query to delete ArtistFollowers
 %Ash.BulkResult{
 status: :success, errors: nil, records: nil,
 notifications: [], error_count: 0
 }
```

#### A Short Detour into Bulk Actions

We will revisit bulk actions [in the next chapter,](#f_0067.xhtml_ch10.bulk_actions), but the short version is that most actions can be run for one record (destroy this one record in particular) or in bulk (destroy this entire list of records). Switching between the two behaviors depends on what you call the action with—if you call a create action with a list of records to be created, as opposed to a single map of data, you’ll get a bulk create.

Our destroy action uses a filter to narrow down which records to delete, but a filter will always return a list, even if that list only has one record in it. Because a list is being passed to the underlying core destroy functionality, we get the bulk behavior of the action and a special bulk result type back.

We could still use the action as is and match on the BulkResult in our liveview, but that’s leaking implementation details out into our view. It shouldn’t care what we’re doing behind the scenes!

Earlier, we saw how to use the get_by option on code interfaces to read a single record by some unique field such as id. Using get_by will automatically enable a few other options behind the scenes, including get? true—the Ash flag for saying that this function will return at most one record. If our unfollow_artist code interface uses get? true instead of require_reference? false, then the bulk result will be introspected, and if exactly zero or one record was deleted, it will return :ok like a standard destroy action.

|  |  |
|----|----|
|  | Note that if the action deletes more than one result, an error will be returned. This error is generated after the actual deletion is complete, so the records will still be deleted despite the error response. Test your actions thoroughly! We’ve added tests for our destroy in test/tunez/music/artist_follower_test.exs to ensure that our filter is working and only the correct record is destroyed. |

Using get? true will also automatically set require_reference? false, which is super convenient for us. Updating the options means that our action works as we want—we’ll get either :ok or an error tuple.

[09/lib/tunez/music.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez%2Fmusic.ex)

```elixir
 resource Tunez.Music.ArtistFollower do
 # ...
 define :unfollow_artist do
 action :destroy
 args [:artist]
 get? true

 # ...
 end
 end
```

```elixir
 iex(6)> Tunez.Music.unfollow_artist(artist, actor: user)
 :ok
```

#### Integrating the Code Interface into the Liveview

Back in the TunezWeb.Artist.ShowLive liveview, we now have the pieces to connect up in the “unfollow” event handler, much like we did for “follow”. We expect this to always be :ok, but in the off chance that something goes wrong, we can let the user know.

[09/lib/tunez_web/live/artists/show_live.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez_web%2Flive%2Fartists%2Fshow_live.ex)

```elixir
 def handle_event("unfollow", _params, socket) do
 socket =
 case Tunez.Music.unfollow_artist(socket.assigns.artist,
 actor: socket.assigns.current_user
 ) do
 :ok ->
 update(socket, :artist, & %{&1 | followed_by_me: false})

 {:error, _} ->
 put_flash(socket, :error, "Could not unfollow artist")
 end

 {:noreply, socket}
 end
```

Authenticated users will now be able to follow and unfollow any artist by clicking on the little star icon on an artist’s profile. But wait, so can unauthenticated users! We added authorization policies for the action, but not in the view—so all users can see the star icon.

To fix this, we can add a policy check when calling the follow_toggle function component to render the star in TunezWeb.Artists.ShowLive. Ash has auto-generated can_follow_artist? and can_unfollow_artist? functions for our code interfaces, so you can pick one to conditionally render the icon.

[09/lib/tunez_web/live/artists/show_live.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez_web%2Flive%2Fartists%2Fshow_live.ex)

```elixir
 <.h1>
 {@artist.name}
 <.follow_toggle
 :if={Tunez.Music.can_follow_artist?(@current_user, @artist)}
 on={@artist.followed_by_me}
 />
 </.h1>
```

## Spicing Up the Artist Catalog

With this one new relationship, we can do some pretty neat things using ideas and concepts we’ve already learned. Let’s make the artist catalog a bit more interesting!

### Showing the Follow Status for Each Artist

It’s a pain to have to click through to the artist profile to see if we follow them or not, so let’s add a little “following” icon to artists in the catalog if the logged-in user follows them.

In TunezWeb.Artists.IndexLive, we load the artists to display with the Tunez.Music.search_artists function. This has all of its load statements tucked away on the code interface function in case we want to reuse the whole search. To add loading the followed_by_me calculation for each artist, edit the options in the code interface in Tunez.Music:

[09/lib/tunez/music.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez%2Fmusic.ex)

```elixir
 resource Tunez.Music.Artist do
 # ...

 define :search_artists,
 action: :search,
 args: [:query],

 default_options: [
 load: [
 :followed_by_me, :album_count, :latest_album_year_released,
 :cover_image_url
 ]
 ]
 end
```

Then, we can render an icon in each artist_card of the liveview if the user follows the artist. We’ve included a small follow_icon component for this purpose:

[09/lib/tunez_web/live/artists/index_live.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez_web%2Flive%2Fartists%2Findex_live.ex)

```elixir
 <.link navigate={~p"/artists/#{@artist.id}"}>
 <.follow_icon :if={@artist.followed_by_me} />
 <.cover_image image={@artist.cover_image_url} />
 </.link>
```

Each of the artist album covers will now show a small star icon if you’ve followed them. Pretty nifty!

While we’re in here, why don’t we show how many followers each artist has?

### Showing Follower Counts for Each Artist

In the same way we wrote an aggregate to count albums for an artist, we can write an aggregate to count their followers as well. This will go in the aggregates block, in the Tunez.Music.Artist resource:

[09/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 aggregates do
 # ...

 count :follower_count, :follower_relationships
 end
```

We don’t need to know who the followers actually are, just how many there are, so we can use the join relationship in the aggregate. To show this new aggregate in the artist catalog, again edit the options in the code interface to load it when searching artists:

[09/lib/tunez/music.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez%2Fmusic.ex)

```elixir
 resource Tunez.Music.Artist do
 # ...

 define :search_artists,
 action: :search,
 args: [:query],
 default_options: [
 load: [
 :follower_count, :followed_by_me, :album_count,
 :latest_album_year_released, :cover_image_url
 ]
 ]
 end
```

And then use the aggregate value in the artist_card function component, in the Tunez.Artist.IndexLive liveview. We’ve provided a follower_count_display component, which will show friendly numbers like “12”, “3.6K”, or “22.1M”.

[09/lib/tunez_web/live/artists/index_live.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez_web%2Flive%2Fartists%2Findex_live.ex)

```elixir
 
 <.link ...>{@artist.name}</.link>
 <.follower_count_display count={@artist.follower_count} />
 
```

In your development, the Tunez app is probably not so exciting to view because you might only have one or two accounts that follow a handful of artists. In a real app though, as people sign up and follow artists, you might start seeing some popularity trends! Let’s surface some of those trends.

### Sorting Artists by Follow Status and Follower Count

In [*Sorting Based on Aggregate Data*](#f_0032.xhtml_ch03.album_count_aggregate), we learned how to use aggregates like album_count to sort search results. You can also sort by calculations—if we sort by the followed_by_me calculation, all of the user’s followed artists would show up first in the search results. We can also add an option for sorting by artist popularity!

The list of sort options is in the sort_options/0 function, in TunezWeb.Artists.IndexLive. We can add -followed_by_me and -follower_count to the end of the list, the - signifying to sort in descending order to get true/higher values first:

[09/lib/tunez_web/live/artists/index_live.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez_web%2Flive%2Fartists%2Findex_live.ex)

```elixir
 defp sort_options do
 [
 # ...
 {"latest album release", "--latest_album_year_released"},
 {"popularity", "-follower_count"},
 {"followed artists first", "-followed_by_me"}
 ]
 end
```

This sort value is used with the sort_input option for building queries, meant for untrusted user input. To signify that yes, we’ll allow these fields to be sorted on, they have to be marked public? true in the Tunez.Music.Artist resource:

[09/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/09%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 calculations do
 calculate :followed_by_me,
 :boolean,
 expr(exists(follower_relationships, follower_id == ^actor(:id))) do
 public? true
 end
 end

 aggregates do
 # ...

 count :follower_count, :follower_relationships do
 public? true
 end
 end
```

And this works great! Let’s take a minute to think about what we’ve built here.

Our catalog displays a lot of different information—each of our calculations/aggregates would have to be written as a separate Ecto subquery that could be both selected and possibly sorted on. We’d also likely need a separate library like Flop to do a lot of the heavy lifting.

But with Ash, we’ve been working at a higher level of abstraction. We’ve defined relationships between our resources, and we got all this extra functionality basically for free, using standard Ash features like calculations and aggregates. It’s pretty amazing!

Now that we know which artists a user follows, we can move on to what we really want to build—a real-time notification system!

Footnotes

<https://hexdocs.pm/ash/relationships.html#many-to-many>

<https://hexdocs.pm/ash/relationships.html#many-to-many>

<https://hexdocs.pm/ash/dsl-ash-resource.html#relationships-many_to_many-destination_attribute_on_join_resource>

<https://hexdocs.pm/ash/expressions.html#sub-expressions>

<https://hexdocs.pm/ash/expressions.html#templates>

<https://hexdocs.pm/ash/calculations.html#arguments-in-calculations>

<https://hexdocs.pm/ash/dsl-ash-resource.html#actions-create-argument-constraints>

<https://ash-project.github.io/ash/code-interfaces.html#customizing-the-generated-function>

<https://hexdocs.pm/ash/Ash.Resource.Change.Builtins.html#relate_actor/2>

<https://hexdocs.pm/ash/dsl-ash-resource.html#code_interface-define-require_reference?>

<https://hexdocs.pm/ash/dsl-ash-domain.html#resources-resource-define-get_by>

<https://hexdocs.pm/flop>

Copyright © 2025, The Pragmatic Bookshelf.
