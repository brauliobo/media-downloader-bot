module Ewprs
  # A source file is named by its path without the extension.
  module PathSlug
    def slug = File.basename(path, File.extname(path))
  end
end
