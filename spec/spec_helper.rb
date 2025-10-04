require 'yaml'
require 'active_support/core_ext/module/attribute_accessors'

ENV['TRANSLATOR'] ||= 'Madlad400'
ENV['LOCAL_GEMS'] ||= '1'

require_relative '../lib/exts/sym_mash'
require_relative '../lib/audiobook/parsers/pdf'
require_relative '../lib/audiobook/book'
