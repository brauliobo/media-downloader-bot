module Audiobook
  # Global style → role map built once from the whole document.
  class FontRoles
    BODY_BAND = 1.0
    CLUSTER_GAP = 1.0
    HEADING_MIN_SCORE = 3.5
    TITLE_MAX_COUNT = 2
    HEADING_ROLES = %i[chapter heading subheading].freeze
    HEADING_LIKE_ROLES = %i[title chapter heading subheading].freeze
    STYLE_ATTRS = %i[font_size alignment bold italic color font_name].freeze
    CENTER_SPAN_MAX = 0.55
    CENTER_SIDE_MIN = 0.18
    SHORT_CENTER_WORDS = 12
    MAX_HEADING_WORDS  = 24
    MAX_LEVELS         = 4

    extend LineJudgement
    extend Css
    include Clustering

    attr_reader :body_size, :map

    def self.current
      Thread.current[:audiobook_font_roles]
    end

    def self.use(roles)
      previous = current
      Thread.current[:audiobook_font_roles] = roles
      yield roles
    ensure
      Thread.current[:audiobook_font_roles] = previous
    end

    def self.from_lines(lines)
      new(Array(lines))
    end

    def self.alignment_of(line) = line.alignment&.to_s&.to_sym

    def initialize(lines)
      @map       = {}
      @body_size = nil
      fit(Array(lines))
    end

    def role_for(line_or_size)
      lookup(line_or_size)[:role] || :body
    end

    def level_for(line_or_size)
      lookup(line_or_size)[:level]
    end

    def heading?(line_or_size)
      level_for(line_or_size).to_i.positive?
    end

    def to_h
      {
        'body_size' => body_size,
        'map' => @map.map do |key, entry|
          {
            'key'   => key.map { |value| value.is_a?(Symbol) ? value.to_s : value },
            'role'  => entry[:role]&.to_s,
            'level' => entry[:level]
          }.compact
        end
      }
    end

    def self.from_h(data)
      data = SymMash.new(data || {})
      obj = allocate
      obj.instance_variable_set(:@body_size, data[:body_size])
      map = {}
      Array(data[:map]).each do |entry|
        entry = SymMash.new(entry)
        key, role, level = entry[:key], entry[:role], entry[:level]
        map[normalize_key(key)] = { role: role&.to_sym, level: level }.compact
      end
      obj.instance_variable_set(:@map, map)
      obj
    end

    def self.normalize_key(key)
      key = Array(key)
      size = key.first.is_a?(Numeric) ? key.first.to_f : key.first
      rest = key.drop(1).map { |value| %w[left right center justify].include?(value.to_s) ? value.to_s.to_sym : value }
      [size, *rest]
    end

    private

    def lookup(line_or_size)
      sample = sample_from(line_or_size) or return {}

      @map[signature(sample)] || @map[size_key(sample[:size])] || {}
    end

    def alignment_of(line)
      self.class.alignment_of(line)
    end
  end
end
