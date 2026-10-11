class Worker
  # The message a job keeps up to date while it runs, and the cancel button it carries.
  module StatusMessage
    private

    def init_status
      return if @st

      @st = Bot::Status.new(on_empty: -> { delete_status_message }) do |text, *args, **params|
        params[:cancel_job] = job_id if job_id && !params.key?(:cancel_job)
        @status_update = [text, args, params]
        edit_status text, args, params, force: params[:cancel_job] == false
      end
      initial_params = job_id ? {cancel_job: job_id} : {}
      initial_text   = 'Downloading metadata...'
      @status_update = [initial_text, [], initial_params]
      if msg.resp&.message_id
        edit_message msg, msg.resp.message_id, text: Bot::MsgHelpers.me(initial_text), **initial_params
      else
        msg.resp = send_message msg, Bot::MsgHelpers.me(initial_text), **initial_params
      end
    end

    def delete_status_message
      delete_message(msg, msg.resp.message_id, wait: 0) if msg.resp&.message_id
      @status_deleted = true
    end

    def clear_cancel_button
      return unless job_id && !@status_deleted && @status_update && msg.resp&.message_id

      text, args, params = @status_update
      edit_status text, args, params.merge(cancel_job: false), force: true
    end

    def edit_status(text, args, params, force:)
      edit_message msg, msg.resp.message_id, *args, text: (params[:parse_mode] ? text : Bot::MsgHelpers.me(text)),
                   force: force, **params
    rescue
      # Retry without MarkdownV2 so error messages with special chars still display
      edit_message(msg, msg.resp.message_id, text: text, force: force, parse_mode: nil, cancel_job: params[:cancel_job]) rescue nil
    end
  end
end
