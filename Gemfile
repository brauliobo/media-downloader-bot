source 'https://rubygems.org'

ruby file: '.ruby-version'

LOCAL_GEMS_DIR = "#{ENV['HOME']}/Projects"
def source github:, dir:
  return {path: "#{LOCAL_GEMS_DIR}/#{dir}"} if ENV['LOCAL_GEMS'] && File.exist?("#{LOCAL_GEMS_DIR}/#{dir}")
  {github: github}
end

gem 'rails', '~> 8.1'
gem 'puma'
gem 'vite_rails'
gem 'dotenv-rails'

gem 'hashie'
gem 'json_schemer'
gem 'chronic'

gem 'iso-639'
gem 'numbers_and_words'

gem 'telegram-bot-ruby', git: 'git@github.com:brauliobo/telegram-bot-ruby.git', require: 'telegram/bot'

gem 'roda' # bot <-> worker http service
gem 'drb'

gem 'addressable'
gem 'mechanize'
gem 'faraday'
gem 'httparty'
gem 'http-cookie'

gem 'epub-parser'
gem 'nokogiri'
gem 'puppeteer-ruby'

if ENV['TD_BOT']
  gem 'tdlib-schema', source(github: 'brauliobo/tdlib-schema', dir: 'tdlib-schema')
  gem 'tdlib-ruby',   source(github: 'brauliobo/tdlib-ruby',   dir: 'tdlib-ruby')
end

gem 'pg'
gem 'sequel-rails'

group :development, :test do
  gem 'pry-rails'
  gem 'rspec-rails'
end
