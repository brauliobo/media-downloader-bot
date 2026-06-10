require 'fileutils'
require_relative 'sh'
require_relative 'http'
require_relative 'safety'

module Utils
  class Thumb

    class_attribute :max_height, default: 320

    def self.process(info, base_filename:, on_error: nil, local: false)
      return if (url = info.thumbnail).blank?

      im_in  = "#{base_filename}-ithumb.jpg"
      im_out = "#{base_filename}-othumb.jpg"

      if local && File.exist?(url)
        FileUtils.cp url, im_in
      elsif Safety.public_http_url?(url)
        ::File.write im_in, HTTP.get(url).body
      else
        return nil
      end

      opts = if portrait?(info)
        w, h = max_height * info.width / info.height, max_height
        "-resize #{w}x#{h}\^ -gravity Center -extent #{w}x#{h}"
      else
        "-resize x#{max_height}"
      end
      Sh.run "convert #{Sh.escape(im_in)} #{opts} -define jpeg:extent=190kb #{Sh.escape(im_out)}"

      im_out
    rescue => e
      on_error&.call(e)
      nil
    end

    def self.portrait?(info)
      return false unless info.width
      info.width < info.height
    end
  end
end
