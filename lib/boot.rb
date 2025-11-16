require 'bundler/setup'
require 'pry' rescue nil # fails with systemd
require 'drb/drb'

require 'dotenv'
Dir.chdir File.dirname(__FILE__) + '/..' do
  Dotenv.load '.env.user'
  Dotenv.load! '.env'
end

require 'active_support/all'
require 'json'
require 'faraday'
require 'faraday'
require 'faraday/multipart'
require 'rack/mime'

require_relative 'exts/sym_mash'
require_relative 'exts/peach'

require_relative 'utils/http'