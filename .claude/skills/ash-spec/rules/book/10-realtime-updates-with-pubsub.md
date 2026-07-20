# 10. Delivering Real-Time Updates with PubSub

##  Chapter 10 Delivering Real-Time Updates with PubSub

In the last chapter, we did a lot of the setup work for building our notification system—we now know who each user’s favorite artists are. We also used that information in some cool ways, such as sorting artists by popularity. There was a lot of bang for our follower buck! And now we can build out the notification functionality.

## Notifying Users About New Albums

The web app currently has a notification bell in the top menu for authenticated users, but there have never been any notifications to display … until now. Our end goal here is that users will receive notifications when new albums are added for the artists they follow. These notifications should be persisted and stay until the user clicks on them.

To do this, we’ll need a new resource representing a notification message. In Tunez our notifications will only ever be for showing new albums to users, so the resource can be pretty simple—it will only need to store who to show the notification to and the album to show the notification for.

### Creating the Notification Resource

Like our ArtistFollower resource, this new Notification resource crosses domain boundaries in linking users in the Tunez.Accounts domain and albums in the Tunez.Music domain. Notifications are pretty personalized though, and “feel” closer to users, so we’ll put the new resource in the Tunez.Accounts domain.

First, generate a new empty resource:

```elixir
 $ mix  ash.gen.resource  Tunez.Accounts.Notification  --extend  postgres
```

And then add the attributes and relationships we want to store:

[10/lib/tunez/accounts/notification.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Faccounts%2Fnotification.ex)

```elixir
 postgres do
 # ...

 references do
 reference :user, index?: true, on_delete: :delete
 reference :album, on_delete: :delete
 end
 end

 attributes do
 uuid_primary_key :id

 create_timestamp :inserted_at
 end

 relationships do
 belongs_to :user, Tunez.Accounts.User do
 allow_nil? false
 end

 belongs_to :album, Tunez.Music.Album do
 allow_nil? false
 end
 end
```

We’ve included an id attribute because we’ll be wanting to dismiss/delete individual notifications when they’re clicked on, as well as an inserted_at timestamp so we can show how long ago the notifications were generated. Because the notifications should be deleted if either the user or the album is deleted, we’ve also configured the database references for the relationships to be on_delete: :delete.

Generate a migration to create the resource in the database, and run it:

```elixir
 $ mix  ash.codegen  create_notifications
 $ mix  ash.migrate
```

### Creating Notifications on Demand

The Notification resource is all set up, so now we can turn to creating notifications when an album is created to let the followers know about it. We can do this with a change, in the Tunez.Music.Album resource. It’s a side effect of creating an album, and we want the change to run whenever any create-type action is called, so we’ll add the change as a global change in the changes block.

We’ll tuck all of the logic away in a separate change module, so it’s a one-liner to add the new change to the Tunez.Music.Album resource:

