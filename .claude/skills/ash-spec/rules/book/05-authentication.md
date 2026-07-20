# 5. Authentication: Who Are You?

##  Chapter 5 Authentication: Who Are You?

In Chapter 4, we expanded Tunez with APIs—we now have HTML in the browser, REST JSON, and GraphQL. It was fun seeing how Ash’s declarative nature could be used to generate everything for us, using the existing domains, resources, and actions in our app.

But now it’s time to get down to serious business. The world is a scary place, and unfortunately, we can’t trust everyone in it to have free rein over the data in Tunez. We need to start locking down access to critical functionality to only trusted users, but we don’t yet have any way of knowing who those users are.

We can solve this by adding authentication to our app and requiring users to log in before they can create or modify any data. Ash has a library that can help with this, called …

## Introducing AshAuthentication

There are two parts to AshAuthentication—the core ash_authentication package, and the ash_authentication_phoenix Phoenix extension—to provide things like sign-up and registration forms. We’ll start with the basic library to get a feel for how it works and then add the web layer afterward.

This chapter will be a little different than everything we’ve covered so far because we won’t have to write much code until the later stages. The AshAuthentication installer will generate most of the necessary code into our app for us, and while we won’t have to modify a lot of it, it’s important to understand it. (And it’s there if we do need to modify it.)

Install AshAuthentication with Igniter:

```elixir
 $ mix  igniter.install  ash_authentication
```

This will generate a lot of code in several stages—so let’s break it down bit by bit.

|  |  |
|----|----|
|  | You may get an error here about the SAT solver installation. Ash requires an SAT solver to run authorization policies—by default, it will attempt to install picosat_elixir on non-Windows machines, but this can be rather complicated to set up. If you get an error, follow the prompts to uninstall picosat_elixir, and install simple_sat instead. |

### New Domain, Who’s This?

We’re now working with a whole different section of our domain model. Previously, we were building music-related resources, so we created a domain named Tunez.Music. Authentication is part of a separate system, an account management system, and so the generator will create a new domain called Tunez.Accounts. This domain will be populated with two new resources: Tunez.Accounts.User and Tunez.Accounts.Token.

The Tunez.Accounts.User resource, in lib/tunez/accounts/user.ex, is what will represent, well, users of your app. It comes preconfigured with AshPostgres as its data layer, so each user record will be stored in a row of the users database table.

By itself, the user resource doesn’t do much yet. It doesn’t even have any attributes, except an id. It does have some authentication-related configuration in the top-level authentication block, like linking the resource with tokens. This is what makes up most of the rest of the generated code.

### Tokens and Secrets and Config, Oh My!

Tokens, via the Tunez.Accounts.Token resource and the surrounding config, are the secret sauce to an AshAuthentication installation. Tokens are how we securely identify users—from an authentication token provided on every request (“I am logged in as rebecca”), to password reset tokens appended to links in emails, and more.

This is the part you really don’t want to get wrong when building a web app because the consequences could be pretty bad. If tokens are insecure, they could be spoofed by malicious users to impersonate other users and gain access to things they shouldn’t. So AshAuthentication generates all of the token-related code we need right up front before we do anything. For basic uses, we shouldn’t need to touch anything in the generated token code, but it’s there if we need to.

So how do we actually use all this code? We need to set up at least one authentication strategy.

## Setting Up Password Authentication

AshAuthentication supports a number of authentication strategies—ways we can identify users in our app. Traditionally, we think of logging in to an app via entering an email address and password, which is one of the supported strategies (the password strategy), but there’re several more. We can authenticate via different types of OAuth or even via magic links sent to a user’s email address.

Let’s set the password strategy up and get a feel for how it works. AshAuthentication comes with igniters to add strategies to our existing app, so you can run the following command:

```elixir
 $ mix  ash_authentication.add_strategy  password
```

This will add a lot more code to our app. We now have:

