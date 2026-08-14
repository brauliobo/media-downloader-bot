require 'bundler/setup'
require 'pry' rescue nil # fails with systemd
require 'drb/drb'

$LOAD_PATH.unshift __dir__ unless $LOAD_PATH.include? __dir__

require 'dotenv'
Dir.chdir File.expand_path('..', __dir__) do
  Dotenv.load '.env.local'
  Dotenv.load '.env.user'
  Dotenv.load! '.env'
end

require 'active_support/all'
ActiveSupport.to_time_preserves_timezone = :zone
require 'i18n'
I18n.load_path |= Dir[File.expand_path '../config/locales/*.{yml,yaml}', __dir__]
require 'json'
require 'faraday'
require 'faraday/multipart'
require 'rack/mime'

require_relative 'exts/sym_mash'
require_relative 'exts/peach'

require 'ffmpeg'
require_relative 'utils/http'

FFmpeg.verify!
