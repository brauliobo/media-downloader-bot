class Session < Sequel::Model(:sessions)
  # uid is the telegram user id, not a generated value
  unrestrict_primary_key
end
