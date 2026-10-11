module Audiobook
  class FontRoles
    # The CSS a styled item is written with, and the style one item takes from another.
    module Css
      def format_pt(size)
        "#{size.to_f.round(1)}pt".sub('.0pt', 'pt')
      end

      def css_rules(item, alignment: :keep)
        return [] unless item

        align = alignment == :keep ? alignment_of(item) : alignment
        rules = []
        rules << "font-size: #{format_pt(item.font_size)}" if item.font_size
        rules << "text-align: #{align}" if align
        rules << 'font-weight: bold' if item.bold
        rules << 'font-style: italic' if item.italic
        rules << "color: #{item.color}" if item.color
        rules
      end

      def copy_style(target, source)
        STYLE_ATTRS.each do |attr|
          value = source.public_send(attr)
          next if value.nil?

          value = value.to_s.to_sym if attr == :alignment
          target.public_send(:"#{attr}=", value)
        end
        target
      end
    end
  end
end