- Two new attributes for the Tunez.Accounts.User resource: email and hashed_password. The email attribute is also marked as an identity, so it must be unique.

- A strategies block added to the authentication configuration in the Tunez.Accounts.User resource. This lists the email attribute as the identity field for the strategy, and it also sets up the resettable option to allow users to reset their passwords.

- The confirmation add-on added to the add_ons block as part of the authentication configuration in the Tunez.Accounts.User resource. This will require users to confirm their email addresses by clicking on a link in their email when registering for an account or changing their email address.

- A whole set of actions in our Tunez.Accounts.User resource for signing in, registering, and resetting passwords.

- Two modules to handle sending email confirmation and password reset emails.

That’s a lot of goodies!

Because the tasks have created a few new migrations, run ash.migrate to get our database up-to-date:

```elixir
 $ mix  ash.migrate
```

There will be a few warnings from the email modules about the routes for password reset/email confirmation not existing yet—that’s okay, we haven’t looked at setting up AshAuthenticationPhoenix yet! But we can still test out our code with the new password strategy in an iex session to see how it works.

> **Don’t Try This in a Real App!**
> Don’t Try This in a Real App!
> Note that we’ll skip AshAuthentication’s built-in authorization policies for this testing by passing the authorize?: false option to Ash.create. This is only for testing purposes—the real code in our app won’t do this.

### Testing Authentication Actions in iex

One of the generated actions in the Tunez.Accounts.User resource is a create :register_with_password action, which takes email, password, and password_confirmation arguments and creates a user record in the database. It doesn’t have a code interface defined, but you can still run it by generating a changeset for the action and submitting it.

```elixir
 iex(1)> Tunez.Accounts.User
 Tunez.Accounts.User
 iex(2)> |> Ash.Changeset.for_create(:register_with_password, %{email: email,
 password: "supersecret", password_confirmation: "supersecret"})
 #Ash.Changeset<
 domain: Tunez.Accounts,
 action_type: :create,
 action: :register_with_password,
 ...
 >
 iex(3)> |> Ash.create!(authorize?: false)
 INSERT INTO "users" ("id","email","hashed_password") VALUES ($1,$2,$3)
 RETURNING "confirmed_at","hashed_password","email","id" [uuid,
 #Ash.CiString<email>, hashed password]
 several queries to generate tokens
 %Tunez.Accounts.User{
 id: uuid,
 email: #Ash.CiString<email>,
 confirmed_at: nil,
 __meta__: #Ecto.Schema.Metadata<:loaded, "users">
 }
```

Calling this action has done a few things:

- Inserted the new user record into the database, including securely hashing the provided password.

- Created tokens for the user to authenticate and also confirm their email address.

- Generated an email to send to the user to actually confirm their email address. In development, it won’t send a real email, but all of the plumbing is in place for the app to do so.

What can we do with our new user record? We can try to authenticate them using the created sign_in_with_password action. This mimics what a user would do on a login form, by entering their email address and password:

```elixir
 iex(9)> Tunez.Accounts.User
 Tunez.Accounts.User
 iex(10)> |> Ash.Query.for_read(:sign_in_with_password, %{email: email,
 password: "supersecret"})
 #Ash.Query<
 resource: Tunez.Accounts.User,
 action: :sign_in_with_password,
 arguments: %{password: "\redacted\", email: #Ash.CiString<email>},
 filter: #Ash.Filter<email == #Ash.CiString<email> and not
 is_nil(hashed_password) == "\redacted\">
 >
 iex(11)> |> Ash.read(authorize?: false)
 SELECT u0."id", u0."email", u0."confirmed_at", u0."hashed_password" FROM
 "users" AS u0 WHERE (u0."email"::citext = ($1::citext)::citext) AND (NOT
 (u0."hashed_password"::text IS NULL)) [email]
 {:ok, [%Tunez.Accounts.User{...}]}
```

