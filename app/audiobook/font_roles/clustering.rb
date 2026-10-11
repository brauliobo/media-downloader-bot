module Audiobook
  class FontRoles
    # Font sizes grouped into clusters, and the clusters read as body text or headings.
    module Clustering
      private

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

        levels = heading_levels(heading_keys, groups)
        heading_keys.each do |key|
          level = levels[key]
          entry = { role: HEADING_ROLES[level - 1] || :subheading, level: level }
          @map[key] = entry
          next if groups[key].first[:size] <= @body_size + BODY_BAND

          clustered = size_key(groups[key].first[:size])
          @map[clustered] = entry if @map[clustered].nil? || @map[clustered][:level].nil?
        end
      end

      # Signatures that share a size hold the same rank: a bold chapter title and an italic one are
      # both chapter titles. Ranking every signature on its own invents a level per style.
      def heading_levels(keys, groups)
        sizes = keys.map { |key| groups[key].first[:size] }.uniq.sort
        ranks = cluster(sizes).reverse.each_with_index
          .flat_map { |group, index| group.map { |size| [size, [index + 1, MAX_LEVELS].min] } }.to_h
        keys.to_h { |key| [key, ranks[groups[key].first[:size]]] }
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
        value = line.public_send(attr)
        value == true || value.to_s == 'true'
      end

      def uppercase?(line)
        letters = line.text.to_s.scan(/\p{L}/)
        return false if letters.size < 3

        letters.count { |char| char == char.upcase } >= letters.size * 0.7
      end
    end
  end
end
