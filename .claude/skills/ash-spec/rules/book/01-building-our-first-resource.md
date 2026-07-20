# 1. Building Our First Resource

##  Chapter 1 Building Our First Resource

Hello! You’ve arrived! Welcome!!

In this very first chapter, we’ll start from scratch and work our way up. We’ll set up the starter Tunez application, install Ash, and build our first resource. We’ll define attributes, set up actions, and connect to a database, all while seeing firsthand how Ash’s declarative principles simplify the process. By the end, you’ll have a working resource fully integrated with the Phoenix front end—and the confidence to take the next step.

## Getting the Ball Rolling

Throughout this book, we’ll build Tunez, a music database app. Think of it as a lightweight Spotify, without actually playing music, where users can browse a catalog of artists and albums, follow their favorites, and receive notifications when new albums are released. On the management side, we’ll implement a role-based access system with customizable permissions and create APIs that allow users to integrate Tunez data into their own apps.

But Tunez is more than just an app—it’s your gateway to mastering Ash’s essential building blocks. By building Tunez step by step, you’ll gain hands-on experience with resources, relationships, authentication, authorization, APIs, and more. Each feature we build will teach you foundational skills you can apply to any project, giving you the toolkit and know-how to tackle larger, more complex applications with the same techniques. Tunez may be small, but the lessons you’ll learn here will have a big impact on your development workflow.

A demo version of the final Tunez app can be found online.

### Setting Up Your Development Environment

One of the (many) great things about the Elixir ecosystem is that we get a lot of great new functionality with every new version of Elixir, but nothing gets taken away (at worst, it gets deprecated). So, while it would be awesome to always use the latest and greatest versions of everything, sometimes that’s not possible, and that’s okay! Our apps will still work with the most recent versions of Elixir, Erlang, and PostgreSQL.

To work through this book, you’ll need at least these versions:

- Elixir 1.15
- Erlang 26.0
- PostgreSQL 14.0

Any newer version will also be just fine!

To install these dependencies, we’d recommend a tool like asdf or mise.

We’ve built an initial version of the Tunez app for you to use as a starting point. To follow along with this book, clone the app from the following repository:

<https://github.com/sevenseacat/tunez>

If you’re using asdf, once you’ve cloned the app, you can run asdf install from the project folder to get all the language dependencies set up. The .tool-versions file in the app lists slightly newer versions than the dependencies listed earlier, but you can use any versions you prefer as long as they meet the minimum requirements.

Follow the setup instructions in the README app, including mix setup, to make sure everything is good to go. If you can run mix phx.server without errors and see a styled homepage with some sample artist data, you’re ready to begin!

 

|  |  |
|----|----|
|  | The code for each chapter can also be found in the Tunez repo on GitHub, in branches named for that chapter. |

### Welcome to Ash!

Before we can start using Ash in Tunez, we’ll need to install it and configure it within the app. Tunez is a blank slate; it has a lot of the views and template logic, but no way of storing or reading data. This is where Ash comes in as our main tool for building out the domain model layer of the app, the code responsible for reading and writing data from the database, and implementing our app’s business logic.

To install Ash, we’ll use the Igniter toolkit, which is already installed as a development dependency in Tunez. Igniter gives library authors tools to write smarter code generators, including installers, and we’ll see that here with the igniter.install Mix task.

Run mix igniter.install ash in the tunez folder, and it will patch the mix.exs file with the new package:

```elixir
 $ mix  igniter.install  ash
 Updating project's igniter dependency ✔
 checking for igniter in project ✔
 compiling igniter ✔
 compile ✔

 Update: mix.exs

  ...|
 35 35 | defp deps do
 36 36 | [
 37 + | {:ash, "~> 3.0"},
 37 38 | {:phoenix, "~> 1.8.0"},
 38 39 | {:phoenix_ecto, "~> 4.5"},
  ...|

 Modify mix.exs and install? [Y/n]
```

Confirm the change, and Igniter will install and compile the latest version of the ash package. This will trigger Ash’s own installation Mix task, which will add Ash-specific formatting configuration in .formatter.exs and config/config.exs. The output is a little too long to print here, but we’ll get consistent code formatting and section ordering across all of the Ash-related modules we’ll write over the course of the project.

> **Starting a New App and Wanting to Use Igniter and Ash?**
> Starting a New App and Wanting to Use Igniter and Ash?
> Much like the phx_new package is used to generate new Phoenix projects, Igniter has a companion igniter_new package for generating projects. You can install it using this command:

This gives access to the igniter.new Mix task, which is very powerful. It can also combine with phx.new, so you can use Igniter to scaffold Phoenix apps that come preinstalled with any package you like (and will also preinstall Igniter). For example, this is a Phoenix app with Ash and ErrorTracker:

 
$ <strong>mix</strong> <strong></strong> <strong>igniter.new</strong> <strong></strong> <strong>my_app</strong> <strong></strong> <strong>--with</strong> <strong></strong> <strong>phx.new</strong> <strong></strong> <strong>--install</strong> <strong></strong> <strong>ash,error_tracker</strong>

If you’d like to get up and running with new apps even faster, there’s an interactive installer on the AshHQ homepage. You can select the packages you want to install and get a one-line command to run in your terminal—and then you’ll be off and racing!

The Ash ecosystem is made up of many different packages for integrations with external libraries and services, allowing us to pick and choose only the dependencies we need. As we’re building an app that will talk to a PostgreSQL database, we’ll want the PostgreSQL Ash integration. Use mix igniter.install to add it to Tunez as well:

```elixir
 $ mix  igniter.install  ash_postgres
```

Confirm the change to our mix.exs file, and the package will be downloaded and installed. After completion, this will do the following:

- Add and fetch the ash_postgres Hex package (in mix.exs and mix.lock).

- Add code auto-formatting for the new dependency (in .formatter.exs and config/config.exs).

- Update the database Tunez.Repo module to use Ash, instead of Ecto (in lib/tunez/repo.ex). This also includes a list of PostgreSQL extensions to be installed and enabled by default.

- Update some Mix aliases to use Ash, instead of Ecto (in mix.exs).

- Generate our first migration to set up the ash-functions pseudo-extension listed in the Tunez.Repo module (in priv/repo/migrations/<timestamp>_initialize_extensions_1.exs).

- Generate an extension config file so Ash can keep track of which PostgreSQL extensions have been installed (in priv/resource_snapshots/repo/extensions.json).

You’ll also see a notice from AshPostgres. It has inferred the version of PostgreSQL you’re running and configured that in Tunez.Repo.min_pg_version/0.

And now we’re good to go and can start building!

### Resources and Domains

In Ash, the central concept is the resource. Resources are domain model objects—the nouns that our app revolves around. They typically (but not always) contain some kind of data and define some actions that can be taken on that data.

