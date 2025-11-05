require 'fileutils'
require 'active_support/core_ext/class/attribute'
require_relative 'sh'
require_relative 'http'

module Utils
  class Thumb

    class_attribute :max_height, default: 320

    RESIZE_CMD = "convert %{in} %{opts} -define jpeg:extent=190kb %{out}"

    def self.process(info, base_filename:, on_error: nil)
      return if (url = info.thumbnail).blank?

      im_in  = "#{base_filename}-ithumb.jpg"
      im_out = "#{base_filename}-othumb.jpg"

      if File.exist?(url)
        FileUtils.cp url, im_in
      else
        ::File.write im_in, HTTP.get(url).body
      end

      opts = if portrait?(info)
        w, h = max_height * info.width / info.height, max_height
        "-resize #{w}x#{h}\^ -gravity Center -extent #{w}x#{h}"
      else
        "-resize x#{max_height}"
      end
      Sh.run RESIZE_CMD % {in: im_in, out: im_out, opts: opts}

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

