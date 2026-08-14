require_relative '../database'

module Models
  class Session < Sequel::Model(:sessions)
  end
end
