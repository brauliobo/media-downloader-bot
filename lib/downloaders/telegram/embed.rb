require 'nokogiri'
require 'uri'

module Downloaders
  class Telegram
    class Embed
      Item = Data.define(:kind, :url)
      Post = Data.define(:text, :author, :items, :error)

      BACKGROUND_IMAGE = /background-image:\s*url\(['"]?([^'")]+)['"]?\)/i

      def self.parse(html)
        doc = Nokogiri::HTML5.parse(html.to_s)
        return Post.new(text: nil, author: nil, items: [], error: 'Telegram post not found') if error?(doc)

        items = media_items(doc)
        error = if items.empty? && doc.at_css('a.tgme_widget_message_video_player')
          'Telegram video is not available from the public preview'
        end

        Post.new(
          text:   message_text(doc),
          author: text_at(doc, '.tgme_widget_message_owner_name'),
          items:  items,
          error:  error
        )
      end

      def self.error?(doc)
        doc.at_css('.err_message')
      end
      private_class_method :error?

      def self.media_items(doc)
        photos = doc.css('a.tgme_widget_message_photo_wrap').filter_map { |node| item(:photo, background_url(node)) }
        videos = doc.css('a.tgme_widget_message_video_player video[src], a.tgme_widget_message_video_player source[src]').filter_map do |node|
          item(:video, node['src'])
        end
        voices = doc.css('.tgme_widget_message_voice audio[src], .tgme_widget_message_voice source[src]').filter_map do |node|
          item(:audio, node['src'])
        end
        photos + videos + voices
      end
      private_class_method :media_items

      def self.item(kind, value)
        url = absolute_url(value)
        Item.new(kind: kind, url: url) if url
      end
      private_class_method :item

      def self.background_url(node)
        node['style'].to_s[BACKGROUND_IMAGE, 1]
      end
      private_class_method :background_url

      def self.absolute_url(value)
        href = value.to_s.strip
        return if href.empty?

        href = "https:#{href}" if href.start_with?('//')
        uri  = URI.parse(href)
        href if uri.is_a?(URI::HTTP) && uri.host && !uri.host.match?(/telegram\.org\z/i)
      rescue URI::InvalidURIError
        nil
      end
      private_class_method :absolute_url

      def self.message_text(doc)
        node = doc.at_css('.tgme_widget_message_text')
        return if node.nil?

        fragment = Nokogiri::HTML5.fragment(node.inner_html)
        fragment.css('br').each { |br| br.replace("\n") }
        text_at(fragment, nil)
      end
      private_class_method :message_text

      def self.text_at(node, selector)
        target = selector ? node.at_css(selector) : node
        return if target.nil?

        target.text.gsub("\u00a0", ' ').gsub(/[ \t]+/, ' ').gsub(/\n{3,}/, "\n\n").strip.presence
      end
      private_class_method :text_at
    end
  end
end
