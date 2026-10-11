ENV['RAILS_ENV'] ||= 'test'
ENV['TD_BOT']    ||= '1'
require_relative '../config/environment'
require 'rspec/rails'

require_relative 'support/ollama_mock'
require_relative 'support/http_client'
require_relative 'support/ffmpeg_double'
require_relative 'support/audiobook_helpers'
