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

gem 'addressable'
gem 'mechanize'
gem 'net_http_unix'

gem 'srt'

if ENV['DB']
  gem 'pg'
  gem 'sequel'
end

gem 'whisper.cpp', path: path_for('../ruby-whisper.cpp') if ENV['WHISPER']

group :development do
  gem 'pry'
end

