# Setting up `TuringBot`:

1. Register on the ultrahook website to get an API key and username.
2. Download and install [Ruby](https://www.ruby-lang.org/en/downloads/). 
3. Download [RubyGems](https://rubygems.org/pages/download) and extract the folder rubygems-x.x.x.
4. In a command prompt, call `~/Rubyxx-xxx/bin/ruby rubygems-x.x.x/setup.rb`.
5. Run `~/Rubyx-xxx/bin/gem ultrahook`
6. Run `echo "api_key: API_KEY" > ~/.ultrahook`, replacing `API_KEY` with the unique key from step 1.
6. CD into `~/Rubyxx-xxx/lib/ruby/gems/x.x.x/gems/ultrahook-x.x.x`, and run `ultrahook github port_number`, replacing `port_number` with the port number you would like to listen to events on, e.g. 8000.
7. Add the following url to the webhook of the repository you want to listen on: `http://github.username.ultrahook.com` replacing `username` with the username you registered in step 1.
8. CD into your favorite working directory and run `git clone https://github.com/mohamed82008/TuringBot.jl TuringBot`.
9. Get an authentication token from Github.
10. Open a Julia session and run:
```julia
] activate ./TuringBot
ENV["GITHUB_USERNAME"] = "username"
ENV["GITHUB_AUTH"] = "auth_token"
```
replacing `username` with your Github username, and `auth_token` with your unique access token. Make sure the token has commenting, push and pull request access.
11. In the same Julia session, run:
```julia
using TuringBot
TuringBot.listen(port)
```
where `port` is the port you used in step 6. It is taken to be 8000 by default.