[10/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 changes do
 change Tunez.Accounts.Changes.SendNewAlbumNotifications, on: [:create]
 # ...
```

The Tunez.Accounts.Changes.SendNewAlbumNotifications module doesn’t exist yet, but we know that it should be a module that uses Ash.Resource.Change, and defines a change/3 callback with the code to run.

[10/lib/tunez/accounts/changes/send_new_album_notifications.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Faccounts%2Fchanges%2Fsend_new_album_notifications.ex)

```elixir
 defmodule Tunez.Accounts.Changes.SendNewAlbumNotifications do
 use Ash.Resource.Change

 @impl true
 def change(changeset, _opts, _context) do
 # Create notifications here!
 changeset
 end
 end
```

Because it’s included in actions in the Album resource, the changeset will have the details of the album being created, including the artist_id. We can use that ID to fetch the artist and all of its followers, and then use a bulk action to create a notification for each follower.

## Running Actions in Bulk

We briefly talked about bulk actions when we saw a surprising BulkResult while unfollowing artists, but now we’re intentionally going to write one.

Imagine that Tunez is super popular, and one artist now has thousands or even tens of thousands of followers. If they release a new album, our SendNewAlbumNotifications change module would be responsible for creating tens of thousands of Notification records in the database. We could do that one at a time, iterating over the followers and calling a create action for each, but that would be really inefficient.

Instead, we can call the create action once, with a list of records to be created. Ash will run all of the pre-database logic, such as validations and changes, for each item in the list, but then it will intelligently batch the insert of multiple records into as few database queries as possible.

Any action can be made into a bulk action by changing what data is passed to the action, so we can test bulk behavior with our existing actions.

### Testing Artist Bulk Create

We know how to create one record by calling either a code interface function or Ash.create.

```elixir
 iex(1)> # user is a loaded record with role = :admin
 iex(2)> Tunez.Music.create_artist(%{name: "New Artist"}, actor: user)
 INSERT INTO "artists" (fields) VALUES ($1,$2,$3,$4,$5,$6,$7) RETURNING
 fields [data]
 {:ok, #Tunez.Music.Artist<...>}
```

We can use the same code to run bulk actions by changing what we pass in. Instead of a single map, we can call the code interface with a list of maps.

```elixir
 iex(3)> data = [%{name: "New Artist 1"}, %{name: "New Artist 2"}]
 [...]
 iex(4)> Tunez.Music.create_artist(data, actor: user)
 INSERT INTO "artists" (fields) VALUES ($1,$2,$3,$4,$5,$6,$7),
 ($8,$9,$10,$11,$12,$13,$14) RETURNING fields [data for both records]
 %Ash.BulkResult{
 status: :success, errors: [], records: nil,
 notifications: nil, error_count: 0
 }
```

Boom, two records are inserted with a single database query.

If you want to be explicit about running actions as bulk actions, Ash has functions like Ash.bulk_create that can only be run with lists of data. These are what we’ve used in the seed files for Tunez, in priv/repo/seeds/.

```elixir
 iex(5)> Ash.bulk_create(data, Tunez.Music.Artist, :create, actor: user)
 %Ash.BulkResult{
 status: :success, errors: [], records: nil,
 notifications: nil, error_count: 0
 }
```

By default, you don’t get a lot of information back in a bulk result, not even the records being created or updated. This is for performance reasons—if you’re inserting a lot of data, it’s a lot of work to get the results back from the database, build the structs, and return them to you! You’ll get the errors if any occurred, but if the bulk result has the status :success, then you can safely assume that all of the records were successfully created.

The default behavior can be customized via any of the options listed for Ash.bulk_create (or bulk_update or bulk_destroy). These same options, such as return_records? to actually get the created/updated records back, can also be used for code interface functions by including them under the bulk_options option key.

```elixir
 iex(11)> Ash.bulk_create([%{name: "Test"}], Tunez.Music.Artist, :create,
 actor: user, return_records?: true)
 %Ash.BulkResult{status: :success, records: [#Tunez.Music.Artist<...>], ...}

 iex(12)> Tunez.Music.create_artist([%{name: "Test"}], actor: user,
 bulk_options: [return_records?: true])
 %Ash.BulkResult{status: :success, records: [#Tunez.Music.Artist<...>], ...}
```

Bulk actions are powerful and let you get things done efficiently. They’ll speed up what we want to do—inserting possibly many notifications for users about new albums.

### Back to Album Notifications

Now that we have a grip on bulk actions, we can write one in our SendNewAlbumNotifications change module.

We’ll use an after_action hook as part of the change function to ensure we only create notifications once, after the album is successfully created. The callback in the hook has access to the newly created album, so we can use it to load up all of the artist’s followers and then build maps of data to bulk create.

[10/lib/tunez/accounts/changes/send_new_album_notifications.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Faccounts%2Fchanges%2Fsend_new_album_notifications.ex)

```elixir
 def change(changeset, _opts, _context) do
 Ash.Changeset.after_action(changeset, fn _changeset, album ->
 album = Ash.load!(album, artist: [:follower_relationships])

 album.artist.follower_relationships
 |> Enum.map(fn %{follower_id: follower_id} ->
 %{album_id: album.id, user_id: follower_id}
 end)
 |> Ash.bulk_create!(Tunez.Accounts.Notification, :create)

 {:ok, album}
 end)
 end
```

The after_action callback can return either an {:ok, album} tuple or an {:error, changeset} tuple. If it returns an error tuple, the record (in this case, the album) won’t be created after all—the database transaction will be rolled back, and the whole action will return the changeset with the error.

Before you can test out the new code, we need to define the :create action on the Tunez.Accounts.Notification resource! The bulk action will try to call it, but then raise an error because the action doesn’t exist. The action will be pretty simple: the map of data contains the two foreign keys, and they can be accepted directly:

[10/lib/tunez/accounts/notification.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Faccounts%2Fnotification.ex)

```elixir
 actions do
 create :create do
 accept [:user_id, :album_id]
 end
 end
```

Now that we have actions on the resource, we should also add policies for it. For something like this, which will only ever be done as a system action and never be called from outside the domain model, we can forbid it from all access.

[10/lib/tunez/accounts/notification.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Faccounts%2Fnotification.ex)

```elixir
 defmodule Tunez.Accounts.Notification do
 use Ash.Resource,
 # ...
 authorizers: [Ash.Policy.Authorizer]

 policies do
 policy action(:create) do
 forbid_if always()
 end
 end

 # ...
```

Our internal SendNewAlbumNotifications module can still call it though, so we’ll bypass that authorization check there.

[10/lib/tunez/accounts/changes/send_new_album_notifications.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Faccounts%2Fchanges%2Fsend_new_album_notifications.ex)

```elixir
 album.artist.follower_relationships
 |> Enum.map(fn %{follower_id: follower_id} ->
 %{album_id: album.id, user_id: follower_id}
 end)
 |> Ash.bulk_create!(Tunez.Accounts.Notification, :create,
 authorize?: false
 )
```

Now you can test out the new code! If you follow an artist in your Tunez app and then create a new album for that artist, you should see a new notification being created in the server logs when you save the album:

```elixir
 [debug] HANDLE EVENT "save" in TunezWeb.Albums.FormLive
 Parameters: %{"form" => %{"cover_image_url" => "", "name" => "Test Album
 Name", "year_released" => "2025"}}
 INSERT INTO "albums" (fields) VALUES (values) RETURNING fields
 [album_uuid, "Test Album Name", now, now, artist_uuid, nil,
 creator_uuid, creator_uuid, 2025]
 queries to load the album's artist's followers
 INSERT INTO "notifications" ("id","album_id","inserted_at","user_id") VALUES
 ($1,$2,$3,$4) [uuid, album_uuid, now, user_uuid]
```

If you have multiple users in your database that all follow that artist, you may even see multiple notifications being created at once!

#### Optimizing Big Queries with Streams

We can go even further with improving the after_action callback in the SendNewAlbumNotifications change module. We’re efficiently inserting all the notifications we create using a bulk action, but we still have to load all of the follower relationships from the data layer first. For a popular artist with a lot of followers, this could be pretty slow and take up a lot of memory.

We can turn to streaming the data from the data layer—fetching the follower data in batches, processing each batch, and then using the bulk create to insert all the notifications. For larger datasets, it’s significantly more memory-efficient than loading all the records at once because Elixir and Ash don’t have to keep track of all the data.

All read actions can return their results via streaming, so instead of using Ash.load to load the relationship data we need, we’ll create a new read action to run directly. We’re loading follower relationships, which are Tunez.Music.ArtistFollower records, so the new action will go on the ArtistFollower resource to read all records for a given artist ID.

[10/lib/tunez/music/artist_follower.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Fmusic%2Fartist_follower.ex)

```elixir
 read :for_artist do
 argument :artist_id, :uuid do
 allow_nil? false
 end

 filter expr(artist_id == ^arg(:artist_id))
 pagination keyset?: true, required?: false
 end
```

The action accepts an artist_id to fetch follower relationships for and uses it in a filter. The action has to support pagination, for streaming—but we can mark it as required? false so we don’t have to use it.

Set up a code interface function for the action in the Tunez.Music domain:

[10/lib/tunez/music.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Fmusic.ex)

```elixir
 resource Tunez.Music.ArtistFollower do
 # ...

 define :followers_for_artist, action: :for_artist, args: [:artist_id]
 end
```

Then we can rewrite the after_action callback to call our new action, with the stream?: true option for streaming:

[10/lib/tunez/accounts/changes/send_new_album_notifications.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Faccounts%2Fchanges%2Fsend_new_album_notifications.ex)

```elixir
 def change(changeset, _opts, _context) do
 changeset
 |> Ash.Changeset.after_action(fn _changeset, album ->
 Tunez.Music.followers_for_artist!(album.artist_id, stream?: true)
 |> Stream.map(fn %{follower_id: follower_id} ->
 %{album_id: album.id, user_id: follower_id}
 end)
 |> Ash.bulk_create!(Tunez.Accounts.Notification, :create,
 authorize?: false
 )

 {:ok, album}
 end)
 end
```

The code doesn’t look a whole lot different! Instead of loading the data with Ash.load and then iterating over it with Enum.map/2, we call our new Tunez.Music.followers_for_artist function and then iterate over it with Stream.map/2. We don’t have to change the bulk create—it can already work with streams. This new version should run in roughly the same amount of time, but be a lot kinder on your server’s memory usage.

> Because Ash uses Ecto under the hood, your database queries are subject to Ecto’s limits, such as the query timeout[189] configuration. By default, an Ash bulk create can take at most 15 seconds. That’s enough time to process a lot of records, but if you need more time, you can either extend the timeout or implement the functionality differently.
> For example, you could create a generic action[190] that runs an SQL query to insert the notifications records directly.

Now that notifications are being created, we should update the UI of the web app to show them to users. We’ll look at this in two parts—loading and showing the notifications on page load, and then updating them in real time as new notifications are sent.

## Showing Notifications to Users

The notification bell in the main navigation bar is implemented in its own LiveView module, rendered from the user_info function component in the TunezWeb.Layouts module:

[10/lib/tunez_web/components/layouts.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez_web%2Fcomponents%2Flayouts.ex)

```elixir
 <%= if @current_user do %>
 {live_render(@socket, TunezWeb.NotificationsLive, sticky: true,
 id: :notifications_container)}
 <% # ... %>
```

This NotificationsLive liveview is marked as sticky, meaning it won’t need to reload as we navigate around and use the app. It’ll stay open on the server, alongside the page liveview we’re currently using such as TunezWeb.Artists.IndexLive, and each new page liveview will connect to it to render it.

Inside TunezWeb.NotificationsLive, in lib/tunez_web/live/notifications_live.ex, there’s a whole template set up to render notifications. But the notifications are currently hardcoded as an empty list in the mount/3 function.

To render the real notifications for the logged-in user, we need a read action on the Tunez.Accounts.Notification resource. From the outside, we might name the code interface function something like notifications_for_user, and call it like this:

[10/lib/tunez_web/live/notifications_live.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez_web%2Flive%2Fnotifications_live.ex)

```elixir
 def mount(_params, _session, socket) do
 notifications = Tunez.Accounts.notifications_for_user!(
 actor: socket.assigns.current_user
 )
 {:ok, assign(socket, notifications: notifications)}
 end
```

This code interface function then needs to be defined in the Tunez.Accounts domain module in lib/tunez/accounts.ex:

[10/lib/tunez/accounts.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Faccounts.ex)

```elixir
 resources do
 # ...

 resource Tunez.Accounts.Notification do
 define :notifications_for_user, action: :for_user
 end
 end
```

And then finally, the action can be added to the Tunez.Accounts.Notification resource!

[10/lib/tunez/accounts/notification.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Faccounts%2Fnotification.ex)

```elixir
 actions do
 # ...

 read :for_user do
 prepare build(load: [album: [:artist]], sort: [inserted_at: :desc])
 filter expr(user_id == ^actor(:id))
 end
 end
```

The read action includes a filter to only select notifications for the actor calling the action. We’ll also load all of the related data we need to render the notifications and sort them so that the latest notifications appear first.

We need to add a policy that covers the action, so who should be able to run it? Well, anyone. With the filtering in the action, any authenticated user should be able to run it, and they’ll only ever get back their own notifications. So we can use the built-in actor_present policy check again.

[10/lib/tunez/accounts/notification.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Faccounts%2Fnotification.ex)

```elixir
 policies do
 policy action(:for_user) do
 authorize_if actor_present()
 end

 # ...
 end
```

Everything looks all good, right? But refreshing the page will give a bit of a surprise—the NotificationsLive liveview doesn’t have the current_user stored in the socket! Why not?

### A Brief Detour into LiveView Process Shenanigans

This gotcha is caused by a quirk in how LiveView works, in particular, sticky child liveviews. When a liveview is initially created, it only has access to data stored in the session, and this is the same for both liveviews mounted in your router and any nested liveviews.

Most of the time, this doesn’t matter because we’re only rendering one liveview and being done with it. But in this case, it does. The page liveviews, such as TunezWeb.Artists.ShowLive, get the current user via an on_mount callback set up in your app’s router with ash_authentication_live_session. This callback will read the authentication token stored in the session, load the correct user record, and store it in socket.assigns.

So TunezWeb.NotificationsLive will need to load its own copy of the current user. We can use one of AshAuthenticationPhoenix’s helpers for this. When we installed it, it created the TunezWeb.LiveUserAuth module in our app, with some on_mount callbacks for us to use.

The on_mount(:current_user) callback is the one we’re after. It uses the same AshAuthenticationPhoenix functionality as ash_authentication_live_session to read the authentication token (which our liveview does have access to) and to load and assign the current user.

After all that explanation, the fix turns out to be one line of code—calling that on_mount callback at the top of the NotificationsLive liveview:

[10/lib/tunez_web/live/notifications_live.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez_web%2Flive%2Fnotifications_live.ex)

```elixir
 defmodule TunezWeb.NotificationsLive do
 use TunezWeb, :live_view

 on_mount {TunezWeb.LiveUserAuth, :current_user}

 def mount(_params, _session, socket) do
 # ...
```

|  |  |
|----|----|
|  | It is possible for parent and child liveviews to “share” assigns, but this is a performance optimization and shouldn’t be relied on. And it doesn’t work at all for sticky liveviews—these are totally de-coupled from their calling liveview. |

If you refresh your app to recompile the changes to NotificationsLive and re-initialize it, you should now see the notification (or notifications) you created earlier when testing SendNewAlbumNotifications! No one will be able to ignore that red pinging notification bell. Excellent.

### OK, Tell Me About That New Album … and Then Go Away

It’s great to know what new albums there are, and clicking on the notification will redirect to the details of the album on the artist profile. But the notification doesn’t disappear after clicking on it! That’s really annoying. If a user clicks on a notification, it should be dismissed (deleted).

Currently, if you click on a notification, it sends the “dismiss-notification” event to the NotificationsLive liveview via a JS.push. There’s an event handler set up to process that event, but it’s empty.

The notifications are all stored in the socket, so to process the notification that the user clicked on, we can find it based on its ID. Then, we need a new action on the Notification resource to actually dismiss it. The code is a little bit verbose here, but we can tidy it up when we make this liveview more real-time.

[10/lib/tunez_web/live/notifications_live.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez_web%2Flive%2Fnotifications_live.ex)

```elixir
 def handle_event("dismiss-notification", %{"id" => id}, socket) do
 notification = Enum.find(socket.assigns.notifications, &(&1.id == id))

 Tunez.Accounts.dismiss_notification(
 notification,
 actor: socket.assigns.current_user
 )

 notifications = Enum.reject(socket.assigns.notifications, &(&1.id == id))
 {:noreply, assign(socket, notifications: notifications)}
 end
```

The new action doesn’t have to be anything fancy—we only want to delete the notification. We could soft-delete the notification by setting a dismissed_at timestamp and then showing “read” notifications differently from “unread” ones, but for Tunez, a standard default destroy is fine.

[10/lib/tunez/accounts.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Faccounts.ex)

```elixir
 resources do
 # ...

 resource Tunez.Accounts.Notification do
 define :notifications_for_user, action: :for_user
 define :dismiss_notification, action: :destroy
 end
 end
```

[10/lib/tunez/accounts/notification.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Faccounts%2Fnotification.ex)

```elixir
 actions do
 defaults [:destroy]

 # ...
```

The destroy action needs authorization, so we can use the relates_to_user_via/2 built-in check to ensure that users can only dismiss their own notifications:

[10/lib/tunez/accounts/notification.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Faccounts%2Fnotification.ex)

```elixir
 policies do
 # ...

 policy action(:destroy) do
 authorize_if relates_to_actor_via(:user)
 end
 end
```

This works pretty well—when you click on a notification, you get to see the album details and the notification will disappear, along with the annoying red ping (if it was the only notification in the list).

There’s one thing left to do. At the moment, users will only get new notifications when they reload the page, due to our sticky liveview only fetching notifications in the mount/3 callback. They need to find out about new albums immediately! It’s a matter of internet street cred … I mean, life and death!!

## Updating Notifications in Real Time

For real-time goodness, our NotificationsLive liveview needs some way of finding out when new Notification records are created. For this, we can turn to a publish/subscribe mechanism, also known as pub/sub (or pubsub). The Notification resource will publish updates for every action that we set it up for, with a given topic name, and then the liveview can subscribe to that topic to receive the updates and update the page with the new notification details.

Phoenix has a pubsub adapter built into it for use with features like channels and presence. Ash also comes with a pubsub notifier that works with Phoenix’s pubsub (or any other pubsub) to let us set up systems that can respond to events in real time.

### Setting Up the Publish Mechanism

To enable pubsub broadcasting for notifications, we first need to configure it as a notifier in the Notification resource. Notifiers are a way to set up side effects for your actions, but only those really lightweight kinds of side effects where it’s not a big deal if an error occurs and it doesn’t go through. We call these kinds of side effects “at most once” side effects because that’s how often they will occur.

Pubsub is a perfect use case for this—if something goes wrong and a publish message is missed, that’s okay because it’s only an enhancement to get the data on the page a little bit quicker. The Notification record is still created in the database, and the user will see it when they reload the page.

To configure notifiers for a resource, add the notifiers option to use Ash.Resource:

[10/lib/tunez/accounts/notification.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Faccounts%2Fnotification.ex)

```elixir
 defmodule Tunez.Accounts.Notification do
 use Ash.Resource,
 otp_app: :tunez,
 domain: Tunez.Accounts,
 data_layer: AshPostgres.DataLayer,
 authorizers: [Ash.Policy.Authorizer],
 notifiers: [Ash.Notifier.PubSub]
```

Once that’s done, we can use the pub_sub DSL in the resource to enable publishing broadcasts whenever specific actions are run. Because we’re in a Phoenix app, our Phoenix Endpoint module (TunezWeb.Endpoint) will handle all pubsub functionality.

In our specific case, we want to broadcast a message whenever the create action is run. As we care about notifications on a per-user basis (like we implemented a notifications_for_user function), we’ll use a topic for messages that includes the :user_id topic template. Ash will replace this with the actual user ID that the notification is for.

[10/lib/tunez/accounts/notification.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Faccounts%2Fnotification.ex)

```elixir
 defmodule Tunez.Accounts.Notification do
 # ...

 pub_sub do
 prefix "notifications"
 module TunezWeb.Endpoint
 publish :create, [:user_id]
 end
```

This will broadcast messages with a topic like notifications:<user_id>, whenever a Notification is created. Awesome! How do we know if it’s working, though? Where do the messages go? Before we set up the subscriber, it would be great to be able to see what’s going on and if our messages are actually getting sent.

#### Debugging Pubsub Publishing

Pubsub can be tricky to get working properly because it feels like magic going on behind the scenes. To make it a bit easier, while building your pubsub setup, we’d strongly recommend enabling Ash’s pubsub debugging, which logs when messages are sent and their content.

You can do this with the following config in your config/dev.exs file:

[10/config/dev.exs](http://media.pragprog.com/titles/ldash/code/10%2Fconfig%2Fdev.exs)

```elixir
 config :ash, :pub_sub, debug?: true
```

Then, if you start an iex session and manually create a new Notification, you’ll be able to see the pubsub message being broadcast:

```elixir
 iex(1)> Ash.Changeset.for_action(Tunez.Accounts.Notification, :create,
 %{user_id: user_uuid, album_id: album_uuid})
 |> Ash.create!(authorize?: false)
 INSERT INTO "notifications" ...

 [debug] Broadcasting to topics ["notifications:user_uuid"] via
 TunezWeb.Endpoint.broadcast

 Notification:

 %Ash.Notifier.Notification{resource: Tunez.Accounts.Notification, domain:
 Tunez.Accounts, action: %Ash.Resource.Actions.Create{name: :create,
 primary?: true, description: nil, error_handler: nil, accept: ...
```

Ash has built an Ash.Notifier.Notification struct (not to be confused with a Tunez.Accounts.Notification!), and that’s what will be sent out in the broadcast.

If we try to generate pubsub messages in iex by creating a new album for an artist that has at least one follower, though, we won’t see the pubsub debug message printed:

```elixir
 iex(2)> Tunez.Music.create_album!(%{artist_id: artist_uuid,
 name: "New Album", year_released: 2022}, actor: user)
 INSERT INTO "albums" ("id","name","inserted_at","updated_at", ...
 SELECT query to load the artist followers
 INSERT INTO "notifications" ("id","album_id","inserted_at", ...
 %Tunez.Music.Album{...}
```

So we’ve done something in the create action of Tunez.Music.Album that’s preventing pubsub messages from being created or sent.

#### Putting Our Detective Caps On

A good place to start debugging would be where the Notifications are being created: in the SendNewAlbumNotifications module. It uses a bulk action to generate notifications for all of an artist’s followers at once. If we create notifications using a bulk action in iex, do we get pubsub messages sent?

```elixir
 iex(3)> Ash.bulk_create([%{user_id: user_uuid, album_id: album_id}],
 Tunez.Accounts.Notification, :create, authorize?: false)
 INSERT INTO "notifications" ("id","album_id","inserted_at","user_id") ...
 %Ash.BulkResult{notifications: nil, ...}
```

We don’t! Notifications aren’t generated by default for bulk actions, just like records aren’t returned, also for performance reasons. To configure a bulk action to generate and auto-send any notifications, you can use the notify? true option of Ash.bulk_create.

```elixir
 iex(4)> Ash.bulk_create([%{user_id: user_uuid, album_id: album_id}],
   Tunez.Accounts.Notification, :create, authorize?: false, notify?: true)
 INSERT INTO "notifications" ("id","user_id","album_id","inserted_at") ...
 [debug] Broadcasting to topics ["notifications:user_uuid"] via
 TunezWeb.Endpoint.broadcast

 Notification:

 %Ash.Notifier.Notification{resource: Tunez.Accounts.Notification, ...}

 %Ash.BulkResult{...}
```

Perfect! If we add this same option to our SendNewAlbumNotifications change function, Ash generates and sends notifications for us:

[10/lib/tunez/accounts/changes/send_new_album_notifications.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Faccounts%2Fchanges%2Fsend_new_album_notifications.ex)

```elixir
 def change(changeset, _opts, _context) do
 changeset
 |> Ash.Changeset.after_action(fn _changeset, album ->
 Tunez.Music.followers_for_artist!(album.artist_id, stream?: true)
 |> Stream.map(fn %{follower_id: follower_id} ->
 %{album_id: album.id, user_id: follower_id}
 end)
 |> Ash.bulk_create!(Tunez.Accounts.Notification, :create,
 authorize?: false, notify?: true
 )

 {:ok, album}
 end)
 end
```

After making that change, if you recompile (or restart iex), you’ll see the notification being sent when creating an album.

```elixir
 iex(5)> Tunez.Music.create_album!(%{artist_id: artist_uuid,
 name: "Son Of New Album", year_released: 2025}, actor: user)
 INSERT INTO "albums" ("id","name","inserted_at","updated_at", ...
 SELECT query to load the artist followers
 INSERT INTO "notifications" ("id","album_id","inserted_at","user_id") ...
 [debug] Broadcasting to topics ["notifications:user_uuid"] via
 TunezWeb.Endpoint.broadcast

 Notification:

 %Ash.Notifier.Notification{resource: Tunez.Accounts.Notification, domain: ...}

 %Tunez.Music.Album{...}
```

If we restart our web app (to get the updated debug config) and then create an album in the UI for an artist that has a follower, we’ll also see the notification being sent in the web server logs. Perfect.

#### Limiting Data Sent Within Notifications

These Ash.Notifier.Notification structs are pretty big—there’s a lot of information in there about the action that was called, the changeset that was built, the record that was created, the actor, and so on. All of that information will be broadcast as part of the pubsub message, which can be a bit unwieldy.

It can also be a security issue. Because any liveview, with any authenticated user, can subscribe to a pubsub topic and receive broadcasts, we don’t have any way of restricting the data in the notification to stop the recipient from seeing data they aren’t authorized to see.

To prevent issues, Ash lets you define a transform function for your pubsub notifications. Each publish or publish_all line can have its own transform function, or you can define one for the entire pub_sub block. This function receives the full Ash.Notifier.Notification struct, and lets you either strip data from it, or rebuild it in a way that makes sense for your app.

|  |  |
|----|----|
|  | The behavior of pubsub transform functions may change in Ash 4.0—see this GitHub issue for details. |

Our planned implementation for our NotificationsLive liveview will be pretty simple. If it gets a message that there’s a new notification, it will reload the user’s notification list. So the broadcast we send doesn’t need many details in it; a subset of data from the created Tunez.Accounts.Notification will be sufficient.

[10/lib/tunez/accounts/notification.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Faccounts%2Fnotification.ex)

```elixir
 pub_sub do
 prefix "notifications"
 module TunezWeb.Endpoint

 transform fn notification ->
 Map.take(notification.data, [:id, :user_id, :album_id])
 end

 publish :create, [:user_id]
 end
```

Configuring a transform won’t change the debug information printed in the server logs, but it will change the data in the actual broadcast message.

### Setting Up the Subscribe Mechanism

Compared to the publish side of the mechanism, subscription is a lot more straightforward! Ash doesn’t provide any helpers to handle subscribing to pubsub topics or processing the messages—it doesn’t need to, they’re none of its concern. Ash’s responsibilities end when the messages are sent, and it’s our liveview’s responsibility to listen and react.

To start listening for the pubsub messages in our NotificationsLive liveview, update the mount/3 function and subscribe to the topic we defined for our messages:

[10/lib/tunez_web/live/notifications_live.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez_web%2Flive%2Fnotifications_live.ex)

```elixir
 def mount(_params, _session, socket) do
 # ...

 if connected?(socket) do
 "notifications:#{socket.assigns.current_user.id}"
 |> TunezWeb.Endpoint.subscribe()
 end

 {:ok, assign(socket, notifications: notifications)}
 end
```

The endpoint module will then send a message to the liveview when a pubsub broadcast is received, which has to be received with a handle_info callback. We don’t have any handle_info callbacks set up, but we can add a simple one that will reload the list of notifications when any messages are received:

[10/lib/tunez_web/live/notifications_live.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez_web%2Flive%2Fnotifications_live.ex)

```elixir
 def handle_info(%{topic: "notifications:" <> _}, socket) do
 notifications = Tunez.Accounts.notifications_for_user!(
 actor: socket.assigns.current_user
 )

 {:noreply, assign(socket, notifications: notifications)}
 end
```

We’ll do some pattern matching to make sure we’re getting the right type of messages, but that’s it. If we were going to receive more than one type of message, or we needed to do something more involved with the specific message we received, the logic here would have to be a bit more complex. But for Tunez, where we’re only receiving one type of message and don’t expect users to have a million notifications at the same time, it’s fine!

And if you inspect and print out the received pubsub message, you’ll see it’s very trim, taut, and terrific:

```elixir
 [(tunez 0.1.0) lib/tunez_web/live/notifications_live.ex:67:
 TunezWeb.NotificationsLive.handle_info/2]
 message #=> %Phoenix.Socket.Broadcast{
 topic: "notifications:user_uuid",
 event: "create",
 payload: %{id: uuid, album_id: album_uuid, user_id: user_uuid}
 }
```

### Deleting Notifications

There’s one last wrench to throw in the real-time works—what happens when a notification is deleted? This could happen if you have Tunez open on both your computer and your phone, and you click a notification on one device—the other would still show that you have a notification to view.

Or a new album could be added but then deleted. The Tunez.Accounts.Notification resource is set up with a database reference to delete notifications if the album is deleted, but users will still see that notification until their notification list is refreshed.

Let’s look at how we can address these issues for a smooth experience.

#### Broadcasting Delete Messages

Similar to how we set up pubsub for the Tunez.Accounts.Notification create action, we can also use pubsub to broadcast calls to the destroy action. This will resolve one of our issues when a user has the app open in two places at once. Deleting a notification on one device will send a pubsub message to the other.

[10/lib/tunez/accounts/notification.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Faccounts%2Fnotification.ex)

```elixir
 pub_sub do
 # ...

 publish :create, [:user_id]
 publish :destroy, [:user_id]
 end
```

Because we’ve used the exact same pubsub topic, notifications:<uuid>, we don’t even need to change our NotificationsLive implementation. Receiving a destroy message should behave exactly the same as a create message, and reload the list of notifications.

We can clean up a little bit of our “dismiss-notification” event handler logic in NotificationsLive though. We don’t need to manually remove the dismissed notification from the list when a user clicks on one—the pubsub process will handle that for us!

[10/lib/tunez_web/live/notifications_live.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez_web%2Flive%2Fnotifications_live.ex)

```elixir
 def handle_event("dismiss-notification", %{"id" => id}, socket) do
 notification = Enum.find(socket.assigns.notifications, &(&1.id == id))

 Tunez.Accounts.dismiss_notification(
 notification,
 actor: socket.assigns.current_user
 )

 {:noreply, socket}
 end
```

This won’t resolve our second issue, though. Because the database reference handles the deletion entirely within the database, our app doesn’t know that it’s even taken place and can’t notify anyone!

#### Cascading Deletes in Code

When we covered [deleting related resources,](#f_0025.xhtml_ch02.cascade_delete), we discussed two approaches—specifying the ON DELETE behavior on the database reference to either do the delete within the database or do it in code by using a cascade_destroy for the related records.

So far, we’ve always opted for the database method because it’s much more efficient. But this is a case where we have business logic to run (sending pubsub messages) when we delete the related records, so we’ll have to switch to the less performant approach.

To get rid of the automatic deletion of notifications when their related album is deleted, remove the on_delete: :delete from the database reference to :album in the Tunez.Accounts.Notification resource.

[10/lib/tunez/accounts/notification.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Faccounts%2Fnotification.ex)

```elixir
 postgres do
 # ...

 references do
 reference :user, index?: true, on_delete: :delete
 reference :album
 end
 end
```

Generate a migration for the database change, and then run it:

```elixir
 $ mix  ash.codegen  remove_notification_album_cascade_delete
 $ mix  ash.migrate
```

This breaks the ability to delete albums that have any related notifications waiting to be seen, but we’ll fix that now!

We need to manually destroy related notifications when the destroy action of the Tunez.Music.Album resource is called. At the moment, that action is defined as a default action. And we don’t even have a relationship defined between albums and notifications! We’ll have to add that first; it should be a has_many relationship as there can be many notifications for different users, all for the same album:

[10/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 relationships do
 # ...

 has_many :notifications, Tunez.Accounts.Notification
 end
```

Then we can write a new destroy action, removing the default implementation from the defaults list:

[10/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 actions do
 defaults [:read]

 destroy :destroy do
 primary? true
 change cascade_destroy(:notifications, return_notifications?: true,
 after_action?: false)
 end

 # ...
```

This new action uses the cascade_destroy built-in change to read the related Tunez notifications for an album and call the default destroy action for them all as a bulk action (in a before_action hook, by declaring after_action?: false, see the [sidebar](#f_0069.xhtml_sidebar.ch10.1)). It looks kind of weird because we also need to configure cascade_destroy to get the Ash notifications back for pubsub broadcast, with return_notifications?: true. This is similar to when we bulk-created Tunez notifications in SendNewAlbumNotifications. So many notifications flying around!

before_action or after_action?

cascade_destroy works by calling a bulk destroy action for the related resources, either in an after_action function hook (the default) or a before_action function hook. Which one you choose determines the order of the destroys: which should come first, deleting the main resource (the album) or deleting the related resources (the notifications)?

When using an after_action hook, the main resource will be deleted first (and then the related records, in the hook). But we know that you can’t delete a record that has references pointing to it, it generates a foreign key violation error—that’s why we used ON DELETE CASCADE in the first place! This is when we’d need to use the deferrable option on the database reference, as mentioned in the cascade_destroy documentation. deferrable: :initially will defer that foreign key check until the end of the transaction. As long as all the related records are also deleted before the end of the transaction, everything is A-OK.

This won’t suit all cases, though. We haven’t looked at policies yet, but as we’ll now be deleting notifications via calling a destroy action, we’ll have to update the policies for that action to include this new use case. What if the rules we want to encode depend on the main resource? If the main resource has already been deleted, the policies might not behave as intended.

If we switch our cascade_destroy to use a before_action instead by specifying after_action?: false, then all of these issues will go away!

That last paragraph also hints at another last change we need to make—we need to read the related notifications before we can delete them. Our Tunez.Accounts.Notification resource doesn’t have any basic read action, so we can quickly add one.

[10/lib/tunez/accounts/notification.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Faccounts%2Fnotification.ex)

```elixir
 actions do
 defaults [:read, :destroy]
 # ...
```

The read action also needs an authorization policy, or it won’t be allowed to run. Who should be allowed to access this action? The only users who should be bulk-managing notifications like this, to read all notifications for an album to delete them, are the users who are deleting the album.

Our policies around album deletion currently look like this:

[10/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 policies do
 bypass actor_attribute_equals(:role, :admin) do
 authorize_if always()
 end

 # ...

 policy action_type([:update, :destroy]) do
 authorize_if expr(
 ^actor(:role) == :editor and created_by_id == ^actor(:id)
 )
 end
 end
```

You could copy and paste these policy checks into policies for the read and destroy actions for Notifications, but if the logic changes, we’d have to remember to update it in all three places. Instead, we’ll extract the logic into a calculation, so we can reuse it across different resources.

#### Calculations: Not Just for User-Facing Data

There are probably some confused noises being made right now. So far, we’ve seen calculations primarily for presenting data in a more user-friendly way—formatting seconds as minutes and seconds, or telling users how long ago their favorite albums came out. (I’m sorry, Master of Puppets is how old?) But there’s nothing saying that’s all they can be used for.

Extracting reusable expressions is a perfectly valid use of a calculation. We can extract the logic of the Album policy check into a calculation, which we’ll call can_manage_album?:

[10/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 calculations do
 # ...

 calculate :can_manage_album?,
 :boolean,
 expr(
 ^actor(:role) == :admin or
 (^actor(:role) == :editor and created_by_id == ^actor(:id))
 )
 end
```

We can then update the Album policy to use the new calculation:

[10/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 policy action_type([:update, :destroy]) do
 authorize_if expr(can_manage_album?)
 end
```

Ash will automatically load the calculation when the policy is run. We have existing tests for this policy in test/tunez/music/album_test.exs, so you can run them to double-check that the functionality still behaves as expected.

Now we can write the policies for the Notification resource—the read and destroy actions can be run if the album can be managed by the current user. This is a second policy check for the destroy action, so it can go in the same policy. If either of the checks passes, then the action will be authorized.

[10/lib/tunez/accounts/notification.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Faccounts%2Fnotification.ex)

```elixir
 policies do
 policy action(:read) do
 authorize_if expr(album.can_manage_album?)
 end

 # ...

 policy action(:destroy) do
 authorize_if expr(album.can_manage_album?)
 authorize_if relates_to_actor_via(:user)
 end
```

This is why we couldn’t use an after_action when calling cascade_destroy. We’d first be deleting the album, and then the notifications, but the authorization policy for notifications depends on the deleted album! Oops.

And now we can delete albums again! Try following an artist, creating an album for them, seeing the notification, and then deleting the album. The notification will disappear! Magic!

#### I Have Some Bad News for You, Though …

We’ve successfully solved the issue around deleting albums but introduced another problem. Now we can’t delete artists that have albums that have notifications, for the same reason we couldn’t delete albums that had notifications!

These kinds of changes can ripple through an app, and unfortunately, there’s not much that can be done about it. We can either keep going and add cascade_destroy for albums when deleting artists, or we can undo our cascade_destroy changes for albums and accept that users may occasionally see phantom notifications for albums that have been deleted.

We’ll opt to add cascade_destroy for albums in Tunez, but we’ll do it super quickly. We’ll first update the reference from albums back to artists:

[10/lib/tunez/music/album.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Fmusic%2Falbum.ex)

```elixir
 defmodule Tunez.Music.Album do
 # ...

 postgres do
 # ...

 references do
 reference :artist, index?: true
 end
 end
```

Then, we’ll replace the default destroy action with a new one to call cascade_destroy:

[10/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 defmodule Tunez.Music.Artist do
 # ...

 actions do
 defaults [:create, :read]

 destroy :destroy do
 primary? true
 change cascade_destroy(:albums, return_notifications?: true,
 after_action?: false)
 end

 # ...
```

And finally, we’ll generate and run the migration to update the database reference:

```elixir
 $ mix  ash.codegen  remove_album_artist_cascade_delete
 $ mix  ash.migrate
```

And now we can delete artists again. Phew!

There are a few tests in the Tunez repo that cover this behavior to ensure that it works as expected. You can enable them in test/tunez/music/artist_test.exs and test/tunez/music/album_test.exs.

## We Need to Talk About Atomics

There’s one last topic we want to cover before we finish up—it’s not related to what we’ve covered so far in this chapter, but we think it’s important. We’ve discussed little snippets about atomics all throughout this book but haven’t gone into much detail beyond the fact that they’re used for running logic in the data layer, instead of in our app. What does that actually mean, though?

Imagine we wrote a feature that counts the number of followers an artist has and manually updates the number whenever someone follows or unfollows them. It might look something like this, in the Tunez.Music.Artist resource:

```elixir
 update :follow do
 change fn changeset, _opts ->
 count = Ash.Changeset.get_attribute(changeset, :follower_count)
 Ash.Changeset.change_attribute(changeset, :follower_count, count + 1)
 end
 end
```

(Obviously, we’d never write this code because we know that change modules are much better, but we’re doing it here for demonstration purposes.)

You’re browsing Tunez, and you see your favorite artist. Hey, they have 472 followers! Not bad! But you haven’t followed them yet. Better do that now.

While you’re reading through their album list and making sure there are no typos, three other users follow that artist. They now have 475 followers! But when you click the star icon to follow them, what happens? The follower count goes down to 473! Wait, what?

This action isn’t atomic—it runs in code and uses the data that’s loaded in memory. When you loaded the artist record, the value was at 472, so the follow action dutifully added one more and wrote the value 473 to the data layer. Oops.

What you actually meant in the action was “add one to the current count, whatever it is,” and the data layer is the source of truth for what the count is right now. Not when you loaded the page, but right now. When we say “run the change logic in the data layer,” it’s instructing the data layer to increment the current value, not store an arbitrary new value that we calculated elsewhere. In SQL, it’s this:

```elixir
 -- Not atomic!
 UPDATE artists SET follower_count = 473 WHERE id = uuid;

 -- Atomic! :)
 UPDATE artists SET follower_count = follower_count + 1 WHERE id = uuid;
```

Basically, if we’re using data from the resource in a change function/module, we really want to be doing it atomically, or consciously decide not to do so.

### What Does This Mean for Tunez?

When we wrote code to [store previous names for an artist,](#f_0026.xhtml_ch02.atomics_first_mention), we used both the name and previous_names attributes that existed when we loaded the Tunez.Music.Artist record. This creates a race condition like our follower_count example—if two users edited the same artist’s name at the same time, the name that the first user used wouldn’t be added to the second user’s submitted previous_names, it would be lost unless we rewrote the logic of the change to be atomic.

It’s the same thing with using manage_relationship [when updating records,](#f_0057.xhtml_ch08.manage_relationship_atomic): Ash currently needs to use the existing records to be able to figure out what data needs to be created, updated, or deleted, so this can’t be run atomically.

Our final case of the [MinutesToSeconds change module,](#f_0059.xhtml_ch08.minutes_to_seconds), can be made atomic, but perhaps not in the way you think. The module doesn’t use data from the Track record when it was loaded—it only uses data that was submitted from the Album form. So it’s already atomic, but we need to tell Ash that the change can be used that way.

To enable atomic behavior for a change module, we need to implement the atomic/3 callback in the Tunez.Music.Changes.MinutesToSeconds module. It doesn’t need to do anything fancy, it can call the existing change/3 function, and return the changeset in an :ok tuple:

```elixir
 defmodule Tunez.Music.Changes.MinutesToSeconds do
 # ...

 @impl true
 def atomic(changeset, opts, context) do
 {:ok, change(changeset, opts, context)}
 end
 end
```

We might think twice in this case about removing require_atomic? false from the update action of the Tunez.Music.Track resource, though. Because this action is called as part of a manage_relationship function call, Ash will try to atomically update each track just in case the data in memory is out of date, leading to a classic n+1 query problem.

### What if We Really Wanted to Store the Follower Count, Though?

Sometimes you really do need incrementing fields. Or maybe our trade-off for UpdatePreviousNames is unacceptable, and it has to be atomic. For cases like this, there are a few different approaches.

Ash provides an atomic_update/3 built-in change function, that can be used for cases like the incrementing follower count. Using atomic_update, it could be written like this:

```elixir
 update :follow do
 change atomic_update(:follower_count, expr(follower_count + 1))
 end
```

This uses an expression to define what needs to change, and that’s something the data layer knows how to deal with. As a bonus, it’s even shorter and easier to read than the inline change version!

For more complex logic, there’s the atomic/3 callback that can be implemented in change modules. We’ve seen how we can use it to mark known good changes as atomic, but it can do a whole lot more. It has a pretty intimidating typespec—it can return a lot of different things. We’ve seen one example already: an :ok tuple means “this changeset is already atomic, nothing else needs to be done.”

If a change can be done atomically, we can return an :atomic tuple with :atomic as the first element and a map of atomic changes to make as the second element. The follower_count example could be written like this if we wanted to extract it to a module for reuse:

```elixir
 @impl true
 def atomic(_changeset, _opts, _context) do
 {:atomic, %{follower_count: expr(follower_count + 1)}}
 end
```

Ash actually has an increment change built-in, and you can see exactly how it’s implemented. The atomic version can’t be written as a single expression, due to the overflow_limit option, but it always returns a single atomic tuple.

It does have one thing we haven’t seen before—the use of the atomic_ref function. This will get a reference to the attribute, after any other changes from our action have been made, ready to use in an expression. We’ll see what this really means when we rewrite the UpdatePreviousNames change.

### Rewriting UpdatePreviousNames to Be Atomic

This change runs in the Artist update action to record all previous versions of an artist’s name attribute.

[10/lib/tunez/music/changes/update_previous_names.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Fmusic%2Fchanges%2Fupdate_previous_names.ex)

```elixir
 def change(changeset, _opts, _context) do
 Ash.Changeset.before_action(changeset, fn changeset ->
 new_name = Ash.Changeset.get_attribute(changeset, :name)
 previous_name = Ash.Changeset.get_data(changeset, :name)
 previous_names = Ash.Changeset.get_data(changeset, :previous_names)

 names =
 [previous_name | previous_names]
 |> Enum.uniq()
 |> Enum.reject(fn name -> name == new_name end)

 Ash.Changeset.force_change_attribute(changeset, :previous_names, names)
 end)
 end
```

It can be written atomically in a single expression if we lean on PostgreSQL array operations and functions to do some of the heavy lifting. To embed SQL directly in an expression, we can use a fragment.

```elixir
 expr(
 fragment(
 "array_remove(array_prepend(?, ?), ?)",
 name, previous_names, ^atomic_ref(:name)
 )
 )
```

This expression uses both name and atomic_ref(:name), so we can actually see the difference. name is the name as it exists in the database, but atomic_ref(:name) is the name with any changes we’ve made as part of this action. If we’re changing an artist’s name from “Hybrid Theory” to “Linkin Park”, name will refer to the “Hybrid Theory” value, but atomic_ref(:name) will refer to the “Linkin Park” value.

And if previous_names is “{Xero}”, a PostgreSQL array with one element (the string “Xero”), then this expression will boil down to the SQL fragment:

```elixir
 array_remove(array_prepend('Hybrid Theory', '{Xero}'), 'Linkin Park')
```

If the name is being updated, this will add the old name and remove the new name from the list (as the new name is no longer a “previous” name!), which is the same logic that we wrote in the non-atomic version of the change.

The expression needs one more thing before it can be used in an atomic/3 callback. The fragment returns an array in PostgreSQL land, but Ash has no way of knowing that. To tell Ash that yes, this expression is okay and will always return a valid value, we need to wrap it in an :atomic tuple.

All together, the atomic/3 callback looks like this:

[10/lib/tunez/music/changes/update_previous_names.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Fmusic%2Fchanges%2Fupdate_previous_names.ex)

```elixir
 @impl true
 def atomic(_changeset, _opts, _context) do
 {:atomic,
 %{
 previous_names:
 {:atomic,
 expr(
 fragment(
 "array_remove(array_prepend(?, ?), ?)",
 name, previous_names, ^atomic_ref(:name)
 )
 )}
 }}
 end
```

The change is now fully atomic! We can remove the change/3 version of the change from the UpdatePreviousNames module, and we can remove the require_atomic? false from the update action of the Tunez.Music.Artist resource because the whole action can now be run atomically.

[10/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/10%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 update :update do
 accept [:name, :biography]
 change Tunez.Music.Changes.UpdatePreviousNames
 end
```

## Wrapping Everything Up

And that’s it! Congratulations! You’ve made it to the very end, and there was no monster at the end of the book. Well done!

We hope you’ve enjoyed this tour through the foundations of the Ash framework, learning how it can help speed up your development and write more efficient apps using declarative design. You’ve built a full application (it’s tiny but mighty!) and you should be proud!

What should you do next? Build some more apps! It’s one thing to follow a carefully crafted guide to explain all the concepts as you go along, but it’s quite another to build something of your own. You could build one of the ideas we considered building in this book—a web forum, a Q&A site, a project management tool, or a time tracker. Or you could add some more features to Tunez. Some cool ideas we wanted to cover (but ran out of space for!) are things like these:

- Moving notification generation to a background job, using Oban and AshOban

- Using pubsub to live-update each artist’s follower count in the catalog

- The ability to rate albums and artists

- Extracting that rating ability to an extension, so it can be reused and you can rate all of the things!

- User friendships, and getting notifications when your friends rate an album

- A more advanced artist search, using AshPhoenix.FilterForm

- Genre tags for artists, to show how a tagging UI could be built

The possibilities are literally endless. And that’s just for Tunez. You probably have a lot of awesome ideas of your own, which we’d love to see you build! If you’re keen to learn more about Ash or simply want to chat, join us in the Ash community. We’re a friendly bunch!

And above all else, have fun, and good luck!

Footnotes

<https://hexdocs.pm/ash/Ash.Resource.Change.html>

<https://hexdocs.pm/ash/Ash.html#bulk_create/4>

<https://hexdocs.pm/ash/Ash.Changeset.html#after_action/3>

<https://hexdocs.pm/ecto/Ecto.Repo.html#module-shared-options>

<https://hexdocs.pm/ash/generic-actions.html>

<https://hexdocs.pm/ash/Ash.Policy.Check.Builtins.html#actor_present/0>

<https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html#assign_new/3-when-connected>

<https://hexdocs.pm/phoenix_pubsub/>

<https://hexdocs.pm/phoenix/channels.html>

<https://hexdocs.pm/phoenix/presence.html>

<https://hexdocs.pm/ash/Ash.Notifier.PubSub.html>

<https://hexdocs.pm/ash/notifiers.html>

<https://hexdocs.pm/ash/dsl-ash-notifier-pubsub.html#pub_sub>

<https://hexdocs.pm/ash/Ash.Notifier.PubSub.html#module-topic-templates>

<https://hexdocs.pm/ash/Ash.html#bulk_create/4>

<https://hexdocs.pm/ash/dsl-ash-notifier-pubsub.html#pub_sub-transform>

<https://github.com/ash-project/ash/issues/1792>

<https://hexdocs.pm/ash/Ash.Resource.Change.Builtins.html#cascade_destroy/2>

<https://www.pingcap.com/article/how-to-efficiently-solve-the-n1-query-problem/>

<https://hexdocs.pm/ash/Ash.Resource.Change.Builtins.html#atomic_update/3>

<https://hexdocs.pm/ash/Ash.Resource.Change.html#c:atomic/3>

<https://hexdocs.pm/ash/Ash.Resource.Change.Builtins.html#increment/2>

<https://github.com/ash-project/ash/blob/main/lib/ash/resource/change/increment.ex>

<https://hexdocs.pm/ash/Ash.Expr.html#atomic_ref/1>

<https://www.postgresql.org/docs/current/functions-array.html>

<https://hexdocs.pm/ash/expressions.html#fragments>

<https://ash-hq.org/community>

Copyright © 2025, The Pragmatic Bookshelf.
