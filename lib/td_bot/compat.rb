require 'tdlib-ruby' rescue nil

# Predefine missing Update subtypes eagerly to avoid early update-manager crashes
begin
  if defined?(TD::Types)
    TD::Types.const_set(:Update, Class.new(TD::Types::Base)) unless TD::Types.const_defined?(:Update)
    unless TD::Types::Update.const_defined?(:DefaultPaidReactionType)
      TD::Types::Update.const_set(:DefaultPaidReactionType, Class.new(TD::Types::Base))
    end
  end
rescue
end

# TDLib compatibility shims for schema/version mismatches.
# Keep this lean; only patch what actually prevents operation.

if defined?(TD::Types)
  module TD::Types
    # ---------- Core defaults/stubs ----------
    begin
      # Message: ensure newly added flags/fields exist
      if const_defined?(:Message)
        m = const_get(:Message)
        m.singleton_class.class_eval do
          alias_method :__compat_new_msg, :new unless method_defined?(:__compat_new_msg)
          define_method :new do |hash|
            h = hash.dup
            h[:has_sensitive_content]   = false unless h.key?(:has_sensitive_content) || h.key?('has_sensitive_content')
            h[:restriction_reason]      ||= h['restriction_reason'] || ''
            h[:is_topic_message]        = false unless h.key?(:is_topic_message) || h.key?('is_topic_message')
            h[:saved_messages_topic_id] ||= 0
            h[:is_outgoing]             = false unless h.key?(:is_outgoing) || h.key?('is_outgoing')
            __compat_new_msg(h)
          end
        end
      end

      # EmojiStatusTypeCustomEmoji: default expiration_date
      if const_defined?(:EmojiStatusTypeCustomEmoji)
        cls = const_get(:EmojiStatusTypeCustomEmoji)
        cls.singleton_class.class_eval do
          alias_method :__compat_new_esc, :new unless method_defined?(:__compat_new_esc)
          define_method :new do |hash|
            h = hash.dup
            h[:expiration_date] ||= h['expiration_date'] || 0
            __compat_new_esc(h)
          end
        end
      end

      # EmojiStatus: default custom_emoji_id
      if const_defined?(:EmojiStatus)
        em = const_get(:EmojiStatus)
        em.singleton_class.class_eval do
          alias_method :__compat_new_es, :new unless method_defined?(:__compat_new_es)
          define_method :new do |hash|
            h = hash.dup
            h[:custom_emoji_id] ||= h['custom_emoji_id'] || 0
            __compat_new_es(h)
          end
        end
      end

      # Supergroup: default various boolean flags and restriction_reason
      if const_defined?(:Supergroup)
        sg = const_get(:Supergroup)
        sg.singleton_class.class_eval do
          alias_method :__compat_new_sg, :new unless method_defined?(:__compat_new_sg)
          define_method :new do |hash|
            h = hash.dup
            %i[is_verified is_scam is_fake has_sensitive_content].each { |k| h[k] = false unless h.key?(k) || h.key?(k.to_s) }
            h[:restriction_reason] ||= h['restriction_reason'] || ''
            __compat_new_sg(h)
          end
        end
      end

      # LinkPreviewType::Photo: default :author
      if const_defined?(:LinkPreviewType) && LinkPreviewType.const_defined?(:Photo)
        lpp = LinkPreviewType.const_get(:Photo)
        lpp.singleton_class.class_eval do
          alias_method :__compat_new_lp, :new unless method_defined?(:__compat_new_lp)
          define_method :new do |hash|
            h = hash.dup
            h[:author] ||= h['author'] || ''
            __compat_new_lp(h)
          end
        end
      end

      # ChatActionBar::ReportAddBlock: default :distance
      if defined?(TD::Types::ChatActionBar) && ChatActionBar.const_defined?(:ReportAddBlock)
        cab = ChatActionBar.const_get(:ReportAddBlock)
        cab.singleton_class.class_eval do
          alias_method :__compat_new_cab, :new unless method_defined?(:__compat_new_cab)
          define_method :new do |hash|
            h = hash.dup
            h[:distance] ||= h['distance'] || 0
            __compat_new_cab(h)
          end
        end
      end

      # Simple stubs seen at runtime
      class AccountInfo < Base; end unless const_defined?(:AccountInfo)
      class VerificationStatus < Base; end unless const_defined?(:VerificationStatus)
      class MessageTopicSavedMessages < Base; end unless const_defined?(:MessageTopicSavedMessages)
      class MessageTopicForum < Base; end unless const_defined?(:MessageTopicForum)

      # Older stubs for TDLib type names
      begin
        super_klass = const_defined?(:EmojiStatus) ? EmojiStatus : Base
        class EmojiStatusTypeCustomEmoji < super_klass; end unless const_defined?(:EmojiStatusTypeCustomEmoji)
      rescue; end
      class PaidReactionTypeRegular < Base; end unless const_defined?(:PaidReactionTypeRegular)
      class ChatFolderName          < Base; end unless const_defined?(:ChatFolderName)

      # Update::* dynamic fallback
      upd = const_get(:Update) rescue nil
      if upd
        begin
          upd.const_set(:DefaultPaidReactionType, Class.new(upd)) unless upd.const_defined?(:DefaultPaidReactionType)
        rescue; end
        unless upd.singleton_class.method_defined?(:const_missing)
          upd.singleton_class.class_eval do
            def const_missing(name)
              klass = Class.new(TD::Types::Base)
              const_set(name, klass)
            end
          end
        end
      end
    rescue
    end
  end
end