Related resources are grouped together into domains, which are context boundaries where we can define configuration and functionality that will be shared across all connected resources. This is also where we’ll define the interfaces that the rest of the app uses to communicate with the domain model, much like a Phoenix context does.

What does this mean for Tunez? Over the course of the book, we’ll define several different domains for the distinct ideas within the app, such as Music and Accounts; and each domain will have a collection of resources such as Album, Artist, Track, User, and Notification.

Each resource will define a set of attributes, which is data that maps to keys of the resource’s struct. An Artist resource will read/modify records in the form of Artist structs, and each attribute of the resource will be a key in that struct. The resources will also define relationships—links to other resources—as well as actions, validations, pubsub configuration, and more.

Do I Need Multiple Domains in My App?

Technically, you don’t need multiple domains. For small apps, you can get away with defining a single domain and putting all of your resources in it, but we want to be clear about keeping closely related resources like Album and Artist away from other closely related resources like User and Notification.

You may also want to provide different interfaces for the same resource in different domains. An Order resource, for example, would have different functionality depending on where it’s being used—someone packing boxes in a warehouse needs a very different view of an order than someone working in a customer service department.

We’ve just thrown a lot of words and concepts at you—some may be familiar to you from other frameworks, and others may not. We’ll go over each of them as they become relevant to the app, including lots of other resources that can help you out, as well.

### Generating the Artist Resource

The first resource we’ll create is for an Artist. It’s the most important resource for anything music-related in Tunez that other resources such as albums will link back to. The resource will store information about an artist’s name and biography, which are important for the users to know who they’re looking at!

To create our Artist resource, we’ll use an Igniter generator. You could create the necessary domain and resource files yourself, but the generators are pretty convenient. We’ll then generate the database migration to add a database table for storage for our resource, and then we can start fleshing out actions to be taken on our resource.

The basic resource generator will create a nearly empty Ash resource so we can step through it and look through the parts. Run the following in your terminal:

```elixir
 $ mix  ash.gen.resource  Tunez.Music.Artist  --extend  postgres
```

This will generate a new resource module named Tunez.Music.Artist that extends PostgreSQL, a new domain module named Tunez.Music, and has automatically included the Tunez.Music.Artist module as a resource in the Tunez.Music domain.

The code for the generated resource is in lib/tunez/music/artist.ex:

