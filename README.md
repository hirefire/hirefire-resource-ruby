## [HireFire](http://hirefire.io/) - Autoscaling for your Heroku dynos

Load-based scaling, schedule-based scaling, dyno crash recovery, for [Heroku](http://heroku.com/) web- and worker dynos.

---

It supports practically any worker library. We provide out-of-the-box support for:

* Delayed Job
* Resque
* Qu
* QueueClassic
* Sidekiq
* Bunny

*Note that you can write your own worker queue logic for almost any other worker library as well.
HireFire can scale multiple individual worker libraries at the same time, as well as multiple individual queues for any worker library.*

It supports practically any Rack-based application or framework, such as:

* Ruby on Rails
* Sinatra
* Padrino
* Bare Rack Apps

We provide convenient macros for the above mentioned worker libraries to calculate the queue size for each of them.
If you wish to conribute more macros for other existing worker libraries feel free to send us a pull request.

Here is an example with Ruby on Rails 3. First, add the gem to your `Gemfile`:

```ruby
gem "hirefire-resource"
```

Then, all you have to do is create an initializer in `config/initializers/hirefire.rb` and add the following:

```ruby
HireFire::Resource.configure do |config|
  config.dyno(:resque_worker) do
    HireFire::Macro::Resque.queue
  end

  config.dyno(:dj_worker) do
    HireFire::Macro::Delayed::Job.queue(mapper: :active_record)
  end
end
```

This will allow HireFire to read out the queues for both Resque and Delayed Job. By default these macros will count all the queues combined if you are using multiple
different queues for each worker library. You can also pass in specific queues to count, like so:

```ruby
HireFire::Resource.configure do |config|
  config.dyno(:resque_worker) do
    HireFire::Macro::Resque.queue(:mail, :backup)
  end

  config.dyno(:dj_worker) do
    HireFire::Macro::Delayed::Job
      .queue(:encode, :compress, mapper: :active_record)
  end
end
```

This will tell HireFire to count the total amount of jobs from the `mail` and `backup` queue for the `resque_worker` dyno, and the `encode` and `compress` queues for the `dj_worker` dyno.
The `resque_worker` refers to the `resque_worker` in your `Procfile`, and the `dj_worker` refers to the `dj_worker` in the `Procfile`. In this case the `Procfile` would look something like this:

```
resque_worker: QUEUE=mail,backup bundle exec rake resque:work
dj_worker: QUEUES=encode,compress bundle exec rake jobs:work
```

Now that HireFire will scale both of the these dyno types based on their individual queue sizes. To customize how they scale, log in to the HireFire web interface.

Visit the [official website](http://www.hirefire.io/) for more information!

### License

hirefire-resource is released under the Apache 2.0 license. See LICENSE.
