# Front Matter — Foreword, Acknowledgments, Welcome

# Ash Framework

## Create Declarative Elixir Web Apps

## by Rebecca Le, Zach Daniel

Version: P1.0 (August 2025)

Copyright © 2025 The Pragmatic Programmers, LLC. This book is licensed to the individual who purchased it. We don't copy-protect it because that would limit your ability to use it for your own purposes. Please don't break this trust—you can use this across all of your devices but please do not share this copy with other members of your team, with friends, or via file sharing services. Thanks.

Many of the designations used by manufacturers and sellers to distinguish their products are claimed as trademarks. Where those designations appear in this book, and The Pragmatic Programmers, LLC was aware of a trademark claim, the designations have been printed in initial capital letters or in all capitals. The Pragmatic Starter Kit, The Pragmatic Programmer, Pragmatic Programming, Pragmatic Bookshelf and the linking *g* device are trademarks of The Pragmatic Programmers, LLC.

Every precaution was taken in the preparation of this book. However, the publisher assumes no responsibility for errors or omissions, or for damages that may result from the use of information (including program listings) contained herein.

## About the Pragmatic Bookshelf

The Pragmatic Bookshelf is an agile publishing company. We’re here because we want to improve the lives of developers. We do this by creating timely, practical titles, written by programmers for programmers.

Our Pragmatic courses, workshops, and other products can help you and your team create better software and have more fun. For more information, as well as the latest Pragmatic titles, please visit us at <http://pragprog.com>.

Our ebooks do not contain any Digital Restrictions Management, and have always been DRM-free. We pioneered the beta book concept, where you can purchase and read a book while it’s still being written, and provide feedback to the author to help make a better book for everyone. Free resources for all purchasers include source code downloads (if applicable), errata and discussion forums, all available on the book's home page at pragprog.com. We’re here to make your life easier.

### New Book Announcements

