module Audiobook
  module Parsers
    class CssStyle
      TAG_SIZES = {
        'h1' => 24, 'h2' => 22, 'h3' => 20, 'h4' => 18, 'h5' => 16, 'h6' => 14,
        'p' => 12, 'div' => 12, 'li' => 12, 'blockquote' => 12, 'small' => 10, 'sup' => 10, 'sub' => 10
      }.freeze
      NAMED_SIZES = {
        'xx-small' => 8, 'x-small' => 10, 'small' => 11, 'medium' => 12,
        'large' => 14, 'x-large' => 18, 'xx-large' => 24
      }.freeze
      BOLD_TAGS = %w[h1 h2 h3 h4 h5 h6 b strong].freeze
      ITALIC_TAGS = %w[i em].freeze

      def self.sheets_from(doc)
        doc.css('style').flat_map { |node| parse_sheet(node.text) }
      end

      def self.parse_sheet(css)
        rules = []
        css.to_s.gsub(%r{/\*.*?\*/}m, '').scan(/([^{@][^{]*)\{([^}]+)\}/) do |selector, decls|
          selector.split(',').map(&:strip).reject(&:empty?).each do |sel|
            next if sel.include?('@') || sel.include?(':')
            rules << { selector: sel, spec: specificity(sel), style: parse_decls(decls) }
          end
        end
        rules
      end

      def self.for_node(node, sheets = [])
        style = { font_size: 12 }
        chain = node.ancestors.select(&:element?).reverse + [node]
        chain.each do |el|
          style.merge!(tag_defaults(el.name))
          matching(el, sheets).each { |rule| style.merge!(rule[:style].compact) }
          style.merge!(parse_decls(el['style'], base_size: style[:font_size]))
          style.merge!(presentational(el))
        end
        style.compact
      end

      def self.tag_defaults(name)
        defaults = {}
        defaults[:font_size] = TAG_SIZES[name] if TAG_SIZES[name]
        defaults[:bold] = true if BOLD_TAGS.include?(name)
        defaults[:italic] = true if ITALIC_TAGS.include?(name)
        defaults[:alignment] = :center if name == 'center'
        defaults
      end

      def self.presentational(node)
        style = {}
        style[:bold] = true if BOLD_TAGS.include?(node.name)
        style[:italic] = true if ITALIC_TAGS.include?(node.name)
        align = node['align'].to_s.downcase.presence
        style[:alignment] = align.to_sym if %w[left right center justify].include?(align)
        style[:alignment] = :center if node.name == 'center'
        style
      end

      def self.parse_decls(css, base_size: 12)
        style = {}
        css.to_s.split(';').each do |decl|
          prop, value = decl.split(':', 2).map { |part| part.to_s.strip }
          next if prop.blank? || value.blank?
          apply_decl(style, prop.downcase, value, base_size)
        end
        style
      end

      def self.apply_decl(style, prop, value, base_size)
        case prop
        when 'font-size'   then style[:font_size] = size_to_pt(value, base_size)
        when 'font-weight' then style[:bold] = bold_weight?(value)
        when 'font-style'  then style[:italic] = value.match?(/italic|oblique/i)
        when 'text-align'
          align = value.downcase[/\A(left|right|center|justify)/, 1]
          style[:alignment] = align.to_sym if align
        when 'color'       then style[:color] = value.split(/\s/).first
        when 'font-family' then style[:font_name] = value.split(',').first.to_s.gsub(/['"]/, '').presence
        when 'font'        then apply_font_shorthand(style, value, base_size)
        end
      end

      def self.apply_font_shorthand(style, value, base_size)
        style[:italic] = true if value.match?(/italic|oblique/i)
        style[:bold] = true if bold_weight?(value)
        size = value[/\b(\d+(?:\.\d+)?(?:pt|px|em|rem|%)|#{NAMED_SIZES.keys.join('|')})\b/i, 1]
        style[:font_size] = size_to_pt(size, base_size) if size
        family = value[/\b(?:pt|px|em|rem)\s+(.+)\z/i, 1]
        style[:font_name] = family.split(',').first.to_s.gsub(/['"]/, '').presence if family
      end

      def self.size_to_pt(value, base_size)
        raw = value.to_s.strip.downcase
        return NAMED_SIZES[raw] if NAMED_SIZES[raw]
        number = raw[/\A(\d+(?:\.\d+)?)/, 1]&.to_f
        return unless number
        return number if raw.end_with?('pt')
        return (number * 0.75).round(2) if raw.end_with?('px')
        return (number * base_size.to_f).round(2) if raw.end_with?('em', 'rem')
        return (number * base_size.to_f / 100.0).round(2) if raw.end_with?('%')
        number
      end

      def self.bold_weight?(value)
        value.match?(/bold|[6-9]00/i)
      end

      def self.matching(node, sheets)
        sheets.select { |rule| match?(node, rule[:selector]) }.sort_by { |rule| rule[:spec] }
      end

      def self.match?(node, selector)
        tag, id, classes = parse_selector(selector)
        return false if tag && node.name != tag
        return false if id && node['id'] != id
        return false if classes.any? && (classes - node['class'].to_s.split).any?
        tag || id || classes.any?
      end

      def self.parse_selector(selector)
        token = selector.to_s.split(/\s+/).last.to_s
        tag = token[/\A[a-z][\w-]*/i]
        id = token[/#([\w-]+)/, 1]
        [tag&.downcase, id, token.scan(/\.([\w-]+)/).flatten]
      end

      def self.specificity(selector)
        _tag, id, classes = parse_selector(selector)
        (id ? 100 : 0) + (classes.size * 10) + (_tag ? 1 : 0)
      end
    end
  end
end
