source 'https://rubygems.org'

ruby File.read('.ruby-version')

LOCAL_GEMS_DIR = "#{ENV['HOME']}/Projects"
def source github:, dir:
  return {path: "#{LOCAL_GEMS_DIR}/#{dir}"} if ENV['LOCAL_GEMS'] && File.exist?("#{LOCAL_GEMS_DIR}/#{dir}")
  {github: github}
end

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
gem 'faraday'
gem 'httparty'

gem 'pdf-reader'
gem 'epub-parser'
gem 'nokogiri'

gem 'srt'

unless ENV['SKIP_TD_BOT']
  gem 'tdlib-schema', source(github: 'brauliobo/tdlib-schema', dir: 'tdlib-schema')
  gem 'tdlib-ruby',   source(github: 'brauliobo/tdlib-ruby',   dir: 'tdlib-ruby')
end

if ENV['DB']
  gem 'pg'
  gem 'sequel'
end

group :development do
  gem 'pry'
end

