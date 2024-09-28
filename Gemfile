source 'https://rubygems.org'

ruby File.read('.ruby-version')

gem 'activesupport'
gem 'dotenv'
gem 'hashie'
gem 'chronic'
gem 'chronic_duration'
gem 'addressable'

gem 'telegram-bot-ruby', git: 'git@github.com:brauliobo/telegram-bot-ruby.git'

gem 'rack' # for better mime type
gem 'roda'
gem 'puma'

if ENV['DB']
  gem 'pg'
  gem 'sequel'
end

gem 'mechanize'

gem 'whisper.cpp' if ENV['WHISPER']

group :development do
  gem 'pry'
end

