require 'sequel'
require 'logger'

def db_config_for p = :DB
  {
    adapter:         ENV["#{p}_ADAPTER"]    || 'postgresql',
    encoding:        ENV["#{p}_ENCODING"]   || 'utf8',
    host:            ENV["#{p}_HOST"]       || 'localhost',
    database:        ENV["#{p}_NAME"]       || 'mdb',
    user:            ENV["#{p}_USER"]       || 'mdb',
    password:        ENV["#{p}_PASSWORD"]   || 'mdb',
    port:            ENV["#{p}_PORT"]&.to_i || '5432',
    max_connections: ENV["#{p}_POOL"]&.to_i || 10,
    pool_timeout:    ENV["#{p}_POOL_TIMEOUT"]&.to_i || 2.minutes.to_i,
    test:            true,
  }
end
DB = Sequel.connect db_config_for(:DB)

Sequel.extension :core_extensions

Sequel::Model.plugin :validation_helpers
# Set created_at and updated_at
Sequel::Model.plugin :timestamps, update_on_create: true
Sequel::Model.plugin :update_or_create

Sequel.extension :pg_array_ops
Sequel.extension :pg_json_ops
Sequel.extension :pg_json

Sequel::Model.db.extension :pg_array
Sequel::Model.db.extension :pg_json

Sequel::Model.strict_param_setting = false

Sequel.extension :symbol_aref
Sequel.split_symbols = true

if ENV['DEBUG']
  DB.sql_log_level = :debug
  DB.loggers << Logger.new($stdout)
end