# Extend LOOKUP_TABLE safely with new mappings (table may be frozen)
begin
  tbl = TD::Types::LOOKUP_TABLE.dup
  {
    'emojiStatusTypeCustomEmoji'    => 'EmojiStatusTypeCustomEmoji',
    'paidReactionTypeRegular'       => 'PaidReactionTypeRegular',
    'chatFolderName'                => 'ChatFolderName',
    'updateDefaultPaidReactionType' => 'Update::DefaultPaidReactionType',
    'accountInfo'                   => 'AccountInfo',
    'verificationStatus'            => 'VerificationStatus',
    'messageTopicSavedMessages'     => 'MessageTopicSavedMessages',
    'messageTopicForum'             => 'MessageTopicForum',
  }.each { |k,v| tbl[k] ||= v }
  TD::Types.send(:remove_const, :LOOKUP_TABLE)
  TD::Types.const_set(:LOOKUP_TABLE, tbl.freeze)
rescue
end

# Lenient wrap: if TDLib returns unknown @type, define a stub class on the fly
begin
  module TD::Types
    class << self
      alias_method :__orig_wrap, :wrap unless method_defined?(:__orig_wrap)
      def wrap(object)
        # Pre-normalize known payloads missing new fields
        if object.is_a?(Hash)
          t = object['@type'] || object[:'@type']
          object['expiration_date'] ||= 0 if t == 'emojiStatusTypeCustomEmoji'
        end
        __orig_wrap(object)
      rescue => e
        t = object.is_a?(Hash) ? (object['@type'] || object[:'@type']) : nil
        raise e unless t
        # Ensure Update::DefaultPaidReactionType exists when encountered
        if t == 'updateDefaultPaidReactionType'
          upd = (TD::Types.const_get(:Update) rescue nil)
          if upd && !upd.const_defined?(:DefaultPaidReactionType)
            # Define as a simple Update subclass or Base to satisfy the wrapper
            begin
              upd.const_set(:DefaultPaidReactionType, Class.new(upd))
            rescue
              upd.const_set(:DefaultPaidReactionType, Class.new(TD::Types::Base))
            end
          end
        end
        target = (LOOKUP_TABLE[t] rescue nil)
        if target && target.include?('::')
          parts = target.split('::')
          mod = TD::Types
          last = parts.pop
          parts.each { |p| mod = mod.const_defined?(p) ? mod.const_get(p) : mod.const_set(p, Module.new) }
          mod.const_set(last, Class.new(Base)) unless mod.const_defined?(last)
        elsif target
          const_set(target, Class.new(Base)) unless const_defined?(target)
        else
          const_name = t.to_s.gsub(/(^|_)([a-z])/) { $2.upcase }
          const_set(const_name, Class.new(Base)) unless const_defined?(const_name)
        end
        __orig_wrap(object)
      end
    end
  end
rescue
end

# Swallow benign update-manager crashes so processing can continue
begin
  class TD::Client
    if method_defined?(:handle_update)
      alias_method :__orig_handle_update, :handle_update unless method_defined?(:__orig_handle_update)
      def handle_update(update)
        __orig_handle_update(update)
      rescue => e
        return if e.message.include?("Can't find class for") ||
                  e.message.include?("uninitialized constant TD::Types::Update") ||
                  e.message.include?("is missing in Hash input")
        raise
      end
    end
  end
rescue
end

# ---------- Additional safe defaults from older TDLibs ----------
begin
  module TD::Types
    # Provide .text helper for Message
    class Message < Base
      def text
        case content
        when MessageContent::Text
          content.text&.text
        when MessageContent::Photo, MessageContent::Video, MessageContent::Audio, MessageContent::Document
          content.caption&.text
        else
          nil
        end
      end unless method_defined? :text
    end

    # User: ensure booleans/ids exist
    class User < Base
      class << self
        alias_method :__orig_new_user, :new unless method_defined?(:__orig_new_user)
        def new(hash)
          h = hash.dup
          %w[is_verified is_premium is_support is_scam is_fake has_active_stories has_unread_active_stories restricts_new_chats have_access added_to_attachment_menu].each { |k| h[k] = false unless h.key?(k) }
          %w[accent_color_id background_custom_emoji_id profile_accent_color_id profile_background_custom_emoji_id].each { |k| h[k] ||= 0 }
          h['restriction_reason'] ||= ''
          __orig_new_user(h)
        end
      end
    end

    # Notification settings: add story flags
    [ScopeNotificationSettings, ChatNotificationSettings].each do |base|
      next unless base rescue next
      base.singleton_class.send(:alias_method, :__orig_new_notif, :new) unless base.singleton_class.method_defined?(:__orig_new_notif)
      base.define_singleton_method(:new) do |hash|
        h = hash.dup
        %i[show_story_sender use_default_show_story_sender].each { |f| h[f] = false unless h.key?(f) || h.key?(f.to_s) }
        __orig_new_notif(h)
      end
    end

    # InputMessageContent::Video: hide self_destruct_type for older TDLibs
    class MessageSelfDestructType < Base; end unless const_defined?(:MessageSelfDestructType)
    class InputMessageContent::Video < InputMessageContent
      class << self
        alias_method :__orig_new_video, :new unless method_defined?(:__orig_new_video)
        def new(hash)
          h = hash.dup
          h[:self_destruct_type] ||= TD::Types::MessageSelfDestructType::Timer.new(self_destruct_time: 0) rescue nil
          __orig_new_video(h)
        end
      end
      def to_hash
        h = super
        h.delete(:self_destruct_type)
        h.delete('self_destruct_type')
        h
      end
      alias_method :to_h, :to_hash
    end

    # ChatFolderInfo: default title
    class ChatFolderInfo < Base
      class << self
        alias_method :__orig_new_cfi, :new unless method_defined?(:__orig_new_cfi)
        def new(hash)
          h = hash.dup
          h[:title] ||= h['title'] || ''
          __orig_new_cfi(h)
        end
      end
    end
  end
rescue
end


