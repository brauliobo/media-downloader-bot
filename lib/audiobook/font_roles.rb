module Audiobook
  # Global style → role map built once from the whole document.
  class FontRoles
    BODY_BAND = 1.0
    CLUSTER_GAP = 1.0
    HEADING_MIN_SCORE = 3.5
    TITLE_MAX_COUNT = 2
    HEADING_ROLES = %i[chapter heading subheading].freeze
    STYLE_ATTRS = %i[font_size alignment bold italic color font_name].freeze

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

    def self.quantize(size)
      return if size.nil? || size.to_f <= 0

      (size.to_f * 2).round / 2.0
    end

    def self.size_of(line)
      value = line.respond_to?(:font_size) ? line.font_size : line[:font_size] || line['font_size']
      quantize(value)
    end

    def self.alignment_for(x:, x_max:, page_width:)
      width = page_width.to_f
      return unless width.positive?

      left       = x.to_f
      right_edge = x_max.to_f
      right_edge = left if right_edge <= left
      right      = width - right_edge
      mid_err    = ((left + right_edge) / 2.0 - width / 2.0).abs

      if mid_err <= width * 0.08 && left > width * 0.12 && right > width * 0.12
        :center
      elsif right + 2 < left * 0.5 && left > width * 0.25
        :right
      else
        :left
      end
    end

    def self.copy_style(target, source)
      STYLE_ATTRS.each do |attr|
        next unless target.respond_to?(:"#{attr}=") && source.respond_to?(attr)

        value = source.public_send(attr)
        next if value.nil?

        value = value.to_s.to_sym if attr == :alignment
        target.public_send(:"#{attr}=", value)
      end
      target
    end

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
      obj.instance_variable_set(:@body_size, data[:body_size] || data['body_size'])
      map = {}
      Array(data[:map] || data['map']).each do |entry|
        entry = SymMash.new(entry)
        key = entry[:key] || entry['key']
        role = entry[:role] || entry['role']
        level = entry[:level] || entry['level']
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
      sample = sample_from(line_or_size)
      return {} unless sample[:size]

      @map[signature(sample)] || @map[size_key(sample[:size])] || {}
    end

    def fit(lines)
      samples = lines.filter_map { |line| sample_from(line) }
      return if samples.empty?

      size_counts = samples.map { |sample| sample[:size] }.tally
      clusters    = cluster(size_counts.keys.sort)
      body        = clusters.max_by { |cluster| cluster.sum { |size| size_counts[size] } }
      @body_size  = body.max_by { |size| size_counts[size] }

      clustered_sizes(clusters).each { |size, role| @map[size_key(size)] = { role: role } }

      groups = samples.group_by { |sample| signature(sample) }
      heading_keys = groups.keys.select { |key| heading_group?(groups[key], samples) }
        .sort_by { |key| [-prominence(groups[key].first), -groups[key].first[:size]] }

      if heading_keys.size >= 2 && groups[heading_keys.first].size <= TITLE_MAX_COUNT
        @map[heading_keys.first] = { role: :title }
        heading_keys.shift
      end

      heading_keys.each_with_index do |key, index|
        role  = HEADING_ROLES[index] || :subheading
        level = index + 1
        entry = { role: role, level: level }
        @map[key] = entry
        next if groups[key].first[:size] <= @body_size + BODY_BAND

        clustered = size_key(groups[key].first[:size])
        @map[clustered] = entry if @map[clustered].nil? || @map[clustered][:level].nil?
      end
    end

    def clustered_sizes(clusters)
      clusters.each_with_object({}) do |cluster, roles|
        role = if bodyish?(cluster)
          :body
        elsif smaller_than_body?(cluster)
          :footnote
        else
          :heading
        end
        cluster.each { |size| roles[size] = role }
      end
    end

    def heading_group?(group, all)
      sample = group.max_by { |item| prominence(item) }
      score  = prominence(sample)
      return false if score < HEADING_MIN_SCORE
      return true if sample[:size] >= @body_size + BODY_BAND

      styled = all.select { |item| item[:size] == sample[:size] && styled?(item) }
      styled.any? && styled.size < all.count { |item| item[:size] == sample[:size] } * 0.4
    end

    def prominence(sample)
      score = (sample[:size] - @body_size) * 3
      score += 4 if sample[:bold]
      score += 3 if sample[:alignment] == :center
      score += 1 if sample[:alignment] == :right
      score += 2 if sample[:uppercase]
      score -= 2 if sample[:italic] && !sample[:bold] && sample[:size] <= @body_size
      score
    end

    def styled?(sample)
      sample[:bold] || sample[:alignment] == :center || sample[:uppercase]
    end

    def sample_from(line_or_size)
      if line_or_size.is_a?(Numeric)
        size = self.class.quantize(line_or_size)
        return unless size

        { size: size, bold: false, italic: false, alignment: :left, uppercase: false }
      else
        size = self.class.size_of(line_or_size)
        return unless size

        {
          size:      size,
          bold:      truthy(line_or_size, :bold),
          italic:    truthy(line_or_size, :italic),
          alignment: alignment_of(line_or_size) || :left,
          uppercase: uppercase?(line_or_size)
        }
      end
    end

    def signature(sample)
      [sample[:size], sample[:bold] ? 1 : 0, sample[:italic] ? 1 : 0, sample[:alignment]]
    end

    def size_key(size)
      [size]
    end

    def cluster(sorted)
      sorted.each_with_object([]) do |size, clusters|
        if clusters.any? && size - clusters.last.last <= CLUSTER_GAP
          clusters.last << size
        else
          clusters << [size]
        end
      end
    end

    def bodyish?(cluster)
      cluster.any? { |size| (size - @body_size).abs <= BODY_BAND }
    end

    def smaller_than_body?(cluster)
      cluster.max < @body_size - BODY_BAND
    end

    def truthy(line, attr)
      value = line.respond_to?(attr) ? line.public_send(attr) : line[attr] || line[attr.to_s]
      value == true || value.to_s == 'true'
    end

    def alignment_of(line)
      value = line.respond_to?(:alignment) ? line.alignment : line[:alignment] || line['alignment']
      value&.to_s&.to_sym
    end

    def uppercase?(line)
      text = line.respond_to?(:text) ? line.text : line[:text] || line['text']
      letters = text.to_s.scan(/\p{L}/)
      return false if letters.size < 3

      letters.count { |char| char == char.upcase } >= letters.size * 0.7
    end
  end
end