And it works! AshAuthentication has validated that the credentials are correct by fetching any user records with the provided email, hashing the provided password, and verifying that it matches what is stored in the database. You can try it with different credentials, like an invalid password; AshAuthentication will properly return an error.

Calling sign_in_with_password with the correct credentials has also generated an authentication token in the returned user’s metadata to be stored in the browser and used to authenticate the user in the future.

```elixir
 iex(12)> {:ok, [user]} = v()
 {:ok, [%Tunez.Accounts.User{...}]}
 iex(13)> user.__metadata__.token
 "eyJhbGciOi..."
```

This token is a JSON Web Token, or JWT. It’s cryptographically signed by our app to prevent tampering—if a malicious user has a token and edits it to attempt to impersonate another user, the token will no longer verify. To test out the verification, we can use some of the built-in AshAuthentication functions like AshAuthentication.Jwt.verify/2 and AshAuthentication.subject_to_user/2:

```elixir
 iex(14)> AshAuthentication.Jwt.verify(user.__metadata__.token, :tunez)
 {:ok,
 %{
 "aud" => "~> 4.9",
 "exp" => 1754146714,
 "iat" => 1752937114,
 "iss" => "AshAuthentication v4.9.7",
 "jti" => string,
 "nbf" => 1752937114,
 "purpose" => "user",
 "sub" => "user?id=uuid"
 }, Tunez.Accounts.User}
```

The interesting parts of the decoded token here are the sub (subject) and the purpose. JWTs can be created for all kinds of purposes, and this one is for user authentication, hence the purpose “user”. The subject is a specially formatted string with a user ID in it, which we can verify belongs to a real user:

```elixir
 iex(15)> {:ok, claims, resource} = v()
 {:ok, %{...}, Tunez.Accounts.User}
 iex(16)> AshAuthentication.subject_to_user(claims["sub"], resource)
 SELECT u0."id", u0."confirmed_at", u0."hashed_password", u0."email" FROM
 "users" AS u0 WHERE (u0."id"::uuid::uuid = $1::uuid::uuid) [uuid]
 {:ok, %Tunez.Accounts.User{email: #Ash.CiString<your email>, ...}}
```

So when a user logs in, they’ll receive an authentication token. On subsequent requests, the user can provide this token as part of a header or a cookie, which our app will decode and verify—and voilà, we now know who they are. They’re logged in!

We don’t need to waste time with all of this, though. It’s good to know how AshAuthentication works and how to verify that it works, but we’re building a web app—we want forms that users can fill out to register or sign in. For that, we’ll use AshAuthentication’s sister library, AshAuthenticationPhoenix.

## Automatic UIs with AshAuthenticationPhoenix

As the name suggests, AshAuthenticationPhoenix is a library that connects AshAuthentication with Phoenix, providing a great LiveView-powered UI that we can tweak a little bit to fit our site look and feel, but otherwise don’t need to touch. Like other libraries, install it with Igniter:

```elixir
 $ mix  igniter.install  ash_authentication_phoenix
```

Ignoring the same warnings about some routes not existing (this will be the last time we see them!), the AshAuthenticationPhoenix installer will set up the following:

- A basic Igniter config file in .igniter.exs—this is the first generator we’ve run that needs specific configuration (for Igniter.Extensions.Phoenix), so it gets written to a file.

- A TunezWeb.AuthOverrides module that we can use to customize the look and feel of the generated liveviews (in lib/tunez_web/auth_overrides.ex).

- A TunezWeb.AuthController module to securely process sign-in requests (in lib/tunez_web/controllers/auth_controller.ex). This is due to a bit of a quirk in how LiveView works; it doesn’t have access to the user session to store data on successful authentication.

- A TunezWeb.LiveUserAuth module providing a set of hooks we can use in liveviews (in lib/tunez_web/live_user_auth.ex).

- Updating our web app router in lib/tunez_web/router.ex to add plugs and routes for all of our authentication-related functionality.

