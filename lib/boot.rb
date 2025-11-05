require 'bundler/setup'
require 'pry' rescue nil # fails with systemd
require 'drb/drb'

require 'dotenv'
Dir.chdir File.dirname(__FILE__) + '/..' do
  Dotenv.load '.env.user'
  Dotenv.load! '.env'
end