Want to keep up on our latest titles and announcements, and occasional special offers? Just create an account on [pragprog.com](https://pragprog.com) (an email address and a password is all it takes) and select the checkbox to receive newsletters. You can also follow us on twitter as @pragprog.

### About Ebook Formats

If you buy directly from [pragprog.com](https://pragprog.com), you get ebooks in all available formats for one price. You can synch your ebooks amongst all your devices (including iPhone/iPad, Android, laptops, etc.) via Dropbox. You get free updates for the life of the edition. And, of course, you can always come back and re-download your books when needed. Ebooks bought from the Amazon Kindle store are subject to Amazon's polices. Limitations in Amazon's file format may cause ebooks to display differently on different devices. For more information, please see our FAQ at [pragprog.com/#about-ebooks](https://pragprog.com/support/#about-ebooks). To learn more about this book and access the free resources, go to <https://pragprog.com/book/ldash>, the book's homepage.

Thanks for your continued support,

The Pragmatic Bookshelf

The team that produced this book includes: Dave Thomas (Publisher)Janet Furlow (COO)Susannah Davidson (Executive Editor)Series editor: Sophie DeBenedettoKelly Lee (Development Editor)Corina Lebegioara (Copy Editor)Potomac Indexing, LLC (Indexing)Gilson Graphics (Layout)

For customer support, please contact .

For international rights, please contact <rights@pragprog.com>.

In loving memory of Monty.

We miss your fluffy presence every single day.

- - Rebecca

Copyright © 2025, The Pragmatic Bookshelf.

# Early Praise for *Ash Framework: Create Declarative Elixir Web Apps*

*Ash Framework: Create Declarative Elixir Web Apps* is an exciting addition to our community; well written, understandable, and full of hard-won wisdom from years of building with Ash. Bravo Rebecca and Zach!

|     |                                                          |
|-----|----------------------------------------------------------|
| →   | James Harton                                             |
|     | Principal Consultant at Alembic and Ash core team member |

A fantastic introduction to Ash. It is clear, practical, and confidence-inspiring. I went from zero experience to feeling ready to use Ash in production.

This book is the best place to start for anyone curious about Ash. It’s approachable, engaging, and never overwhelming.

|     |                    |
|-----|--------------------|
| →   | Kathryn Prestridge |
|     | Software Developer |

A thorough and engaging introduction to the world of Ash!

|     |                  |
|-----|------------------|
| →   | Nicholas Moen    |
|     | Elixir Developer |

##  Foreword

Congratulations!

You’re about to read a book that I believe will fundamentally change how you think about building software.

It’s often mistaken for one, but Ash isn’t a web framework, it’s an application framework. The Ash tagline “Model your domain, derive the rest” describes it succinctly once you understand how it works, so let’s quickly unpack what that means.

The big idea behind Ash is surprisingly simple: express your domain model using the Domain Specific Language (DSL) that Ash provides, and then Ash encodes it as an introspectible data structure. Then, as if by magic, an incredible vista of time-saving opportunities opens up to you. You can generate anything you like!

Ash has many ways to do this already as pre-built extensions: Data Layers, Admin UIs, APIs, Authentication, and the list goes on. You can also build your own extensions. What exists today is merely a taste of what’s possible—the only limit is your imagination. Since anything can be derived, it can seem overwhelming at first. Don’t worry, you’re in good hands.

The Lisp programmers of old have often taken a similar approach: build a DSL for the problem at hand, then build the solution using that. Ash generalizes and extends this approach, making it accessible to everyone. It’s a convenient syntax for expressing your domain and a consistent way to specify your application’s behavior in a way that can be analyzed, transformed, and extended.

My Ash journey was not a straight path. As Alembic’s Technical Director, I looked for opportunities to try Ash on a client project for years. We eventually tried it out on an ambitious and complex client project because we thought it could help generate a GraphQL API and build an Admin UI without much code. On closer inspection, Ash did way more than what it said on the tin. The client architect and I both eventually came to the same conclusion—we couldn’t contemplate building such a large application without something like Ash, and we definitely didn’t want to build it from scratch.

Our version of Greenspun’s tenth rule of programming is as follows:

> Any sufficiently large software application contains an ad hoc, informally specified, bug-ridden, slow implementation of half of Ash.

It’s funny because it’s true—when applications grow beyond a certain size, developers inevitably start building frameworks to manage complexity. They create utilities for common patterns, abstractions for repeated logic, and tools for generating boilerplate. Ash provides all of this out of the box, in a well-tested, battle-hardened package.

Don’t tell anyone, but Ash is our secret sauce. Since then, Ash has been our preferred stack for large-scale projects, and our clients are loving the benefits. Elixir is our preferred language ecosystem because it’s incredibly efficient. We’ll build software using other technologies, but it’s never quite as simple, comfortable, or efficient. We also deeply believe in open source software because it’s fundamentally a positive sum game. When improvements are made to the ecosystem, all projects can immediately benefit—a rising tide indeed lifts all boats!

For three years, Rebecca has worked on some of the most ambitious client projects Alembic has built. She was one of the first at turning her hand at building large Elixir applications with Ash and has the scar tissue to prove it. Her work has informed the development of Ash into the polished product it is today. She is an exemplary technical communicator, and you’ll feel like you’re in an extremely safe pair of hands as you work your way through this book. I certainly did!

Zach, the creator of the Ash Framework, has been building the ecosystem for over five years. He works tirelessly to make Ash better every day. His vision for what Ash could be has evolved through constant feedback from real-world usage. His commitment to maintaining and improving the framework is remarkable. What started as a tool for generating APIs has grown into a comprehensive framework for building robust, maintainable applications.

Together, they bring both a deep architectural understanding and the practical experience of building real-world applications. This combination means you’re getting both the “why” and the “how”—the theoretical underpinnings that make Ash powerful and the practical knowledge of how to use it effectively.

By the time you finish this book, you’ll have a new perspective on how to manage complexity in software applications. You’ll see how making your domain model explicit and introspectible opens up new possibilities for building and maintaining software. Whether you’re building a small service or a large enterprise application, the ideas in this book will help you create more maintainable, consistent, and powerful software.

I’m personally delighted to have been a small part of the journey so far and am very excited about where we can take this in future.

Let’s build something amazing together!

Josh Price

Founder and Technical Director, Alembic

Sydney, Australia, February 2025

Footnotes

<https://philip.greenspun.com/research/>

Copyright © 2025, The Pragmatic Bookshelf.

#  Acknowledgments

Writing a book like this takes so much more than two authors putting words and code on the page.

We’d like to thank the amazing team at PragProg that has worked with us and supported us every step of the way. First and foremost, our intrepid editor, Kelly Lee, as well as Dave Thomas, Sophie DeBenedetto, Margaret Eldridge, Susannah Davidson, Juliet Thomas, Corina Lebegioara, and Devon Thomas.

Many reviewers helped us out by reading and providing feedback on even the earliest versions of each chapter. Thank you to James Harton, Kathryn Prestridge, Mike Buhot, Stefan Wintermeyer, Daniel Pipkin, Nicholas Moen, Peter Wurm, Thomas Fejes, Andrew Ek, and Chaz Watkins.

And finally, to all of our readers: thank you for picking up this book and giving Ash a chance. You are the reason we write.

## Rebecca Le

What a wild ride this has been! I’ll keep this short and sweet.

Thank you to Jeff Chan, who has always told me to go for it and has made me a better developer, communicator, and leader. You’ve dragged me out of the mud and talked me off the metaphorical ledge more times than I can count, and I sincerely appreciate it.

Thank you to the fluffy feline members of my family, Monty, Scooter, and Ziggy; who try their best to get me to take regular breaks and give them lots of attention. Your cuddles (and sometimes claws) keep me grounded and help me breathe.

Many thanks to Zach for bringing us this amazing framework and tirelessly supporting it every day. For fixing all my bugs, letting me rant and whinge (and curse his name) every now and then, coming up with game-changing ideas, and pushing me wayyyyy out of my comfort zone. The book is better for all of it!

But most importantly, thank you to my awesome husband, Thuc. Words can’t express how much you mean to me, but I can only try. You’re the Boston Rob to my Amber, the Stoinis to my Zampa, the potato to my gravy. This book is for you.

Well, it’s for the boys too. But mostly for you.

## Zach Daniel

First and foremost, always, my wife, Meredith. Without her, nothing that I do would be possible. She bears the burden of my work just as much as I and has supported me unreservedly. I never truly understood happiness, the deep and boundless kind, before her.

I count among my blessings a family that values kindness, excellence, and good humor. To my family, Mom, Dad, Allison, Kat, Ann, and Dave, who shaped me and continue to inspire me to be the best that I can be.

To my furry family, who are little goblins that I could not possibly live without. They are the best reminders to get my head out of my laptop. Pippin, Kuma, Juno, Zeus, Rory, and Khloe (yes, I live in a zoo).

To Brandon, who has sacrificed too many of our online gaming nights to count on account of my work obsession. He is the most steadfast friend one could ask for.

To Geena, who took a chance on me and hired me for my first ever job in tech. A boss turned lifelong friend, whose company and counsel I value dearly.

To James, who, knowing that I will work myself to the bone if left to my own devices, sends me pictures of him and his dogs playing in the river to remind me that there is more to life than code.

To Rebecca, who is far and above the mastermind behind this book. Put simply, my job here is the tech. Her keen eye and the process of writing this book have refined and improved Ash in immeasurable ways. The spirit in this book, the educational value, and the wordsmithing are all to her credit. It has been my privilege to work alongside her.

To my colleagues at Alembic and to its leadership, Josh and Suzie, who have believed in Ash since it was barely a diamond in the rough. It’s a pleasure to work among such great minds.

Copyright © 2025, The Pragmatic Bookshelf.

#  Welcome!

As software developers, we face new and interesting challenges daily. When one of these problems appears, our instincts are to start building a mental model of the solution. The model might contain high-level concepts, ideas, or things that we know we want to represent, and ways they might communicate with each other to carry out the desired task.

Your next job is to find a way to map this model onto the limitations of the language and frameworks available to you. But there’s a mismatch: your internal model is a fairly abstract representation of the solution, but the tooling you use demands specific constructs, often dictated by things such as database schemas and APIs.

These problems are hard, but they’re not intractable—they can be solved by using a framework like Ash.

Ash lets you think and code at a higher level of abstraction, and your resulting code will be cleaner, easier to manage, and you’ll be less frustrated.

This book will show you the power of Ash and how to get the most out of it in your Elixir projects.

## What Is Ash?

Ash is a set of tools you can use to describe and build the domain model of your applications—the “things” that make up what your app is supposed to do, and the business logic of how they relate and interact with each other. If you’re building an e-commerce store, your domain model will have things like products, categories, suppliers, orders, customers, deliveries, and more; and you’ll already have a mental model to describe how they fit together. Ash is how you can translate that mental model into code, using standardized patterns and your own terminology.

Ash is a fantastic application framework, but it is not a web framework. This question comes up often, so we want to be clear up front—Ash doesn’t replace Phoenix, Plug, or any other web framework when building web apps in Elixir. It does, however, slide in nicely alongside them and work with them, and when combined they can make the ultimate toolkit for building amazing apps.

What can Ash offer an experienced Elixir/Phoenix developer? You’re already familiar with a great set of tools for building web applications today, and Ash builds on that foundation that you know and love. It leverages the rock-solid Ecto library for its database integrations, and its resource-oriented design helps bring structure and order to the Wild West of Phoenix contexts. If this sounds interesting to you, keep reading!

And if you’re only just starting on your web development journey, we’d love to introduce you to our battle-tested and highly productive stack!

## Why Ash?

Ash is built on three fundamental principles. These principles are rooted in the concept of declarative design and have arisen from direct encounters with the good, bad, and the ugly of software in the wild. They are:

- Data > Code
- Derive > Hand-write
- What > How

To paraphrase a famous manifesto, while there is value in the items on the right, we value the items on the left more.

No principle is absolute, and each has its own trade-offs, but together they can help us build rich, maintainable, and scalable applications. The “why” of Ash is rooted in the “why” of each of these core principles.

### Data > Code

With Ash, we model (describe) our application components with resource modules, using code that compiles into predefined data structures. These resources describe the interfaces to, and behavior of, the various components of our application.

Ash can take the data structures created by these descriptions and use them to do wildly useful things with little to no effort. Also, Ash contains tools that allow you to leverage your application-as-data to build and extend your application in fully custom ways. You can introspect and use the data structures in your own code, and you can even write transformers to extend the language that Ash uses and add new behavior to existing data.

Taking advantage of these superpowers requires learning the language of Ash Framework, and this is what we’ll teach you in this book.

### Derive > Hand-write

We emphasize deriving application components from our descriptions, instead of handwriting our various application layers. When building a JSON API, for example, you might end up handwriting controllers, serializers, OpenAPI schemas, error handling, and the list goes on. If you want to add a GraphQL API as well, you have to do it all over again with queries, mutations, and resolvers. In Ash, this is all driven from your resource definitions, using them as the single source of truth for how your application should behave. Why should you need to restate your application logic in five different ways?

There is value in the separation of these concerns, but that value is radically overshadowed by all of the associated costs, such as:

- The cost of bugs via functionality drift in your various components

- The cost of the conceptual overhead required to implement changes to your application and each of its interfaces

- The cost, especially, of every piece of your application being a special snowflake with its own design, idiosyncrasies, and patterns

When you see what Ash can derive automatically, without all of the costly spaghetti code necessary with other approaches, the value of this idea becomes very clear.

### What > How

This is the core principle of declarative design, and you’ve almost certainly leveraged this principle already in your time as a developer without even realizing it.

Two behemoths in the world of declarative design are HTML and SQL. When writing code in either language, you don’t describe how the target is to be achieved, only what the target is. For HTML, a renderer is in charge of turning your HTML descriptions into pixels on a screen; and for SQL, a query planner and engine are responsible for translating your queries into procedural code that reads data from storage.

An Ash resource behaves in the exact same way, as a description of the what. All of the code in Ash is geared towards looking at the descriptions of what you want to happen, and making it so. This is a crucial thing to keep in mind as you go through this book—when we write resources, we are only describing their behavior. Later, when we actually call the actions we describe, or connect them to an API using an API extension, for example, Ash looks at the description provided to determine what is to be done.

These principles, and the insights we derive from them, might take some time to comprehend and come to terms with. As we go through the more concrete concepts presented in this book, revisit these principles. Ash is more than just a new tool; it’s a new way of thinking about how we build applications in general.

We’ve seen time and time again, especially in our in-person workshops, that everyone has a moment when these concepts finally click. This is when Ash stops feeling like magic and begins to look like what it actually is: the principles of declarative design, taken to their natural conclusion.

Model your domain, and derive the rest.

## Is This Book for You?

If you’ve gotten this far, then yes, this book is for you!

If you have some experience with Elixir and Phoenix, have heard about this library called Ash, and are keen to find out more, then this book is definitely for you.

If you’re a grizzled Elixir veteran wondering what all the Ash fuss is about, it’s also for you!

If you’ve already been working with Ash, even professionally, you’ll still learn new things from this book (but you can read it a bit faster).

If you haven’t used Elixir before, this book is probably not for you yet—but it might be soon! To learn about this amazing functional programming language, we highly recommend working through [*Elixir in Action* [Jur15]](#f_0072.xhtml_d2814e2). To get a feel for how modern web apps are built in Elixir with Phoenix and Phoenix LiveView, [*Programming Phoenix LiveView* [TD25]](#f_0072.xhtml_d2814e73) will get you up to speed. And then you can come back here, and keep reading!

## What’s in This Book

This book is divided into ten chapters, each one building on top of the previous to flesh out the domain model for a music database. We’ll provide the starter Phoenix LiveView application to get up and running, and then away we’ll go!

In Chapter 1, [*Building Our First Resource*](#f_0017.xhtml_ch01.start), we’ll set up the Tunez starter app, install and configure Ash, and get familiar with CRUD actions. We’ll build a full (simple) resource, complete with attributes, actions, and a database table; and integrate those actions into the web UI using forms and code interfaces.

In Chapter 2, [*Extending Resources with Business Logic*](#f_0021.xhtml_ch02.start), we’ll create a second resource and learn about linking resources together with relationships. We’ll also cover more advanced features of resources, like preparations, validations, identities, and changes.

In Chapter 3, [*Creating a Better Search UI*](#f_0027.xhtml_ch03.start), we’ll focus on features for searching, sorting, and pagination to make our main catalog view much more dynamic. We’ll also start to unlock some of the true power of Ash by deriving new attributes with calculations and aggregates.

In Chapter 4, [*Generating APIs Without Writing Code*](#f_0033.xhtml_ch04.start), we’ll see the principle of “model your domain, and derive the rest” in action when we learn how to create full REST JSON and GraphQL APIs from our existing resource and action definitions. It’s not magic, we swear!

In Chapter 5, [*Authentication: Who Are You?*](#f_0037.xhtml_ch05.start), we’ll set up authentication for Tunez, using the AshAuthentication library. We’ll cover different strategies for authentication like username/password and logging in via magic link, as well as customizing the auto-generated liveviews to make them seamless.

In Chapter 6, [*Authorization: What Can You Do?*](#f_0042.xhtml_ch06.start), we’ll introduce authorization into the app, using policies and bypasses. We’ll see how we can define a policy once and use it throughout the entire app, from securing our APIs to showing and hiding UI buttons and more.

In Chapter 7, [*Testing Your Application*](#f_0049.xhtml_ch07.start), we’ll tackle the topic of testing—what should we test in an app built with Ash, and how should we do it? We’ll go over some testing strategies, see what tools Ash provides to help with testing, and cover practical examples of testing Ash and LiveView apps.

In Chapter 8, [*Having Fun With Nested Forms*](#f_0055.xhtml_ch08.start), we’ll dig a little deeper into Ash’s integration with Phoenix, by expanding our domain model and building a nested form, including drag and drop re-ordering for nested records.

In Chapter 9, [*Following Your Favorite Artists*](#f_0061.xhtml_ch09.start), we’ll explore many-to-many relationships to allow users to follow their favorite artists. We’ll improve our code interface game to create some nice functions for following and unfollowing, and use the new follower information in some surprising ways!

And finally, in Chapter 10, [*Delivering Real-Time Updates with PubSub*](#f_0065.xhtml_ch10.start), we’ll use everything we’ve learned so far to build a user notification system. Using bulk actions for efficiency and pubsub for broadcasting real-time updates, we’ll create a simple yet robust system that allows for expansion as your apps grow.

## Online Resources

All online resources for this book, such as errata and code samples, can be found on the Pragmatic Bookshelf product page:

<https://pragprog.com/titles/ldash/ash-framework/>

We also invite you to join the greater Ash community if you’d like to learn more or contribute to the project and ecosystem: <https://ash-hq.org/community>

And on that note, let’s dig in! We’ve got a lot of exciting topics to cover and can’t wait to get started!

Copyright © 2025, The Pragmatic Bookshelf.
