require_relative '../sequel'

module Models
  class Session < Sequel::Model(:sessions)
  end
end
