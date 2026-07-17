require 'fileutils'
require_relative 'sh'
require_relative 'http'
require_relative 'safety'

module Utils
  class Thumb

    class_attribute :max_height, default: 320

    def self.process(info, base_filename:, on_error: nil, local: false)
      return if (url = source_url(info)).blank?

      im_in  = "#{base_filename}-ithumb.jpg"
      im_out = "#{base_filename}-othumb.jpg"

      if local && File.exist?(url)
        FileUtils.cp url, im_in
      elsif Safety.public_http_url?(url)
        body = HTTP.get_public(url)
        raise ArgumentError, 'thumbnail must be JPEG or PNG' unless image?(body)
        ::File.binwrite im_in, body
      else
        return nil
      end

      opts = if portrait?(info)
        w, h = max_height * info.width / info.height, max_height
        "-resize #{w}x#{h}\^ -gravity Center -extent #{w}x#{h}"
      else
        "-resize #{max_height}x#{max_height}\\>"
      end
      limits = '-limit memory 128MiB -limit map 256MiB -limit disk 512MiB -limit time 30'
      Sh.run "convert #{limits} #{Sh.escape(im_in)} #{opts} -define jpeg:extent=190kb #{Sh.escape(im_out)}"

      im_out
    rescue => e
      on_error&.call(e)
      nil
    end

    def self.source_url(info)
      info.thumbnail.presence || Array(info.thumbnails).reverse_each.filter_map do |thumb|
        if thumb.respond_to?(:url) then thumb.url
        elsif thumb.respond_to?(:[]) then thumb[:url] || thumb['url'] end
      end.first
    end

    def self.portrait?(info)
      return false unless info.width && info.height.to_i.positive?
      info.width < info.height
    end

    def self.image?(body)
      body.start_with?("\xFF\xD8\xFF".b) || body.start_with?("\x89PNG\r\n\x1A\n".b)
    end
  end
end
