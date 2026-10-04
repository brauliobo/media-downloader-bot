Sequel.extension :pg_array_ops, :pg_json_ops, :pg_json

Sequel::Model.db.extension :pg_array, :pg_json
Sequel::Model.plugin :validation_helpers
Sequel::Model.plugin :timestamps, update_on_create: true
Sequel::Model.plugin :update_or_create
Sequel::Model.strict_param_setting = false