Before we can test it out, there’s one manual change we need to make as Igniter doesn’t (yet) know how to patch JavaScript or CSS files. AshAuthenticationPhoenix’s liveviews are styled with Tailwind CSS, so we need to add its liveview paths to Tailwind’s content lookup paths. Tunez is using Tailwind 4, configured via CSS, so you need to add the @source line under the list of other @source lines in assets/css/app.css.

[05/assets/css/app.css](http://media.pragprog.com/titles/ldash/code/05%2Fassets%2Fcss%2Fapp.css)

```elixir
 /\ ... \/
 @source "../../lib/tunez_web";
 @source "../../deps/ash_authentication_phoenix";

 @plugin "@tailwindcss/forms";
 /\ ... \/
```

Restart your mix phx.server, and then we can see what kind of UI we get by visiting the sign-in page at <http://localhost:4000/sign-in>.

It’s pretty good! Out of the box, we can sign in, register for new accounts, and request password resets.

After signing in, we get redirected back to the Tunez homepage—but there’s no indication that we’re now logged in, and there’s no link to log out. We’ll fix that now.

### Showing the Currently Authenticated User

It’s a common pattern for web apps to show current user information in the top-right corner of the page, so that’s what we’ll implement as well. The main Tunez navigation is part of the TunezWeb.Layouts.app function component, in lib/tunez_web/components/layouts.ex, so we can edit to add a new rendered user_info component:

[05/lib/tunez_web/components/layouts.ex](http://media.pragprog.com/titles/ldash/code/05%2Flib%2Ftunez_web%2Fcomponents%2Flayouts.ex)

```elixir
 
 
 <% # ... %>
 
 <.user_info current_user={@current_user} socket={@socket} />
 
```

This is an existing function component located in the same TunezWeb.Layouts module, and it shows sign-in/register buttons if there’s no user logged in, and a dropdown of user-related things if there is. But refreshing the app after making this change shows a big error:

```elixir
 key :current_user not found in: %{
 socket: #Phoenix.LiveView.Socket<...>,
 __changed__: %{...},
 page_title: "Artists",
 inner_content: %Phoenix.LiveView.Rendered{...},
 ...
```

Fixing this will require looking into how the new router code works.

#### Digging into AshAuthenticationPhoenix’s Generated Router Code

We didn’t actually go over the changes to our router in lib/tunez_web/router.ex after installing AshAuthenticationPhoenix—we just assumed everything was all good. For the most part it is, but there are one or two things we need to tweak.

The igniter added plugs to our pipelines to load the current user: load_from_bearer for our API pipelines and load_from_session for our browser pipeline. These are what will decode the user’s JWT token, load the authenticated user’s record, and store it in the request conn for us to use. This works for traditional non-liveview controller-based web requests that receive a request and send the response in the same process.

LiveView works differently, though. When a new request is made to a liveview, it spawns a new process and keeps that active WebSocket connection open for real-time data transfer. This new process doesn’t have access to the session, so although our base request knows who the user is, the spawned process doesn’t.

Enter live_session, and how it’s wrapped by AshAuthentication, ash_authentication_live_session. This macro will ensure when new processes are spawned, they get copies of the data in the session, so the app will continue working as expected.

What does this mean for Tunez? It means that all our liveview routes that are expected to have access to the current user need to be moved into the ash_authentication_live_session block in the router.

[05/lib/tunez_web/router.ex](http://media.pragprog.com/titles/ldash/code/05%2Flib%2Ftunez_web%2Frouter.ex)

```elixir
 scope "/", TunezWeb do
 pipe_through :browser

 # This is the block of routes to move
 live "/", Artists.IndexLive
 # ...
 live "/albums/:id/edit", Albums.FormLive, :edit

 auth_routes AuthController, Tunez.Accounts.User, path: "/auth"
 # ...
```

The ash_authentication_live_session helper is in a separate scope block in the router, earlier on in the file:

[05/lib/tunez_web/router.ex](http://media.pragprog.com/titles/ldash/code/05%2Flib%2Ftunez_web%2Frouter.ex)

```elixir
 scope "/", TunezWeb do
 pipe_through :browser

 ash_authentication_live_session :authenticated_routes do
 # This is the location that the block of routes should be moved to
 live "/", Artists.IndexLive
 # ...
 live "/albums/:id/edit", Albums.FormLive, :edit
 end
 end
```

With this change, our app should be renderable, and we should see information about the currently logged-in user in the top-right corner of the main navigation.

Now we can turn our attention to the generated liveviews themselves. We want them to look totally seamless in our app, as we wrote and styled them ourselves. While we don’t have control over the HTML that gets generated, we can customize a lot of the styling and some of the content using overrides.

### Stylin’ and Profilin’ with Overrides

Each liveview component in AshAuthenticationPhoenix’s generated views has a set of overrides configured that we can use to change things like component class names and image URLs.

When we installed AshAuthenticationPhoenix, a base TunezWeb.AuthOverrides module was created in lib/tunez_web/auth_overrides.ex. Here’s the syntax that we can use to set the different attributes that will then be used when the liveview is rendered:

[05/lib/tunez_web/auth_overrides.ex](http://media.pragprog.com/titles/ldash/code/05%2Flib%2Ftunez_web%2Fauth_overrides.ex)

```elixir
 # override AshAuthentication.Phoenix.Components.Banner do
 # set :image_url, "https://media.giphy.com/media/g7GKcSzwQfugw/giphy.gif"
 # set :text_class, "bg-red-500"
 # end
```

You can also use the link to see the complete list of overrides in the documentation.

Let’s test it out by changing the Sign In button on the sign-in page. It can be a bit tricky to find exactly which override will do what you want, but in this case, the submit button is an input, and under AshAuthentication.Phoenix.Components.Password.Input is an override for submit_class. Perfect.

In the overrides file, set a new override for that Input component:

[05/lib/tunez_web/auth_overrides.ex](http://media.pragprog.com/titles/ldash/code/05%2Flib%2Ftunez_web%2Fauth_overrides.ex)

```elixir
 defmodule TunezWeb.AuthOverrides do
 use AshAuthentication.Phoenix.Overrides

 override AshAuthentication.Phoenix.Components.Password.Input do
 set :submit_class, "bg-primary-600 text-white my-4 py-3 px-5 text-sm"
 end
```

Log out and return to the sign-in page, and the sign-in button will now be purple!

As any overrides we set will completely override the default styles, there may be more of a change than you expect. If you’re curious about what the default values for each override are, or you want to copy and paste them so you can only change what you need, you can see them in the AshAuthenticationPhoenix source code.

We won’t bore you with every single class change to make to turn a default AshAuthenticationPhoenix form into one matching the rest of the site theme, so we’ve provided a set of overrides to use in lib/tunez_web/auth_overrides_sample.txt. Take the full contents of that file and replace the contents of the TunezWeb.AuthOverrides module, like so:

[05/lib/tunez_web/auth_overrides.ex](http://media.pragprog.com/titles/ldash/code/05%2Flib%2Ftunez_web%2Fauth_overrides.ex)

```elixir
 defmodule TunezWeb.AuthOverrides do
 use AshAuthentication.Phoenix.Overrides
 alias AshAuthentication.Phoenix.Components

 override Components.Banner do
 set :image_url, nil
 # ...
```

And it should look like this:

Feel free to tweak the styles the way you like—Tunez is your app, after all!

### Why Do Users Always Forget Their Passwords!?

Earlier, we mentioned that the app was automatically generating an email to send to users after registration to confirm their accounts. Let’s see what that looks like!

When we added the password authentication to Tunez, AshAuthentication generated two modules responsible for generating emails—senders in AshAuthentication jargon. These live in lib/tunez/accounts/user/senders. One is for SendNewUserConfirmationEmail and the other one for SendPasswordResetEmail.

Phoenix apps come with a Swoosh integration built in for sending emails, and the generated senders have used that. Each sender module defines two critical functions: a body/1 private function that generates the content for the email and a send/3 that’s responsible for constructing and sending the email using Swoosh.

We don’t need to set up an email provider to send real emails while working in development. Swoosh provides a “mailbox” we can use—any emails sent, no matter the target email address, will be delivered to the dev mailbox (instead of actually being sent!). This dev mailbox is added to our router in dev mode only and can be accessed at <http://localhost:4000/dev/mailbox>.

The mailbox is empty by default, but if you register for a new account via the web app and then refresh the mailbox, you get this:

The email contains a link to confirm the email address, which, sure, is totally my email address, and I did sign up for the account, so open the link in a new tab. You’ll be redirected to a confirmation screen in the Tunez app, with a button to click to ensure that you do want to verify your account. If you click it, you’ll be back on the app homepage, with a flash message letting us know that your email address is now confirmed. Success!

## Setting Up Magic Link Authentication

Some users nowadays think that passwords are just so passé, and they’d much prefer to be able to log in using magic links instead—enter their email address, click the login link that gets sent straight to their inbox, and they’re in. That’s no problem!

AshAuthentication doesn’t limit our apps to only one method of authentication; we can add as many as we like from the supported strategies or even write our own. So there’s no problem with adding the magic link strategy to our existing password-strategy-using app, and users can even log in with either strategy depending on their mood. Let’s go.

To add the strategy, run the ash_authentication.add_strategy Mix task:

```elixir
 $ mix  ash_authentication.add_strategy  magic_link
```

This will do the following:

- Add a new magic_link authentication strategy block to our Tunez.Accounts.User resource, in lib/tunez/accounts/user.ex.

- Add two new actions named sign_in_with_magic_link and request_magic_link, also in our Tunez.Accounts.User resource.

- Remove the allow_nil? false on the hashed_password attribute in the Tunez.Accounts.User resource (users that sign in with magic links won’t necessarily have passwords!).

- Add a new sender module responsible for generating the magic link email, in lib/tunez/accounts/user/senders/send_magic_link_email.ex.

The magic_link config block in the Tunez.Accounts.User resource lists some sensible values for the strategy configuration, such as the identity attribute (email by default). There are more options that can be set, such as how long generated magic links are valid for (token_lifetime), but we won’t need to add anything extra to what is generated here.

A migration was generated for the allow_nil? false change on the users table, so you’ll need to run that:

```elixir
 $ mix  ash.migrate
```

Wait … that’s it? Yep, that’s it. The initial setup of AshAuthentication generates a lot of code for the initial resources, but adding subsequent strategies typically only needs a little bit.

Once you’ve added the strategy, visiting the sign-in page will have a nice surprise:

Is it really that simple? If we fill out the magic link sign-in form with the same email address we confirmed earlier, an email will be delivered to our dev mailbox with a sign-in link to click. Click the link, and after confirming the login, you should be back on the Artist catalog, with a flash message saying that you’re now signed in. Awesome!

But you might not be signed in automatically. You might be back on the sign-in page, with a generic “incorrect email or password” message that doesn’t give away any secrets. If not, you can force an error by logging out and visiting the magic link a second time. Now you’ll get an error! How can we tell what’s happening behind the scenes?

### Debugging When Authentication Goes Wrong

Although showing a generic failure message is good in production for security reasons—for example, we want to protect an account’s email address from potentially bad actors—it’s not good in development while you’re trying to debug issues and make things work.

To get more information about what’s going on, enable authentication debugging for our development environment only by placing the following at the bottom of config/dev.exs:

[05/config/dev.exs](http://media.pragprog.com/titles/ldash/code/05%2Fconfig%2Fdev.exs)

```elixir
 config :ash_authentication, debug_authentication_failures?: true
```

Restart your mix phx.server to apply the new config change, and visit the same magic link URL again. You should see a big yellow warning in your server logs:

```elixir
 [warning] Authentication failed:
 Bread Crumbs:
 > Error returned from: Tunez.Accounts.User.sign_in_with_magic_link

 Forbidden Error

 * Invalid magic_link token
 (ash_authentication x.x.x) lib/ash_authentication/errors/invalid_token.ex:5:
 AshAuthentication.Errors.InvalidToken.exception/1
 ...
```

Aha! Now we know! The magic link token has either already been used or has expired. Either way, it’s not valid anymore.

Without turning the AshAuthentication debugging on, these kinds of issues would be nearly impossible to fix. It’s safe to leave it enabled in development, as long as you don’t mind the warning about it during server start. If the warning is too annoying, feel free to turn debugging off, but don’t forget that it’s available to you!

And that’s all we need to do to implement magic link authentication in our apps. Users will be able to create accounts via magic links and also log into their existing accounts that were created with an email and password. Our future users will thank us!

### Can We Allow Authentication over Our APIs?

In the previous chapter, we built two shiny APIs that users can use to programmatically access Tunez and its data. To make sure the APIs have full feature parity with the web UI, we need to make sure they can register and sign in via the API as well. When we start locking down access to critical parts of the app, we don’t want API users to be left out!

Let’s give it a try and see how far we can get. We’ll start with adding registration support in our JSON API.

To add JSON API support to our Tunez.Accounts.User resource, we can extend it using Ash’s extend patcher:

```elixir
 $ mix  ash.extend  Tunez.Accounts.User  json_api
```

This will configure our JSON API router, domain module, and resource with everything we need to start connecting routes to actions. To create a POST request to our register_with_password action, we can add a new route to the domain, as we did with [*Adding Albums to the API*](#f_0035.xhtml_ch04.albums_to_api). We’ve customized the actual URL with the route option to create a full URL like /api/json/users/register.

[05/lib/tunez/accounts.ex](http://media.pragprog.com/titles/ldash/code/05%2Flib%2Ftunez%2Faccounts.ex)

```elixir
 defmodule Tunez.Accounts do
 use Ash.Domain, extensions: [AshJsonApi.Domain]

 json_api do
 routes do
 base_route "/users", Tunez.Accounts.User do
 post :register_with_password, route: "/register"
 end
 end
 end

 # ...
 end
```

Looks good so far! But if you try it in an API client, or using cURL, correctly supplying all the arguments that the action expects, it won’t work; it always returns a forbidden error. Drat.

This is because at the moment, the Tunez.Accounts.User resource is tightly secured. All of the actions are restricted to only be accessible via AshAuthenticationPhoenix’s form components. (Or if we skip authorization checks, like we [did earlier,](#f_0039.xhtml_ch05_authorize_false). That was for test purposes only!)

This is good for security reasons—we don’t want any old code to be able to do things like change people’s passwords! But it makes our development lives a little bit harder because to understand how to allow the functionality we want, we need to dive into our next topic, authorization. Buckle up, this may be a long one …

Footnotes

<https://codingnest.com/modern-sat-solvers-fast-neat-underused-part-1-of-n/>

<https://hexdocs.pm/ash_authentication/get-started.html#choose-your-strategies-and-add-ons>

<https://jwt.io/>

<https://hexdocs.pm/ash_authentication_phoenix/ui-overrides.html#reference>

<https://github.com/team-alembic/ash_authentication_phoenix/blob/main/lib/ash_authentication_phoenix/overrides/default.ex>

<https://hexdocs.pm/swoosh/>

<https://hexdocs.pm/ash_authentication/get-started.html#choose-your-strategies-and-add-ons>

<https://hexdocs.pm/ash_authentication/dsl-ashauthentication-strategy-magiclink.html#options>

<https://hexdocs.pm/ash_json_api/dsl-ashjsonapi-domain.html#json_api-routes-base_route-post>

Copyright © 2025, The Pragmatic Bookshelf.
