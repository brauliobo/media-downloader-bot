source 'https://rubygems.org'

ruby File.read('.ruby-version')

def path_for p; p if ENV['LOCAL_GEMS']; end

gem 'activesupport'
gem 'dotenv'
gem 'hashie'
gem 'chronic'
gem 'chronic_duration'

gem 'iso-639'

gem 'telegram-bot-ruby', git: 'git@github.com:brauliobo/telegram-bot-ruby.git'

gem 'rack' # for better mime type
gem 'roda'
gem 'puma'
gem 'drb'

gem 'addressable'
gem 'mechanize'

gem 'pdf-reader'

gem 'srt'

gem 'tdlib-schema', github: 'brauliobo/tdlib-schema', path: path_for("#{ENV['HOME']}/Projects/tdlib-schema")
gem 'tdlib-ruby',   github: 'brauliobo/tdlib-ruby',   path: path_for("#{ENV['HOME']}/Projects/tdlib-ruby")

if ENV['DB']
  gem 'pg'
  gem 'sequel'
end

group :development do
  gem 'pry'
end