[01/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 defmodule Tunez.Music.Artist do
 use Ash.Resource, otp_app: :tunez, domain: Tunez.Music,
 data_layer: AshPostgres.DataLayer

 postgres do
 table "artists"
 repo Tunez.Repo
 end
 end
```

Let’s break down this generated code piece by piece because this is our first introduction to Ash’s domain-specific language (DSL).

Because we specified --extend postgres when calling the generator, the resource will be configured with PostgreSQL as its data store for reading from and writing to via AshPostgres.DataLayer. Each Artist struct will be persisted as a row in an artist-related database table.

This specific data layer is configured using the postgres code block. The minimum information we need is the repo and table name, but there’s a lot of other behavior that can be configured as well.

|  |  |
|----|----|
|  | Ash has several different data layers built in using storage such as Mnesia and ETS. More can be added via external packages (the same way we did for PostgreSQL), such as SQLite or CubDB. Some of these external packages aren’t as fully featured as the PostgreSQL package, but they’re pretty usable! |

To add attributes to our resource, add another block in the resource named attributes. Because we’re using PostgreSQL, each attribute we define will be a column in the underlying database table. Ash provides macros we can call to define different types of attributes, so let’s add some attributes to our resource.

A primary key will be critical to identify our artists, so we can call uuid_primary_key to create an auto-generated UUID primary key. Some timestamp fields would be useful, so we know when records are inserted and updated, and we can use create_timestamp and update_timestamp for those. Specifically for artists, we also know we want to store their name and a short biography, and they’ll both be string values. They can be added to the attributes block using the attribute macro.

[01/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 defmodule Tunez.Music.Artist do
 # ...

 attributes do
 uuid_primary_key :id

 attribute :name, :string do
 allow_nil? false
 end

 attribute :biography, :string

 create_timestamp :inserted_at
 update_timestamp :updated_at
 end
 end
```

And that’s all the code we need to write to add attributes to our resource!

> There’s a rich set of configuration options for attributes. You can read more about them in the attribute DSL documentation.[15] We’ve used one here, allow_nil?, but there are many more available.
> You can also pass extra options like --uuid-primary-key id or --attribute name:string to the ash.gen.resource generator[16] to generate attribute-related code (and more!) if you prefer.

Right now, our resource is only a module. We’ve configured a database table for it, but that database table doesn’t yet exist. To change that, we can use another generator, ash.codegen. This one we’ll get pretty familiar with over the course of the book.

### Auto-generating Database Migrations

If you’ve used Ecto for working with databases before, you’ll be familiar with the pattern of creating or updating a schema module, then generating a blank migration and populating it with commands to mirror that schema. It can be a little bit repetitive and has the possibility of your schema and your database getting out of sync. If someone updates the database structure but doesn’t update the schema module, or vice versa, you can get some tricky and hard-to-debug issues.

Ash sidesteps these kinds of issues by generating complete migrations for you based on your resource definitions. This is our first example of Ash’s philosophy of “model your domain, derive the rest.” Your resources are the source of truth for what your app should be and how it should behave, and everything else is derived from that.

What does this mean in practice? Every time you run the ash.codegen mix task, Ash (via AshPostgres) will do the following:

- Create snapshots of your current resources.
- Compare them with the previous snapshots (if they exist).
- Generate deltas of the changes to go into the new migration.

This is data-layer agnostic, in the sense that any data layer can provide its own implementation for what to do when ash.codegen is run. Because we’re using AshPostgres, which is backed by Ecto, we get Ecto migrations.

Now, we have an Artist resource with some attributes, so we can generate a migration for it using the mix task:

```elixir
 $ mix  ash.codegen  create_artists
```

|  |  |
|----|----|
|  | The create_artists argument given here will become the name of the generated migration module, for example, Tunez.Repo.Migrations.CreateArtists. This can be anything, but it’s a good idea to describe what the migration will actually do. |

Running the ash.codegen task will create a few files:

- A snapshot file for our Artist resource, in priv/resource_snapshots/repo/artists/[timestamp].json. This is a JSON representation of our resource as it exists right now.

- A migration for our Artist resource, in priv/repo/migrations/[timestamp]_create_artists.ex. This contains the schema differences that Ash has detected between our current snapshot that was just created and the previous snapshot (which, in this case, is empty).

This migration contains the Ecto commands to set up the database table for our Artist resource, with the fields we added for a primary key, timestamps, name, and biography:

[01/priv/repo/migrations/[timestamp]_create_artists.exs](http://media.pragprog.com/titles/ldash/code/01%2Fpriv%2Frepo%2Fmigrations%2F%5Btimestamp%5D_create_artists.exs)

```elixir
 def up do
 create table(:artists, primary_key: false) do
 add :id, :uuid, null: false, default: fragment("gen_random_uuid()"),
 primary_key: true
 add :name, :text, null: false
 add :biography, :text

 add :inserted_at, :utc_datetime_usec,
 null: false,
 default: fragment("(now() AT TIME ZONE 'utc')")

 add :updated_at, :utc_datetime_usec,
 null: false,
 default: fragment("(now() AT TIME ZONE 'utc')")
 end
 end
```

This looks a lot like what you would write if you were setting up a database table for a pure Ecto schema—but we didn’t have to write it. We don’t have to worry about keeping the database structure in sync manually. We can run mix ash.codegen every time we change anything database-related, and Ash will figure out what needs to be changed and create the migration for us.

This is the first time we’ve touched the database, but the database will already have been created when running mix setup earlier. To run the migration we generated, use Ash’s ash.migrate Mix task:

```elixir
 $ mix  ash.migrate
 Getting extensions in current project...
 Running migration for AshPostgres.DataLayer...

 [timestamp] [info] == Running [timestamp] Tunez.Repo.Migrations
 .InitializeExtensions1.up/0 forward
 truncated SQL output
 [timestamp] [info] == Migrated [timestamp] in 0.0s

 [timestamp] [info] == Running [timestamp] Tunez.Repo.Migrations
 .CreateArtists.up/0 forward
 [timestamp] [info] create table artists
 [timestamp] [info] == Migrated [timestamp] in 0.0s
```

Now we have a database table, ready to store Artist data!

> To roll back a migration, Ash also provides an ash.rollback Mix task, as well as ash.setup, ash.reset, and so on. These are more powerful than their Ecto equivalents—any Ash extension can set up their own functionality for each task. For example, AshPostgres provides an interactive UI to select how many migrations to roll back when running ash.rollback.
> Note that if you roll back and then delete a migration to regenerate it, you’ll also need to delete the snapshots that were created with the migration.

How do we actually use the resource to read or write data into our database, though? We’ll need to define some actions on our resource.

## Oh, CRUD! — Defining Basic Actions

An action describes an operation that can be performed for a given resource; it is the verb to a resource’s noun. Actions can be loosely broken down into four types:

- Creating new persisted records (rows in the database table)
- Reading one or more existing records
- Updating an existing record
- Destroying (deleting) an existing record

These four types of actions are common in web applications and are often shortened to the acronym CRUD.

|  |  |
|----|----|
|  | Ash also supports generic actions for any action that doesn’t fit into any of those four categories. We won’t be covering those in this book, but you can read the online documentation about them. |

With a bit of creativity, we can use these four basic action types to describe almost any kind of action we might want to perform in an app.

Registering for an account? That’s a type of create action on a User resource.

Searching for products to purchase? That sounds like a read action on a Product resource.

Publishing a blog post? It could be a create action if the user is writing the post from scratch, or an update action if they’re publishing an existing saved draft.

In Tunez, we’ll have functionality for users to list artists and view details of a specific artist (both read actions), create and update artist records (via forms), and also destroy artist records; so we’ll want to use all four types of actions. This is a great time to learn how to define and run actions using Ash, with some practical examples.

In our Artist resource, we can add an empty block for actions and then start filling it out with what we want to be able to do:

[01/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 defmodule Tunez.Music.Artist do
 # ...

 actions do
 end
 end
```

Let’s start with creating records with a create action, so we have some data to use when testing out other types of actions.

### Defining a create Action

Actions are defined by adding them to the actions block in a resource. At their most basic, they require a type (one of the four mentioned earlier—create, read, update, and destroy), and a name. The name can be any atom you like but should describe what the action is actually supposed to do. It’s common to give the action the same name as the action type until you know you need something different.

[01/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 actions do
 create :create do
 end
 end
```

To create an Artist record, we need to provide the data to be stored—in this case, the name and biography attributes, in a map. (The other attributes, such as timestamps, will be automatically managed by Ash.) We call these the attributes that the action accepts and can list them in the action with the accept macro.

[01/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 actions do
 create :create do
 accept [:name, :biography]
 end
 end
```

And that’s actually all we need to do to create the most basic create action. Ash knows that the core of what a create action should do is create a data layer record from provided data, so that’s exactly what it will do when we run it.

### Running Actions

There are two basic ways we can run actions: the generic query/changeset method and the more direct code interface method. We can test them both out in an iex session:

```elixir
 $ iex  -S  mix
```

#### Creating Records via a Changeset

If you’ve used Ecto before, this pattern may be familiar to you:

- Create a changeset (a set of data changes to apply to the resource).
- Pass that changeset to Ash for processing.

In code, this might look like the following:

```elixir
 iex(1)> Tunez.Music.Artist
 |> Ash.Changeset.for_create(:create, %{
 name: "Valkyrie's Fury",
 biography: "A power metal band hailing from Tallinn, Estonia"
 })
 |> Ash.create()
```

```elixir
 {:ok,
 #Tunez.Music.Artist<
 id: [uuid],
 name: "Valkyrie's Fury",
 biography: "A power metal band hailing from Tallinn, Estonia",
 ...
 >}
```

We specify the action that the changeset should be created for, with the data that we want to save. When we pipe that changeset into Ash, it will handle running all of the validations, creating the record in the database, and then returning the record as part of an :ok tuple. You can verify this in your database client of choice, for example, using psql tunez_dev in your terminal to connect using the inbuilt command-line client:

```elixir
 tunez_dev=# select * from artists;
 -[ RECORD 1 ]----------------------------------------------
 id | [uuid]
 name | Valkyrie's Fury
 biography | A power metal band hailing from Tallinn, Estonia
 inserted_at | [now]
 updated_at | [now]
```

What happens if we submit invalid data, such as an Artist without a name?

```elixir
 iex(2)> Tunez.Music.Artist
 |> Ash.Changeset.for_create(:create, %{name: ""})
 |> Ash.create()
 {:error,
 %Ash.Error.Invalid{
 bread_crumbs: ["Error returned from: Tunez.Music.Artist.create"],
 changeset: #Changeset<>,
 errors: [
 %Ash.Error.Changes.Required{
 field: :name,
 type: :attribute,
 resource: Tunez.Music.Artist,
 ...
```

The record isn’t inserted into the database, and we get an error record back telling us what the issue is: the name is required. This error comes from the allow_nil? false that we set for the name attribute. Later on in this chapter, we’ll see how these returned errors are used when we integrate the actions into our web interface.

Like a lot of other Elixir libraries, most Ash functions return data in :ok and :error tuples. This is handy because it lets you easily pattern match on the result to handle the different scenarios. To raise an error instead of returning an error tuple, you can use the bang version of a function ending in an exclamation mark, that is, Ash.create! instead of Ash.create.

#### Creating Records via a Code Interface

If you’re familiar with Ruby on Rails or ActiveRecord, this pattern may be more familiar to you. It allows us to skip the step of manually creating a changeset and lets us call the action directly as a function.

Code interfaces can be defined on either a domain module or on a resource directly. We’d generally recommend defining them on domains, similar to Phoenix contexts, because this lets the domain act as a solid boundary with the rest of your application. Listing all your resources in your domain also gives a great overview of all your functionality in one place.

To enable this, use Ash’s define macro when including the Artist resource in our Tunez.Music domain:

[01/lib/tunez/music.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez%2Fmusic.ex)

```elixir
 resources do
 resource Tunez.Music.Artist do
 define :create_artist, action: :create
 end
 end
```

This will connect our domain function create_artist, to the create action of the resource. Once you’ve done this, if you recompile within iex, the new function will now be available, complete with auto-generated documentation:

```elixir
 iex(2)> h Tunez.Music.create_artist

 def create_artist(params \ nil, opts \ nil)

 Calls the create action on Tunez.Music.Artist.

 # Inputs

 • name
 • biography
```

You can call it like any other function, with the data to be inserted into the database:

```elixir
 iex(7)> Tunez.Music.create_artist(%{
 name: "Valkyrie's Fury",
 biography: "A power metal band hailing from Tallinn, Estonia"
 })
 {:ok, #Tunez.Music.Artist<...>}
```

When Would I Use Changesets Instead of Code Interfaces, or Vice Versa?

Under the hood, the code interface is creating a changeset and passing it to the domain, but that repetitive logic is hidden away. So there’s no real functional benefit, but the code interface is easier to use and more readable.

Where the changeset method shines is around forms on the page. We’ll see shortly how AshPhoenix provides a thin layer over the top of changesets to allow all of Phoenix’s existing form helpers to work seamlessly with Ash changesets instead of Ecto changesets.

We’ve provided some sample content for you to play around with—there’s a mix seed alias defined in the aliases/0 function in the Tunez app’s mix.exs file. It has three lines for three different seed files, all commented out. Uncomment the first line:

[01/mix.exs](http://media.pragprog.com/titles/ldash/code/01%2Fmix.exs)

```elixir
 defp aliases do
 [
 setup: ["deps.get", "ash.setup", "assets.setup", "assets.build", ...],
 "ecto.setup": ["ecto.create", "ecto.migrate"],
 seed: [
 "run priv/repo/seeds/01-artists.exs",
 # "run priv/repo/seeds/02-albums.exs",
 # "run priv/repo/seeds/08-tracks.exs"
 ],
 # ...
```

Running mix seed will now import a list of sample (fake) artist data into your database. There are other seed files listed in the function as well, but we’ll mention those when we get to them! (The chapter numbers in the filenames are probably a bit of a giveaway.)

```elixir
 $ mix  seed
```

Now that we have some data in our database, let’s look at other types of actions.

### Defining a read Action

In the same way we defined the create action on the Artist resource, we can define a read action by adding it to the actions block. We’ll add one extra option: we’ll define it as a primary action.

[01/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 actions do
 # ...
 read :read do
 primary? true
 end
 end
```

A resource can have one of each of the four action types (create, read, update, and destroy) marked as the primary action of that type. These are used by Ash behind the scenes when actions aren’t or can’t be specified. We’ll cover these in a little bit more detail later.

To be able to call the read action as a function, add it as a code interface in the domain just as we did with create.

[01/lib/tunez/music.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez%2Fmusic.ex)

```elixir
 resource Tunez.Music.Artist do
 # ...
 define :read_artists, action: :read
 end
```

What does a read action do? As the name suggests, it will read data from our data layer based on any parameters we provide. We haven’t defined any parameters in our action, so when we call the action, we should expect it to return all the records in the database.

```elixir
 iex(1)> Tunez.Music.read_artists()
 {:ok, [#Tunez.Music.Artist<...>, #Tunez.Music.Artist<...>, ...]}
```

While actions that modify data use changesets under the hood, read actions use queries. If we do want to provide some parameters to the action, such as filtering or sorting, we need to modify the query when we run the action. This can be done either as part of the action definition (we’ll learn about that in [*Designing a Search Action*](#f_0028.xhtml_ch03.action_arguments)) or inline when we call the action.

#### Manually Reading Records via a Query

While this isn’t something you’ll do a lot of when building applications, it’s still a good way of seeing how Ash builds up queries piece by piece.

There are a few steps to the process:

- Creating a basic query from the action we want to run

- Piping the query through other functions to add any extra parameters we want

- Passing the final query to Ash for processing

In iex you can test this out step by step, starting from the basic resource, and creating the query:

```elixir
 iex(2)> Tunez.Music.Artist
 Tunez.Music.Artist
 iex(3)> |> Ash.Query.for_read(:read)
 #Ash.Query<resource: Tunez.Music.Artist, action: :read>
```

Then you can pipe that query into Ash’s query functions like sort and limit. The query keeps getting the extra conditions added to it, but it isn’t yet being run in the database.

```elixir
 iex(4)> |> Ash.Query.sort(name: :asc)
 #Ash.Query<resource: Tunez.Music.Artist, action: :read, sort: [name: :asc]>
 iex(5)> |> Ash.Query.limit(1)
 #Ash.Query<resource: Tunez.Music.Artist, action: :read, sort: [name: :asc],
 limit: 1>
```

Then, when it’s time to go, Ash can call it and return the data you requested, with all conditions applied:

```elixir
 iex(6)> |> Ash.read()
 SELECT a0."id", a0."name", a0."biography", a0."inserted_at", a0."updated_at"
 FROM "artists" AS a0 ORDER BY a0."name" LIMIT $1 [1]
 {:ok, [#Tunez.Music.Artist<...>]}
```

For a full list of the query functions Ash provides, check out the documentation. Note that to use any of the functions that use special syntax, like filter, you’ll need to require Ash.Query in your iex session first.

#### Reading a Single Record by Primary Key

One common requirement is to be able to read a single record by its primary key. We’re building a music app, so we’ll be building a page where we can view an artist’s profile, and we’ll want an easy way to fetch that single Artist record for display.

We have a basic read action already, and we could write another read action that applies a filter to only fetch the data by an ID we provide, but Ash provides a simpler way.

A neat feature of code interfaces is that they can automatically apply a filter for any attribute of a resource that we expect to return at most one result. Looking up records by primary key is a perfect use case for this because they’re guaranteed to be unique!

To use this feature, add another code interface for the same read action, but also add the get_by option for the primary key, the attribute :id.

[01/lib/tunez/music.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez%2Fmusic.ex)

```elixir
 resource Tunez.Music.Artist do
 # ...
 define :get_artist_by_id, action: :read, get_by: :id
 end
```

Adding this code interface defines a new function on our domain:

```elixir
 iex(4)> h Tunez.Music.get_artist_by_id

 def get_artist_by_id(id, params \ nil, opts \ nil)

 Calls the read action on Tunez.Music.Artist.
```

Copy the ID from any of the records you loaded when testing the read action, and you’ll see that this new function does exactly what we hoped: it returns the single record that has that ID.

```elixir
 iex(3)> Tunez.Music.get_artist_by_id("an-artist-id")
 SELECT a0."id", a0."name", a0."biography", a0."inserted_at", a0."updated_at"
 FROM "artists" AS a0 WHERE (a0."id"::uuid = $1::uuid) ["an-artist-id"]
 {:ok, #Tunez.Music.Artist<id: "an-artist-id", ...>}
```

Perfect! We’ll be using that soon.

### Defining an update Action

A basic update action is conceptually similar to a create action. The main difference is that instead of building a new record with some provided data and saving it into the database, we provide an existing record to be updated with the data and saved.

Let’s add the basic action and code interface definition:

[01/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 actions do
 # ...
 update :update do
 accept [:name, :biography]
 end
 end
```

[01/lib/tunez/music.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez%2Fmusic.ex)

```elixir
 resource Tunez.Music.Artist do
 # ...
 define :update_artist, action: :update
 end
```

How would we call this new action? First, we need a record to be updated. You can use the read action you defined earlier to find one, or if you’ve been testing the get_artist_by_id function we just wrote, you might have one right there. Note the use of the bang version of the function here (get_artist_by_id!) to get back a record instead of an :ok tuple.

```elixir
 iex(3)> artist = Tunez.Music.get_artist_by_id!("an-artist-id")
 #Tunez.Music.Artist<id: "an-artist-id", ...>
```

Now we can either use the code interface we added or create a changeset and apply it, as we did for create.

```elixir
 iex(4)> # Via the code interface
 iex(5)> Tunez.Music.update_artist(artist, %{name: "Hello"})
 UPDATE "artists" AS a0 SET "updated_at" = (CASE WHEN $1::text !=
 a0."name"::text THEN $2::timestamp ELSE a0."updated_at"::timestamp END)
 ::timestamp, "name" = $3::text WHERE (a0."id"::uuid = $4::uuid) RETURNING
 a0."id", a0."name", a0."biography", a0."inserted_at", a0."updated_at"
 ["Hello", [now], "Hello", "an-artist-id"]
 {:ok, #Tunez.Music.Artist<id: "an-artist-id", name: "Hello", ...>}

 iex(6)> # Or via a changeset
 iex(7)> artist
 |> Ash.Changeset.for_update(:update, %{name: "World"})
 |> Ash.update()
 an almost-identical SQL statement
 {:ok, #Tunez.Music.Artist<id: "an-artist-id", name: "World", ...>}
```

As with create actions, we get either an :ok tuple with the updated record or an :error tuple with an error record back.

### Defining a destroy Action

The last type of core action that Ash provides is the destroy action, which we use when we want to get rid of data, or delete it from our database. Like update actions, destroy actions work on existing data records, so we need to provide a record when we call a destroy action, but that’s the only thing we need to provide. Ash can do the rest!

You might be able to guess by now how to implement a destroy action in our resource:

[01/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 actions do
 # ...
 destroy :destroy do
 end
 end
```

[01/lib/tunez/music.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez%2Fmusic.ex)

```elixir
 resource Tunez.Music.Artist do
 # ...
 define :destroy_artist, action: :destroy
 end
```

This will allow us to call the action either by creating a changeset and submitting it or calling the action directly.

```elixir
 iex(3)> artist = Tunez.Music.get_artist_by_id!("the-artist-id")
 #Tunez.Music.Artist<id: "an-artist-id", ...>

 iex(4)> # Via the code interface
 iex(5)> Tunez.Music.destroy_artist(artist)
 DELETE FROM "artists" AS a0 WHERE (a0."id" = $1) ["the-artist-id"]
 :ok

 iex(6)> # Or via a changeset
 iex(7)> artist
 |> Ash.Changeset.for_destroy(:destroy)
 |> Ash.destroy()
 DELETE FROM "artists" AS a0 WHERE (a0."id" = $1) ["the-artist-id"]
 :ok
```

And with that, we have a solid explanation of the four main types of actions we can define in our resources.

Let’s take a moment to let this sink in. By creating a resource and adding a few lines of code to describe its attributes and what actions we can take on it, we now have the following:

- A database table to store records in

- Secure functions we can call to read and write data to the database (remember: no storing any attributes that aren’t explicitly allowed)

- Database-level validations to ensure that data is present

- Automatic type-casting of attributes before they get stored

We didn’t have to write any functions that query the database, update our database schema when we added new attributes to the resource, or manually cast attributes. A lot of the boilerplate we would typically need to write has been taken care of for us because Ash handles translating what our resource should do into how it should be done. This is a pattern we’ll see a lot!

### Default Actions

Now that you’ve learned about the different types of actions and how to define them in your resources, we’ll let you in on a little secret.

You don’t actually have to define empty actions like this for CRUD actions.

You know how we said that Ash knows that the main purpose of a create action is to take the data and save it to the data layer? This is what we call the default implementation for a create action. Ash provides default implementations for all four action types, and if you want to use these implementations without any customization, you can use the defaults macro in your actions block like this:

[01/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 actions do
 defaults [:create, :read, :update, :destroy]
 end
```

We still need the code interface definitions if we want to be able to call the actions as functions, but we can cut out the empty actions to save time and space. This also marks all four actions as primary? true, as a handy side effect.

But what about the accept definitions that we added to the create and update actions, the list of attributes to save? We can define default values for that list with the default_accept macro. This default list will then apply to all create and update actions unless specified otherwise (as part of the action definition).

So the actions for our whole resource, as it stands right now, could be written in a few short lines of code:

[01/lib/tunez/music/artist.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez%2Fmusic%2Fartist.ex)

```elixir
 actions do
 defaults [:create, :read, :update, :destroy]
 default_accept [:name, :biography]
 end
```

That is a lot of functionality packed into those four lines!

Which version of the code you write is up to you. For actions other than read, we would generally err on the side of explicitly defining the actions with the attributes they accept as you’ll need to convert them whenever you need to add business logic to your actions anyway. We don’t tend to customize the basic read action, and using a default action for read actually adds some extra functionality as well (mostly around pagination), so read usually gets placed in the defaults list.

For quick prototyping though, the shorthand for all four actions can’t be beat. Whichever way you go, it’s critical to know what your code is doing for you under the hood, which is generating a full CRUD interface to your resource, thus allowing you to manage your data.

## Integrating Actions into LiveViews

We’ve talked a lot about Tunez the web app, but we haven’t even looked at the app in an actual browser yet. Now that we have a fully functioning resource, let’s integrate it into the web interface so we can see the actions in, well, action!

### Listing Artists

In the app folder, start the Phoenix web server with the following command in your terminal:

```elixir
 $ mix  phx.server
 [info] Running TunezWeb.Endpoint with Bandit 1.7.0 at 127.0.0.1:4000 (http)
 [info] Access TunezWeb.Endpoint at http://localhost:4000
 [watch] build finished, watching for changes...
 ≈ tailwindcss v4.1.4

 Done in [time]ms.
```

Once you see that the build is ready to go, open a web browser at http://localhost: 4000, and you can see what we’ve got to work with.

The app homepage is the artist catalog, listing all of the Artists in the app. In the code, this catalog is rendered by the TunezWeb.Artists.IndexLive module, in lib/tunez_web/live/artists/index_live.ex.

> We’re not going to go into a lot of detail about Phoenix and Phoenix LiveView, apart from where we need to ensure that our app is secure. If you need a refresher course (or want to learn them for the first time), we can recommend reading through Programming Phoenix 1.4 [TV19] and Programming Phoenix LiveView [TD25].
> If you’re more of a video person, you shouldn’t pass up Pragmatic Studio’s Phoenix LiveView course.[22]

In the IndexLive module, we have some hardcoded maps of artist data defined in the handle_params/3 function:

[01/lib/tunez_web/live/artists/index_live.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez_web%2Flive%2Fartists%2Findex_live.ex)

```elixir
 def handle_params(_params, _url, socket) do
 artists = [
 %{id: "test-artist-1", name: "Test Artist 1"},
 %{id: "test-artist-2", name: "Test Artist 2"},
 %{id: "test-artist-3", name: "Test Artist 3"},
 ]

 socket =
 socket
 |> assign(:artists, artists)

 {:noreply, socket}
 end
```

These are what are iterated over in the render/1 function, using a function component to show a “card” for each artist—the image placeholders and names we can see in the browser.

Earlier in [*Defining a read Action*](#f_0019.xhtml_ch01.read_action), we defined a code interface function on the Tunez.Music domain for reading records from the database. It returns Artist structs that have id and name keys, just as the hardcoded data does. So, to load real data from the database, replace the hardcoded data with a call to the read action.

[01/lib/tunez_web/live/artists/index_live.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez_web%2Flive%2Fartists%2Findex_live.ex)

```elixir
 def handle_params(_params, _url, socket) do
 artists = Tunez.Music.read_artists!()
 # ...
```

And that’s it! The page should reload in your browser when you save the changes to the liveview, and the names of the seed artists and the test artists you created should be visibly rendered on the page.

Each of the placeholder images and names links to a separate profile page where you can view details of a specific artist, and which we’ll address next.

### Viewing an Artist Profile

Clicking on the name of one of the artists will bring you to their profile page. This liveview is defined in TunezWeb.Artists.ShowLive, which you can verify by checking the logs of the web server in your terminal:

```elixir
 [debug] MOUNT TunezWeb.Artists.ShowLive
 Parameters: %{"id" => "[the artist UUID]"}
```

Inside that module, in lib/tunez_web/live/artists/show_live.ex, you’ll again see some hardcoded artist data defined in the handle_params/3 function and added to the socket.

[01/lib/tunez_web/live/artists/show_live.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez_web%2Flive%2Fartists%2Fshow_live.ex)

```elixir
 def handle_params(_params, _url, socket) do
 artist = %{
 id: "test-artist-1",
 name: "Artist Name",
 biography: some sample biography content
 }
 # ...
```

Earlier in [*Reading a Single Record by Primary Key*](#f_0019.xhtml_ch01.get_by_primary_key), we defined a get_artist_by_id code interface function on the Tunez.Music domain, which reads a single Artist record from the database by its id attribute. The URL for the profile page contains the ID of the Artist to show on the page, and the terminal logs show that the ID is available as part of the params. So we can replace the hardcoded data with a call to get_artist_by_id after first using pattern matching to get the ID from the params.

[01/lib/tunez_web/live/artists/show_live.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez_web%2Flive%2Fartists%2Fshow_live.ex)

```elixir
 def handle_params(%{"id" => artist_id}, _url, socket) do
 artist = Tunez.Music.get_artist_by_id!(artist_id)
 # ...
```

After saving the changes to the liveview, the page should refresh and you should see the correct data for the artist whose profile you’re viewing.

### Creating Artists with AshPhoenix.Form

To create and edit Artist data, we’ll have to learn how to handle forms and form data with Ash.

If we were building our app directly on Phoenix contexts using Ecto, we would have a schema module that would define the attributes for an Artist. The schema module would also define a changeset function to parse and validate data from forms before the context module would attempt to insert or update it in the database. If the data validation fails, the liveview (or a template) can take the resulting changeset with errors on it and use it to show the user what they need to fix.

In code, the changeset function might look something like this:

```elixir
 defmodule Tunez.Music.Artist do
 def changeset(artist, attrs) do
 artist
 |> cast(attrs, [:name, :biography])
 |> validate_required([:name])
 end
```

And the context module that uses it might look like this:

```elixir
 defmodule Tunez.Music do
 def create_artist(attrs \ %{}) do
 %Artist{}
 |> Artist.changeset(attrs)
 |> Repo.insert()
 end
```

We can use a similar pattern with Ash, but we need a slightly different abstraction.

We have our Artist resource defined with attributes, similar to an Ecto schema. It has actions to create and update data, replacing the context part as well. What we’re missing is the integration with our UI—a way to take the errors returned if the create action fails and show them to the user—and this is where AshPhoenix comes in.

#### Hello, AshPhoenix

As the name suggests, AshPhoenix is a core Ash library to make it much nicer to work with Ash in the context of a Phoenix application. We’ll use it a few times over the course of building Tunez, but its main purpose is form integration.

Like AshPostgres and Ash itself, we can use mix igniter.install to install AshPhoenix in a terminal:

```elixir
 $ mix  igniter.install  ash_phoenix
```

Confirm the addition of AshPhoenix to your mix.exs file, and the package will be installed, and we can start using it straight away.

#### A Form for an Action

Our Artist resource has a create action that accepts data for the name and biography attributes. Our web interface will reflect this exactly—we’ll have a form with a text field to enter a name, and a text area to enter a biography.

We can tell AshPhoenix that what we want is a form to match the inputs for our create action or, more simply, a form for our create action. AshPhoenix will return an AshPhoenix.Form struct and provide a set of intuitively named functions for interacting with it. We can validate our form, submit our form, add and remove forms (for nested form data!), and more.

In an iex session, we can get familiar with using AshPhoenix.Form:

```elixir
 iex(1)> form = AshPhoenix.Form.for_create(Tunez.Music.Artist, :create)
 #AshPhoenix.Form<
 resource: Tunez.Music.Artist,
 action: :create,
 type: :create,
 params: %{},
 source: #Ash.Changeset<
 domain: Tunez.Music,
 action_type: :create,
 action: :create,
 attributes: %{},
 ...
```

An AshPhoenix.Form wraps an Ash.Changeset, which behaves similarly to an Ecto.Changeset. This allows the AshPhoenix form to be a drop-in replacement for an Ecto.Changeset, when calling the function components that Phoenix generates for dealing with forms. Let’s keep testing.

```elixir
 iex(2)> AshPhoenix.Form.validate(form, %{name: "Best Band Ever"})
 #AshPhoenix.Form<
 resource: Tunez.Music.Artist,
 action: :create,
 type: :create,
 params: %{name: "Best Band Ever"},
 source: #Ash.Changeset<
 domain: Tunez.Music,
 action_type: :create,
 action: :create,
 attributes: %{name: "Best Band Ever"},
 relationships: %{},
 errors: [],
 data: %Tunez.Music.Artist{...},
   valid?: true
   >,
 ...
```

If we call AshPhoenix.Form.validate with valid data for an Artist, the changeset in the form is now valid. In a liveview, this is what we would call in a phx-change event handler to make sure our form in memory stays up-to-date with the latest data. Similarly, we can call AshPhoenix.Form.submit on the form in a phx-submit event handler.

```elixir
 iex(5)> AshPhoenix.Form.submit(form, params: %{name: "Best Band Ever"})
 INSERT INTO "artists" ("id","name","inserted_at","updated_at") VALUES
 ($1,$2,$3,$4) RETURNING "updated_at","inserted_at","biography","name","id"
 [[uuid], "Best Band Ever", [timestamp], [timestamp]]
 {:ok,
 %Tunez.Music.Artist{
 id: [uuid],
 name: "Best Band Ever",
 ...
```

And it works! We get back a form-ready version of the return value of the action. If we had called submit with invalid data, we would get back an {:error, %AshPhoenix.Form{}} tuple instead.

#### Using the AshPhoenix Domain Extension

We’ve defined code interface functions like Tunez.Music.read_artists for all of the actions in the Artist resource and used those code interfaces in our liveviews. It might feel a bit odd to now revert back to using action names directly when generating forms. And if the names of the code interface function and the action are different, it could get confusing!

AshPhoenix provides a solution for this, with a domain extension. If we add the AshPhoenix extension to the Tunez.Music domain module, this will define some new functions on the domain around form generation.

In the Tunez.Music module in lib/tunez/music.ex, add a new extensions option to the use Ash.Domain line:

[01/lib/tunez/music.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez%2Fmusic.ex)

```elixir
 defmodule Tunez.Music do
 use Ash.Domain, otp_app: :tunez, extensions: [AshPhoenix]

 # ...
```

Now, instead of calling AshPhoenix.Form.for_create(Tunez.Music.Artist, :create), we can use a new function Tunez.Music.form_to_create_artist. This works for any code interface function, even for read actions, by prefixing form_to_ to the function name.

```elixir
 iex(5)> AshPhoenix.Form.for_create(Tunez.Music.Artist, :create)
 #AshPhoenix.Form<resource: Tunez.Music.Artist, action: :create, ...>
 iex(6)> Tunez.Music.form_to_create_artist()
 #AshPhoenix.Form<resource: Tunez.Music.Artist, action: :create, ...>
```

The result is the same—you get an AshPhoenix.Form struct to validate and submit, as before—but the way you get it is a lot more consistent with other function calls.

#### Integrating a Form into a Liveview

The liveview for creating an Artist is the TunezWeb.Artists.FormLive module, located in lib/tunez_web/live/artists/form_live.ex. In the browser, you can view it by clicking the New Artist button on the artist catalog, or visiting /artists/new.

It looks good, but it’s totally non-functional right now. We can use what we’ve learned so far about AshPhoenix.Form to make it work as we would expect.

It starts from the top—we want to build our initial form in the mount/3 function. Currently, form is defined as an empty map, just to get the form to render. We can replace it with a function call to create the form, as we did in iex. If you haven’t restarted your Phoenix server since installing AshPhoenix, you’ll need to do so now.

[01/lib/tunez_web/live/artists/form_live.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez_web%2Flive%2Fartists%2Fform_live.ex)

```elixir
 def mount(_params, _session, socket) do
 form = Tunez.Music.form_to_create_artist()

 socket =
 socket
 |> assign(:form, to_form(form))
 # ...
```

The form has a phx-change event handler attached that will fire after every pause in typing on the form. This will send the “validate” event to the liveview, handled by the handle_event/3 function head with the first argument “validate”.

[01/lib/tunez_web/live/artists/form_live.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez_web%2Flive%2Fartists%2Fform_live.ex)

```elixir
 def handle_event("validate", %{"form" => _form_data}, socket) do
 {:noreply, socket}
 end
```

It doesn’t currently do anything, but we know we need to update the form in the socket with the data from the form.

[01/lib/tunez_web/live/artists/form_live.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez_web%2Flive%2Fartists%2Fform_live.ex)

```elixir
 def handle_event("validate", %{"form" => form_data}, socket) do
 socket =
 update(socket, :form, fn form ->
 AshPhoenix.Form.validate(form, form_data)
 end)

 {:noreply, socket}
 end
```

Finally, we need to deal with form submission. The form has a phx-submit event handler attached that will fire when the user presses the Save button (or presses Enter). This will send the “save” event to the liveview. The event handler currently doesn’t do anything either (we told you the form was non-functional!), but we can add code to submit the form with the form data.

We also need to handle the response after submission, handling both the success and failure cases. If the user submits invalid data, then we want to show errors; otherwise, we can go to the newly added artist’s profile page and display a success message.

[01/lib/tunez_web/live/artists/form_live.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez_web%2Flive%2Fartists%2Fform_live.ex)

```elixir
 def handle_event("save", %{"form" => form_data}, socket) do
 case AshPhoenix.Form.submit(socket.assigns.form, params: form_data) do
 {:ok, artist} ->
 socket =
 socket
 |> put_flash(:info, "Artist saved successfully")
 |> push_navigate(to: ~p"/artists/#{artist}")

 {:noreply, socket}

 {:error, form} ->
 socket =
 socket
 |> put_flash(:error, "Could not save artist data")
 |> assign(:form, form)

 {:noreply, socket}
 end
 end
```

Give it a try! Submit some invalid data, see the validation errors, correct the data, and submit the form again. It works great!

But what happens if you make a typo when entering data? No one wants to read about Metlalica, do they? We need some way of editing artist records and updating any necessary information.

### Updating Artists with the Same Code

When we set up the update actions in our Artist resource in [*Defining an update Action*](#f_0019.xhtml_ch01.update_action), we noted that it was pretty similar to the create action and that the only real difference for update is that we need to provide the record being updated. The rest of the flow—providing data to be saved and saving it to the database—is exactly the same.

In addition, the web interface for editing an artist should be exactly the same as for creating an artist. The only difference will be that the form for editing has the artist data pre-populated on it so that it can be modified, and the form for creating will be totally blank.

We can actually use the same TunezWeb.Artists.FormLive liveview module for both creating and updating records. The routes are already set up for this: clicking the Edit Artist button on the profile page will take you to that liveview.

```elixir
 [debug] MOUNT TunezWeb.Artists.FormLive
 Parameters: %{"id" => "[the artist UUID]"}
```

|  |  |
|----|----|
|  | This won’t be the case for all resources, all the time. You may need different interfaces for creating and updating data. A lot of the time, though, this can be a neat way of building out functionality quickly, and it can be changed later if your needs change. |

The FormLive liveview will need to have different forms, depending on whether an artist is being created or updated. Everything else can be the same because we still want to validate the data on keystroke, submit the form on form submission, and perform the same actions after submission.

We currently build the form for create in the mount/3 function, so to support both create and update, we’ll add another mount/3 function head specifically for update. This will set a different form in the socket assigns—a form built for the update action, instead of create.

[01/lib/tunez_web/live/artists/form_live.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez_web%2Flive%2Fartists%2Fform_live.ex)

```elixir
 def mount(%{"id" => artist_id}, _session, socket) do
 artist = Tunez.Music.get_artist_by_id!(artist_id)
 form = Tunez.Music.form_to_update_artist(artist)

 socket =
 socket
 |> assign(:form, to_form(form))
 |> assign(:page_title, "Update Artist")

 {:ok, socket}
 end

 def mount(_params, _session, socket) do
 form = Tunez.Music.form_to_create_artist()
 # ...
```

This new function head (which has to come before the existing function head) is differentiated by having an artist id in the params, just like the ShowLive module did when we viewed the artist profile. It sets up the form specifically for the update action of the resource, using the loaded Artist record as the first argument. It also sets a different page title, and that’s all that has to change! Everything else should keep behaving exactly the same.

Save the liveview and test it out in your browser. You should now be able to click Edit Artist, update the artist’s details, save, and see the changes reflected back in their profile.

### Deleting Artist Data

The last action we need to integrate is the destroy_artist code interface function for removing records from the database. In the UI, this is done from a button at the top of the artist profile page, next to the Edit button. The button, located in the template for TunezWeb.Artists.ShowLive, will send the “destroy-artist” event when pressed.

[01/lib/tunez_web/live/artists/show_live.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez_web%2Flive%2Fartists%2Fshow_live.ex)

```elixir
 <.button_link kind="error" inverse phx-click="destroy-artist"
 data-confirm={"Are you sure you want to delete #{@artist.name}?"}>
 Delete Artist
 </.button_link>
```

We’ve already loaded the artist record from the database when rendering the page, and stored it in socket.assigns, so you can fetch it out again and attempt to delete it with the Tunez.Music.destroy_artist function. The error return value would probably never be seen in practice, but just in case, we’ll show the user a nice message anyway.

[01/lib/tunez_web/live/artists/show_live.ex](http://media.pragprog.com/titles/ldash/code/01%2Flib%2Ftunez_web%2Flive%2Fartists%2Fshow_live.ex)

```elixir
 def handle_event("destroy-artist", _params, socket) do
 case Tunez.Music.destroy_artist(socket.assigns.artist) do
 :ok ->
 socket =
 socket
 |> put_flash(:info, "Artist deleted successfully")
 |> push_navigate(to: ~p"/")

 {:noreply, socket}

 {:error, error} ->
 Logger.info("Could not delete artist '#{socket.assigns.artist.id}':
   #{inspect(error)}")

 socket =
 socket
 |> put_flash(:error, "Could not delete artist")

 {:noreply, socket}
 end
 end
```

There are lots of different stylistic ways that this type of code could be written, but this is typically the way we would write it. If things go wrong, we want errors logged as to what happened, and we always want users to get feedback about what’s going on.

And that’s it! We’ve set up Ash in the Tunez app and implemented a full CRUD interface for our first resource, and we haven’t had to write much code to do it.

We’ve learned a bit about the declarative nature of Ash. We didn’t need to write functions that accepted parameters, processed them, saved the records, and so on—we didn’t need to write any functions at all. We declared what our resource should look like, where data should be stored, and what our actions should do. Ash has handled the actual implementations for us.

We’ve also seen how AshPhoenix provides a tidy Form pattern for integration with web forms, allowing for a streamlined integration with very little code.

In the next chapter, we’ll look at building a second resource and how the two can be integrated together!

Footnotes

<https://tunez.sevenseacat.net/>

<https://asdf-vm.com/>

<https://mise.jdx.dev/>

<https://hexdocs.pm/igniter/>

<https://hexdocs.pm/igniter_new/Mix.Tasks.Igniter.New.html>

<https://ash-hq.org/#get-started>

<https://hexdocs.pm/ash/domains.html>

<https://hexdocs.pm/ash_postgres/dsl-ashpostgres-datalayer.html>

<https://hexdocs.pm/ash/dsl-ash-datalayer-mnesia.html>

<https://hexdocs.pm/ash/dsl-ash-datalayer-ets.html>

<https://hexdocs.pm/ash_sqlite/>

<https://hexdocs.pm/ash_cubdb/>

<https://hexdocs.pm/ash/dsl-ash-resource.html#attributes>

<https://hexdocs.pm/ash/dsl-ash-resource.html#attributes-attribute>

<https://hexdocs.pm/ash/Mix.Tasks.Ash.Gen.Resource.html>

<https://hexdocs.pm/ash/Mix.Tasks.Ash.Codegen.html>

<https://hexdocs.pm/ash/generic-actions.html>

<https://hexdocs.pm/ash/Ash.Query.html>

<https://hexdocs.pm/ash/dsl-ash-domain.html#resources-resource-define-get_by>

<https://hexdocs.pm/ash/dsl-ash-resource.html#actions-default_accept>

<https://pragmaticstudio.com/courses/phoenix-liveview>

Copyright © 2025, The Pragmatic Bookshelf.
