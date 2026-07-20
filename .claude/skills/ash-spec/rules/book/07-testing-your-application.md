# 7. Testing Your Application

##  Chapter 7 Testing Your Application

While working on Tunez, we’ve been doing lots of manual testing of our code. We’ve called functions in iex, verified the results, and loaded the web app in a browser to click around. This is fine while we figure things out, but it won’t scale as our app grows. For that, we can look at automated testing.

There are two main reasons to write automated tests:

- To confirm our current understanding of our code. When we write tests, we’re asserting that our code behaves in a certain way. This is what we’ve been doing so far.

- To protect against unintentional change. When we make changes to our code, it’s critical to understand the impact of those changes. The tests now serve as a safety net to prevent regressions in functionality or bugs being introduced.

A common misconception about testing Ash applications is that you don’t need to write as many tests as you would if you had handwritten all of the features that Ash provides for you. This isn’t the case: it’s important to confirm our understanding and to protect against unintentional change when building with Ash. Just because it’s much easier to build our apps, it doesn’t mitigate the necessity for testing.

In this chapter, we won’t cover how to use ExUnit to write unit tests in Elixir. There are entire books written on testing, such as [*Testing Elixir* [LM21]](#f_0072.xhtml_d2814e33). For LiveView-specific advice, there’s also a great section in [*Programming Phoenix LiveView* [TD25]](#f_0072.xhtml_d2814e73), and libraries like PhoenixTest to make it smoother. What we will focus on is as follows:

- How to set up and execute tests against Ash resources.
- What helpers Ash provides to assist in testing.
- What kinds of things you should test in applications built with Ash.

> There’s no code for you to write in this chapter—Tunez comes with a full set of tests preprepared, but they’re all skipped and commented out (to prevent compilation failures). As we go through this chapter, you can check them out and un-skip and uncomment the tests that cover features we’ve written so far.
> For the remaining chapters in this book, we’ll point out the tests that cover the functionality we’re going to build.

## What Should We Test?

“What do we test?” is a question that Ash can help answer. Ultimately, every interface in Ash stems from our action definitions. This means that the vast majority of our testing should center around calling our actions and making assertions about the behavior and effects of those actions. We should still write tests for our API interfaces, but they don’t necessarily need to be comprehensive. One caveat to this is that if you’re developing a public API, you may want to be more rigorous in your testing. We’ll cover this in more detail shortly.

Additionally, Ash comes with tools and patterns that allow you to unit test various elements of your resource. Since an example is worth a thousand words, let’s use some of these tools.

### The Basic First Test

One of the best first tests to write for a resource is the empty read case—when there is no stored data, nothing is returned. This test may seem kind of obvious, but it can detect problems in your test setup, such as leftover data that isn’t being deleted between tests. It can also help identify when something with your action is broken that has nothing to do with the data in your data layer.

```elixir
 defmodule Tunez.Music.ArtistTest do
 use Tunez.DataCase, async: true

 describe "Tunez.Music.read_artists!/0-2" do
 test "when there is no data, nothing is returned" do
 assert Tunez.Music.read_artists!() == []
 end
 end
 end
```

We can call the code interface functions defined for our actions and directly assert on the result. Provide inputs, and verify outputs. It sounds so simple when written like that!

> While our code interfaces are on the Tunez.Music domain module, and not the Tunez.Music.Artist resource module, it would make for a very long and hard-to-navigate test file to include all the tests for the domain in one test module.
> It’s generally better to split up tests into smaller groups. Here we’re testing actions on the Tunez.Music.Artist resource, so we have one module only for those. This isn’t a requirement, but it leads to better test organization.

For more complicated actions (that is, nearly all of them), we’ll need a way of setting up the data and state required.

## Setting Up Data

For artist actions like search or update, we’ll need some records to exist in the data layer before we can run our actions and check the results. There are two approaches to this:

- Setting up test data using your resource actions
- Seeding data directly via the data layer, bypassing actions

### Using Actions to Set Up Test Data

The first approach is to do what we’ve already been doing throughout this book: calling resource actions. These tests can be seen as a series of events.

```elixir
 # Demonstration test only
 # There are tests for this action in Tunez, but not written like this!
 defmodule Tunez.Music.ArtistTest do
 # ...

 describe "Tunez.Music.search_artists!/1-3" do
 test "can find artists by partial name match" do
 artist = Tunez.Music.create_artist!(%{
 name: "The Froody Dudes",
 biography: "42 musicians all playing the same instrument (a towel)"
 }, authorize?: false)

 assert %{results: [match]} = Tunez.Music.search_artists!("Frood")
 assert match.id == artist.id
 end
 end
 end
```

First, we create an artist, and then we assert that we get that same artist back when we search for it. When in doubt, start with these kinds of tests.

We’re testing our application’s behavior in the same way that it actually gets used. And because we’re building with Ash, and our APIs and web UIs go through the same actions, we don’t need to write extensive tests covering each different interface—we can test the action thoroughly and then write simpler smoke tests for each of the interfaces that use it.

(Writing out action calls with full data can be tedious and prone to breakage, though. We’ll cover ways of addressing this in [*Consolidating Test Setup Logic*](#f_0052.xhtml_ch07.setup_logic).)

#### Pro: We Are Testing Real Sequences of Events

If something changes in the way that our users create artists that affects whether or not they show up in the search results, our test will reflect that. This is more akin to testing a “user story” than a unit test (albeit a very small user story).

This can also be a con: if something breaks in the Tunez.Music.Artist create action, every test that creates artist records as part of their setup will suddenly start failing. If this happens, though, all tests that aren’t specifically for that action should point directly to it as the cause.

#### Con: Real Application Code Has Rules and Dependencies

Let’s imagine that we have a new app requirement that new artists could only be created on Tuesdays. If we wrote a custom validation module named IsTuesday and called it in the Artist create action, suddenly our test suite would only pass on Tuesdays!

There are ways around this, such as using a private argument to determine whether to run the validation or not. This can then be specifically disabled in tests by passing in the option private_arguments: %{validate_tuesday: false} when building a changeset or calling a code interface function.

```elixir
 create :create do
 argument :validate_tuesday, :boolean, default: true, public?: false
 validate IsTuesday, where: argument_equals(:validate_tuesday, true)
 end
```

You could also introduce a test double in the form of a mock with an explicit contract, with different implementations based on the environment. This is also commonly used for replacing external dependencies in either dev or test. We’ve already used an example of this with the Swoosh mailer, in [*Why Do Users Always Forget Their Passwords!?*](#f_0040.xhtml_ch05.swoosh). In production, it will send real emails (if we connected a suitable adapter) but in dev/test it uses an in-memory adapter instead.

If all else fails, you can fall back to a library like mimic, that performs more traditional mocking (“mocking” as a verb).

#### Pro: Your Application Is End-to-End Testable

If you have the time and resources to go through the steps we just mentioned to ensure that actions with complex validations or external dependencies are testable, then this strategy is the best approach. Our tests are all doing only real, valid action calls, and we can have much more confidence in them.

With all of that said, there are still cases where we would want to set up our tests by working directly against the data layer.

### Seeding Data

The other method of setting up our tests is to use seeds. Seeds bypass action logic, going straight to the data layer. When using AshPostgres, this essentially means performing an INSERT statement directly. The only thing that Ash can validate when using seeds is attribute types, and the allow_nil? option, because they’re implemented at the database level. If you’ve used libraries like ex_machina, this is the strategy they use.

When should you reach for seeds to set up test data instead of calling resource actions? Imagine that we’ve realized that a lot of Tunez users are creating artists with incomplete biographies, just like the word “Hi.” To fix this, we’ve decided that all biographies must have at least three sentences.

So we write another custom validation module called SentenceCount and add it to the validations block of our Artist resource like validate {SentenceCount, field: :biography, min: 3}, so it applies to all actions. Ship it! Oops, we’ve just introduced a subtle bug. Can you spot it?

In this hypothetical scenario, when a user tries to update the name of an artist that has a too-short biography saved, they’ll get an error about the biography. That’s not a great user experience. Luckily, it’s an easy fix. We can tweak the validation to only apply when the biography is being updated:

```elixir
 validations do
 validate {SentenceCount, field: :biography, min: 3} do
 where changing(:biography)
 end
 end
```

To write a test for this fix, we need a record with a short biography in the database to make sure the validation doesn’t get triggered if it’s not being changed. We don’t want to add a new action just to allow for the creation of bad data. This is a perfect case for inserting data directly into the data layer using seeds.

In this example, we use Ash.Seed to create an artist that wouldn’t normally be allowed to be created.

```elixir
 # Demonstration test only - this validation doesn't exist in Tunez!
 describe "Tunez.Music.update_artist!/1-3" do
 test "when an artist's name is updated, the biography length does
  not cause a validation error" do
 artist =
 Ash.Seed.seed!(
 %Tunez.Music.Artist{
 name: "The Froody Dudes",
 biography: "42 musicians all playing the same instrument (a towel)."
 }
 )

 updated_artist = Tunez.Music.update_artist!(artist, %{name: "New Name"})
 assert updated_artist.name == "New Name"
 end
 end
```

#### Pro: Your Tests Are Faster and Simpler

Ash.Seed goes directly to the data layer, so any action logic, policies, or notifiers will be skipped. It can be easier to reason about what your test setup actually does. You can think more simply in terms of the data you need, and not the steps required to create it. If a call to Ash.Seed.seed! succeeds, you know you’ve written exactly that data to the data layer.

For the same reason, this will always be at least a little faster than calling actions to create data. For actions that do a lot of validation or contain hooks to call other actions, using seeds can be much faster.

#### Con: Your Tests Are Not as Realistic

While writing test setup using real actions makes setup more complicated, it also makes them more valuable and more correct. When testing with seed data, it’s easy to accidentally create data that has no value to test against because it’s not possible to create under normal app execution. In Tunez, we could seed artists that were created by users with the role of :user or :editor, which definitely violates our authorization rules. Or we could set a user role that doesn’t even exist! (This has actually happened.) What is testing the validity of the test data?

Depending on the situation, this can be worse than just wasted code. It can mislead you into believing that you’ve tested a part of your application that you haven’t. It can also be difficult to know when you’ve changed something in your actions that should be reflected in your tests because your test setup bypasses actions.

### How Do I Choose Between Seeds and Calling Actions?

When both will do what you need, consider what you’re trying to test. Are you testing a data condition, such as the validation example, or are you testing an event, such as running a search query? If the former, then use seeds. If the latter, use your resource actions. When in doubt, use actions.

## Consolidating Test Setup Logic

Ash.Generator provides tools for dynamically generating various kinds of data. You can generate action inputs, queries, and even complete resource records, without having to specify values for every single attribute. We can use Ash.Generator to clean up our test setup and to clearly distinguish our setup code from our test code.

The core functionality of Ash.Generator is built using the StreamData library and the generator/1 callback on Ash.Type. You can test out any of Ash’s built-in types, using Ash.Type.generator/2:

```elixir
 iex(1)> Ash.Type.generator(:integer, min: 1, max: 100)
 #StreamData<66.1229758/2 in StreamData.integer/1>
 iex(2)> Ash.Type.generator(:integer, min: 1, max: 100) |> Enum.take(10)
 [21, 79, 33, 16, 15, 95, 53, 27, 69, 31]
```

The generator returns an instance of StreamData, which is a lazily evaluated stream of random data that matches the type and constraints specified. To get generated data out of the stream, we can evaluate it using functions from the Enum module.

Ash.Generator also works for more complex types, such as maps with a set format:

```elixir
 iex(1)> Ash.Type.generator(:map, fields: [
 hello: [
 type: {:array, :integer},
 constraints: [min_length: 2, items: [min: -1000, max: 1000]]
 ],
 world: [type: :uuid]
 ]) |> Enum.take(1)
 [%{hello: [-98, 290], world: "2368cc8d-c5b6-46d8-97ab-1fe1d9e5178c"}]
```

Ash.Generator.action_input/3 can be used to generate sets of valid inputs for actions, and Ash.Generator.changeset_generator/3 builds on top of that to generate whole changesets for calling actions. That sounds like an idea …

### Creating Test Data Using Ash.Generator

We can use the tools provided by Ash.Generator to build a Tunez.Generator module for test data. Using changeset_generator/3, we can write functions that generate streams of changesets for a specific action, which can then be modified further if necessary or submitted to insert the records into the data layer.

Let’s start with a user generator. To create different types of users, we would need to create changesets for the register_with_password action of the Tunez.Accounts.User resource, submit them, and then maybe update their roles afterward with Tunez.Accounts.set_user_role. We can follow a very similar pattern using options for changeset_generator/3.

The key point to keep in mind is that our custom generators should always return a stream: the test calling the generator should always be able to decide if it needs one record or one hundred.

```elixir
 defmodule Tunez.Generator do
 use Ash.Generator

 def user(opts \ []) do
 changeset_generator(
 Tunez.Accounts.User,
 :register_with_password,
 defaults: [
 # Generates unique values using an auto-incrementing sequence
 # eg. `user1@example.com`, `user2@example.com`, etc.
 email: sequence(:user_email, &"user#{&1}@example.com"),
 password: "password",
 password_confirmation: "password"
 ],
```

```elixir
 overrides: opts,
 after_action: fn user ->
 role = opts[:role] || :user
 Tunez.Accounts.set_user_role!(user, role, authorize?: false)
 end
 )
 end
 end
```

To use our shiny new generator in a test, the test module can import Tunez.Generator and then we can use the provided generate or generate_many functions:

```elixir
 # Demonstration test - this is only to show how to call generators!
 defmodule Tunez.Accounts.UserTest do
 import Tunez.Generator

 test "can create user records" do
 # Generate a user with all default data
 user = generate(user())

 # Or generate more than one user, with some specific data
 two_admins = generate_many(user(role: :admin), 2)
 end
 end
```

As we’re forwarding the generator’s opts directly to changeset_generator/3 as overrides for the default data, we could also include a specific email address or password, if we wanted. The generate functions use Ash.create! to process the changeset, so if something goes wrong, we’ll know immediately. This is pretty clean!

We can write a generator for artists similarly. Creating an artist needs some additional data to exist in the data layer: an actor to create the record. We can pass an actor in via opts, or we can call our user generator within the artist generator.

One pitfall of calling the user generator directly is that we would get a user created for each artist we create. That might be what you want, but most of the time, it’s unnecessary. To solve this, Ash.Generator provides the once/2 helper function: it will call the supplied function (in which we can generate a user) exactly once and then reuse the value for subsequent calls in the same generator.

```elixir
 def artist(opts \ []) do
 actor = opts[:actor] || once(:default_actor, fn ->
 generate(user(role: :admin))
 end)

 changeset_generator(
 Tunez.Music.Artist,
 :create,
 defaults: [name: sequence(:artist_name, &"Artist #{&1}")],
 actor: actor,
 overrides: opts
 )
 end
```

If we don’t pass in an actor when generating artists, even if we generate a million artists, they’ll all have the same actor. Efficient!

Now we can tie it all together to create an album factory. We can follow the same patterns as before, accepting options to allow customizing the generator and massaging the generated inputs to be acceptable by the action.

```elixir
 def album(opts \ []) do
 actor = opts[:actor] || once(:default_actor, fn ->
 generate(user(role: opts[:actor_role] || :editor))
 end)

 artist_id = opts[:artist_id] || once(:default_artist_id, fn ->
 generate(artist()).id
 end)

 changeset_generator(
 Tunez.Music.Album,
 :create,
 defaults: [
 name: sequence(:album_name, &"Album #{&1}"),
 year_released: StreamData.integer(1951..2024),
 artist_id: artist_id,
 cover_image_url: nil
 ],
 overrides: opts,
 actor: actor
 )
 end
```

If we need to seed data instead of using changesets with actions, Ash.Generator also provides seed_generator/2. This can be used in a very similar way, except instead of providing a resource/action, you provide a resource struct:

```elixir
 def seeded_artist(opts \ []) do
 actor = opts[:actor] || once(:default_actor, fn ->
 generate(user(role: :admin))
 end)
```

```elixir
 seed_generator(
 %Tunez.Music.Artist{name: sequence(:artist_name, &"Artist #{&1}")},
 actor: actor,
 overrides: opts
 )
 end
```

This is a drop-in replacement for the artist generator, so you can still call functions like generate_many(seeded_artist(), 3). You could even put both seed and changeset generators in the same function and switch between them based on an input option. It’s a flexible pattern that allows you to generate exactly the data you need, in an explicit yet succinct way, and with the most confidence that what you’re generating is real.

Armed with our generator, we’re ready to start writing more tests!

## Testing Resources

As we discussed earlier, the interfaces to our app all stem from our resource definitions. The code interfaces we define are the only thing external sources know about our app and how it works, so it makes sense that most of our tests will revolve around calling actions and verifying what they do. We’ve already seen a brief example when we wrote [our first empty-case test,](#f_0050.xhtml_ch07.first_test), and now we’ll write some more.

### Testing Actions

Our tests will follow a few guidelines:

- Prefer to use code interfaces when calling actions
- Use the raising “bang” versions of code interfaces in tests
- Avoid using pattern matching to assert the success or failure of actions
- For asserting errors, use Ash.Test.assert_has_error or assert_raise
- Test policies, calculations, aggregates and relationships, changesets, and queries separately if necessary

The reasons for using code interfaces in tests are the same as in our application code, and they’ll help us detect when changes to our resources require changes in our tests. Using the bang versions of functions that support it will keep our tests simple and give us better error messages when something goes wrong. Avoiding pattern matching helps with error messages and also increases the readability of our tests.

Some of the more interesting actions we might want to test are the Artist search action (including filtering and sorting), and the Artist update action (for storing previous names and recording who made the change). What might those look like with our new generators?

```elixir
 # This can also be added to the `using` block in `Tunez.DataCase`
 import Tunez.Generator

 describe "Tunez.Music.search_artists/1-2" do
 defp names(page), do: Enum.map(page.results, & &1.name)

 test "can filter by partial name matches" do
 ["hello", "goodbye", "what?"]
 |> Enum.each(&generate(artist(name: &1)))

 assert Enum.sort(names(Music.search_artists!("o"))) == ["goodbye", "hello"]
 assert names(Music.search_artists!("oo")) == ["goodbye"]
 assert names(Music.search_artists!("he")) == ["hello"]
 end
```

The test uses the generators we just wrote, so we’re assured that we’re looking at real (albeit trivial) data. What about something a bit more complex, like testing one of the aggregate sorts we added?

```elixir
 test "can sort by number of album releases" do
 generate(artist(name: "two", album_count: 2))
 generate(artist(name: "none"))
 generate(artist(name: "one", album_count: 1))
 generate(artist(name: "three", album_count: 3))

 actual =
 names(Music.search_artists!("", query: [sort_input: "-album_count"]))

 assert actual == ["three", "two", "one", "none"]
 end
```

The artist generator we wrote doesn’t currently have an album_count option. (It won’t raise an error, but it won’t do anything.) For something like this that feels like common behavior, we can always add one. We can add an after_action to the call to changeset_generator to generate the number of albums we want for the artist.

```elixir
 def artist(opts \ []) do
 # ...

 after_action =
 if opts[:album_count] do
 fn artist ->
 generate_many(album(artist_id: artist.id), opts[:album_count])
 Ash.load!(artist, :albums)
 end
 end
```

```elixir
 # ...
 changeset_generator(
 Tunez.Music.Artist, :create,
 defaults: [name: sequence(:artist_name, &"Artist #{&1}")],
 actor: actor, overrides: opts,
 after_action: after_action
 )
 end
```

We haven’t specified any overrides for the albums to be generated. If you want to do that (for example, specify that the albums were released in a specific year), we recommend not using this option and generating the albums separately in your test.

If your generators become complex enough, you may even want to write tests for them to ensure that if we pass in something like album_count, the generated artist has the related data that we expect.

### Testing Errors

Testing errors is a critical part of testing your application, but it can also be kind of inconvenient. Actions can produce many different kinds of errors, and sometimes even multiple errors at once.

ExUnit comes with assert_raise built in for testing raised errors, and Ash also provides a helper function named Ash.Test.assert_has_error. assert_raise is good for quick testing to say “When I do X, it fails for Y reason,” while assert_has_error allows for more granular verification of the generated error.

The most common errors in Tunez right now are data validation errors, and we can write tests for those:

```elixir
 test "year_released must be between 1950 and next year" do
 admin = generate(user(role: :admin))
 artist = generate(artist())

 # The assertion isn't really needed here, but we want to signal to
 # our future selves that this is part of the test, not the setup.
 assert %{artist_id: artist.id, name: "test 2024", year_released: 2024}
 |> Music.create_album!(actor: admin)

 # Using `assert_raise`
 assert_raise Ash.Error.Invalid, ~r/must be between 1950 and next year/, fn ->
 %{artist_id: artist.id, name: "test 1925", year_released: 1925}
 |> Music.create_album!(actor: admin)
 end

 # Using `assert_has_error` - note the lack of bang to return the error
 %{artist_id: artist.id, name: "test 1950", year_released: 1950}
 |> Music.create_album(actor: admin)
 |> Ash.Test.assert_has_error(Ash.Error.Invalid, fn error ->
 match?(%{message: "must be between 1950 and next year"}, error)
 end)
 end
```

There are a few more examples of validation testing in the Tunez.Music.AlbumTest module—including how to use Ash.Generator.action_input to generate valid action inputs (according to the constraints defined). Check them out!

### Testing Policies

If you test anything at all while building an app, test your policies. Policies typically define the most critical rules in your application and should be tested rigorously.

We can use the same tools for testing policies as we did in our liveview templates for showing/hiding buttons and other content—[Ash.can?,](#f_0047.xhtml_ch06.can), and the helper functions generated for code interfaces, can_*?. These run the policy checks for the actions and return a boolean. Can the supplied actor run the actions according to the policy checks, or not? For testing policies for create, update, and destroy actions, these make for simple and expressive tests.

Note that we’re using refute for the last three assertions in the test. These users can’t create artists!

```elixir
 test "only admins can create artists" do
 admin = generate(user(role: :admin))
 assert Music.can_create_artist?(admin)

 editor = generate(user(role: :editor))
 refute Music.can_create_artist?(editor)

 user = generate(user())
 refute Music.can_create_artist?(user)

 refute Music.can_create_artist?(nil)
 end
```

Testing policies for read actions looks a bit different. These policies typically result in filters, not yes/no answers, meaning that we can’t test “can the user run this action?” The answer is usually “yes, but nothing is returned if they do.” For these kinds of tests, we can use the data option to test that a specific record can be read.

Let’s say that we get a new requirement that users should be able to look up their own user records and admins should be able to look up any user record by email address. This could be over an API or in the UI; for our purposes, it is not important (and the Ash code looks the same).

The Tunez.Accounts.User resource already has a get_by_email action, but it doesn’t have any specific policies associated. We can add a new policy specifically for that action:

```elixir
 policy action(:get_by_email) do
 authorize_if expr(id == ^actor(:id))
 authorize_if actor_attribute_equals(:role, :admin)
 end
```

This action already has a code interface defined, which we added in the previous chapter:

```elixir
 resource Tunez.Accounts.User do
 # ...

 define :get_user_by_email, action: :get_by_email, args: [:email]
 end
```

Now we can test the interface with the auto-generated can_get_user_by_email? function. Using the data option tells Ash to check the authorization against the provided record or records. It’s roughly equivalent to running the query with any authorization filters applied and checking to see if the given record or records are returned in the results.

```elixir
 # Demonstration tests only - this functionality doesn't exist in Tunez!
 test "users can only read themselves" do
 [actor, other] = generate_many(user(), 2)

 # this assertion would fail, because the actor \can\ run the action
 # but it \wouldn't\ return the other user record
 # refute Accounts.can_get_user_by_email?(actor, other.email)

 assert Accounts.can_get_user_by_email?(actor, actor.email, data: actor)
 refute Accounts.can_get_user_by_email?(actor, other.email, data: other)
 end

 test "admins can read all users" do
 [user1, user2] = generate_many(user(), 2)
 admin = generate(user(role: :admin))

 assert Accounts.can_get_user_by_email?(admin, user1.email, data: user1)
 assert Accounts.can_get_user_by_email?(admin, user2.email, data: user2)
 end
```

You should test your policies until you’re confident that you’ve fully covered all of their variations, and then add a few more tests just for good measure!

### Testing Relationships and Aggregates

Ash doesn’t provide any special tools to assist in testing relationships or aggregates because none are needed. You can set up some data in your test, load the relationship or aggregate, and then assert something about the response.

But we’ll use this opportunity to show how you can use authorize?: false to test or bypass your policies for the purpose of testing. A lot of the time, you’ll likely want to skip authorization checking when loading data, unless you’re specifically testing your policies around that data.

```elixir
 # Demonstration test only - this functionality doesn't exist in Tunez
 test "users cannot see who created an album" do
 user = generate(user())
 album = generate(album())

 # We \can\ load the user record if we skip authorization
 assert Ash.load!(album, :created_by, authorize?: false).created_by

 # If this assertion fails, we know that it must be due to authorization
 assert Ash.load!(album, :created_by, actor: user).created_by
 end
```

### Testing Calculations

Calculations often contain important application logic, so it can be important to test them. You can test them the same way you test relationships and aggregates—load them on a record and verify the results—but you can also test them in total isolation using Ash.calculate/3.

To show this, we’ll add a temporary calculation to the Tunez.Music.Artist resource that calculates the length of the artist’s name using the string_length function:

```elixir
 defmodule Tunez.Music.Artist do
 # ...

 calculations do
 calculate :name_length, :integer, expr(string_length(name))
 end
 end
```

If we wanted to use this calculation “normally,” we would have to construct or load an Artist record and then load the data:

```elixir
 iex(1)> artist = %Tunez.Music.Artist{name: "Amazing!"} |>
 Ash.load!(:name_length)
 #Tunez.Music.Artist<...>
 iex(2)> artist.name_length
 8
```

Using Ash.calculate/3, we can call the calculation directly, passing in a map of references, or refs—data that the calculation needs to be evaluated.

```elixir
 iex(30)> Ash.calculate!(Tunez.Music.Artist, :name_length,
 refs: %{name: "Amazing!"})
 8
```

The name_length calculation only relies on a name field, so the rest of the data of any Artist record doesn’t matter. This makes it simpler to set up the data required.

This also works for calculations that require the database, such as those written using database fragments. Let’s rewrite our name_length calculation using the PostgreSQL’s length function:

```elixir
 calculations do
 calculate :name_length, :integer, expr(fragment("length(?)", name))
 end
```

We could still call it in iex or in a test, only needing to pass in the name ref:

```elixir
 iex(3)> Ash.calculate!(Tunez.Music.Artist, :name_length,
 refs: %{name: "Amazing!"})
 SELECT (length($1))::bigint FROM (VALUES(1)) AS f0 ["Amazing!"]
 8
```

You can even define code interfaces for calculations. This combines the benefits of Ash.calculate/3 with the benefits of code interfaces.

We’ll use define_calculation to define a code interface for our trusty name_length calculation, in the Tunez.Music domain module. A major difference here is how we specify arguments for the code interface compared with defining code interfaces for actions. Because calculations can also accept arguments, they need to be formatted slightly differently. Each of the code interface arguments should be in a tuple, tagging it as a ref or an arg. Our name is a ref, a data dependency of the calculation.

```elixir
 resource Tunez.Music.Artist do
 ...
 define_calculation :artist_name_length, calculation: :name_length,
 args: [{:ref, :name}]
 end
```

This exposes the name_length calculation defined on the Tunez.Music.Artist resource, as an artist_name_length function on the domain module. If the calculation name and desired function name are the same, the calculation option can be left out.

```elixir
 # Demonstration test only - this function doesn't exist in Tunez!
 test "name_length shows how many characters are in the name" do
 assert Tunez.Music.artist_name_length!("fred") == 4
 assert Tunez.Music.artist_name_length!("wat") == 3
 end
```

Imagine we put a limit on the length of an artist’s name or some other content like a blog post. You could use this calculation to display the number of characters remaining next to the text box while the user is typing, without visiting the database. Then, if you changed the way you count characters in an artist’s name, like perhaps ignoring the spaces between words, the logic will be reflected in your view in any API interface that uses that information and even in any query that uses the calculation.

### Unit Testing Changesets, Queries, and Other Ash Modules

The last tip for testing Ash is that you can unit test directly against an Ash.Changeset, Ash.Query, or by calling functions directly on the Ash.Resource.Change and Ash.Resource.Query modules.

For example, if we want to test our validations for year_released, we don’t necessarily need to go through the rigamarole of setting up test data and trying to call actions if we don’t want to. We have a few other options.

We could directly build a changeset for our actions and assert that it has a given error. It doesn’t matter that it also has other errors. We only care that it has one matching what we’re testing.

```elixir
 # Demonstration test only - this is covered by action tests in Tunez
 test "year_released must be greater than 1950" do
 Album
 |> Ash.Changeset.for_create(:create, %{year_released: 1920})
 |> assert_has_error(fn error ->
 match?(%{message: "must be between 1950 and" <> _}, error)
 end)
 end
```

We can apply this exact logic to Ash.Query and Ash.ActionInput to unit test any piece of logic that Ash does eagerly as part of running an action. We can test directly against the modules that we define, as well. Let’s write a test that calls into our artist UpdatePreviousNames change.

```elixir
 # Demonstration test only - this is covered by action tests in Tunez
 # This won't work for logic in hook functions - only code in a change body
 test "previous_names store the current name when changing to a new name" do
 changeset =
 %Artist{name: "george", previous_names: ["fred"]}
 |> Ash.Changeset.new()
 # `opts` and `context` aren't used by this change, so we can
 # leave them empty
 |> Tunez.Music.Changes.UpdatePreviousNames.change([], %{})

 assert Ash.Changeset.changing_attribute?(changeset, :previous_names)
 assert {:ok, ["george", "fred"]} = Ash.Changeset.fetch_change(changeset,
 :previous_names)
```

As you can see, there are numerous places where you can drill down for more specific unit testing as needed. This brings us to a reeeeeally big question …

### Should I Actually Unit Test Every Single One of These Things?

Realistically? No.

Not every single variation of everything needs its own unit test. You can generally have a lot of confidence in your tests by calling your resource actions and making assertions about the results. If you have an action with a single change on it that does a little validation or data transformation, test the action directly. You’ve exercised all of the code, and you know your action works. That’s what you care about, anyway!

You only need to look at unit testing individual parts of your resource if they grow complex enough that you have trouble understanding them in isolation. If you find yourself wanting to write many different combinations of inputs to exercise one part of your action, perhaps that part should be tested in isolation.

## Testing Interfaces

All of the tests we’ve looked at so far have centered around our resources. This is the most important type of testing because it extends to every interface that uses our resources. If the number 5 is an invalid argument value when calling an action, that property will extend to any UI or API we use to call that action. This doesn’t mean that we shouldn’t test those higher layers.

What it does allow us to do is to be a bit less rigorous in testing these generated interfaces. If we’ve tested every action, validation, and policy at the Ash level, we only need to test some basic interactions at the UI/API level to get the most bang for our buck.

### Testing GraphQL

Since AshGraphql is built on top of the excellent absinthe library, we can use its great utilities for testing. It offers three different approaches for testing either resolvers, documents, or HTTP requests.

Ash actions take the place of resolvers, so any tests we write for our actions will cover that facet. Our general goal is to have several end-to-end HTTP request-response sanity tests to verify that the API as a whole is healthy and separate schema-level tests for different endpoints. These will quickly surface errors if any types happen to accidentally change. We’ve written some examples of these tests in test/tunez_web/graphql/, so you can see what we mean.

We also highly recommend setting up your CI process (such as GitHub Actions) to guard against accidental changes to your API schema. This can be done by generating a known-good schema definition once with the absinthe.schema.sdl Mix task and committing it to your repository. During your build process, you can run the task again into a separate file and compare the two files to ensure no breaking changes.

### Testing AshJsonApi

Everything we previously said for testing a GraphQL API applies to testing an API built with AshJsonApi as well. Since we generate an OpenAPI specification for your API, you can even use the same strategy for guarding against breaking changes.

The main difference when testing APIs built with AshJsonApi is that under the hood they use Phoenix controllers, so we can use Phoenix helpers for controller tests. There are also some useful helpers in the AshJsonApi.Test module that you can import to make your tests more streamlined. There are some examples of tests for our JSON API endpoints in Tunez, in lib/tunez_web/json_api/.

### Testing Phoenix LiveView

Testing user interfaces is entirely different than anything else that we’ve discussed thus far. There are whole books dedicated solely to this topic. LiveView itself has many testing utilities, and often when testing LiveView, we’re testing much more than the functionality of our application core.

It’s unrealistic to cover all (or even most) of the UI testing patterns that exist here, for LiveView or otherwise. We’ve written a set of tests using our preferred PhoenixTest library, in the test/tunez_web/live folder of Tunez. These include tests for the Artist, Album forms, and the Artist catalog, including the pagination, search, and sort functionality.

This should help you get your feet wet, and the documentation for PhoenixTest and Phoenix.LiveViewTest will take you the rest of the way.

And that’s a wrap! This was a whirlwind tour through all kinds of testing that we might do in our application. There are a lot more tests available in the Tunez repo (along with some that cover functionality that we haven’t built yet), far too many to go over in this chapter.

All of the tools that Ash works with, like Phoenix and Absinthe, have their own testing utilities and patterns that you’ll want to spend some time learning as you go along. The primary takeaway is that you’ll get the most reward for your effort by doing your heavy and exhaustive testing at the resource layer.

Testing is a very important aspect of building any software, and that doesn’t change when you’re using Ash. Tests are investments that pay off by helping you understand your code and protect against unintentional change in the future.

In the next chapter, we’ll switch back to writing some new features to enhance our domain model. We’ll look at adding track listings for albums, adding calculations for track and album durations, and learn how AshPhoenix can help make building nested forms a breeze.

Footnotes

<https://hexdocs.pm/ex_unit>

<https://hexdocs.pm/phoenix_test/>

<https://dashbit.co/blog/mocks-and-explicit-contracts>

<https://hexdocs.pm/swoosh/Swoosh.html#module-adapters>

<https://hexdocs.pm/mimic/>

<https://hexdocs.pm/ex_machina/>

<https://hexdocs.pm/ash/Ash.Generator.html>

<https://elixir-lang.org/blog/2017/10/31/stream-data-property-based-testing-and-data-generation-for-elixir/>

<https://hexdocs.pm/ash/Ash.Type.html>

<https://hexdocs.pm/elixir/Stream.html>

<https://hexdocs.pm/ash/Ash.Generator.html#changeset_generator/3>

<https://hexdocs.pm/ash/Ash.Generator.html#generate/1>

<https://hexdocs.pm/ash/Ash.Generator.html#seed_generator/2>

<https://hexdocs.pm/ex_unit/ExUnit.Assertions.html#assert_raise/2>

<https://hexdocs.pm/ash/Ash.Test.html>

<https://hexdocs.pm/ash/Ash.Generator.html#action_input/3>

<https://hexdocs.pm/ash/Ash.html#calculate/3>

<https://hexdocs.pm/ash/expressions.html#functions>

<https://hexdocs.pm/ash_postgres/expressions.html>

<https://hexdocs.pm/ash/dsl-ash-domain.html#resources-resource-define_calculation>

<https://hexdocs.pm/ash/calculations.html#arguments-in-calculations>

<https://hexdocs.pm/absinthe/testing.html>

<https://hexdocs.pm/ash_json_api/AshJsonApi.Test.html>

<https://hexdocs.pm/phoenix_test/>

<https://hexdocs.pm/phoenix_live_view/Phoenix.LiveViewTest.html>

Copyright © 2025, The Pragmatic Bookshelf.
