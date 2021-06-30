# frozen_string_literal: true

require_relative '../../config/boot'
require_relative '../../config/environment'
require_relative 'cli_helper'
require_relative '../../app/validators/status_length_validator'

MAX_CHARS = StatusLengthValidator::MAX_CHARS

require 'date'
require 'json'

module Mastodon
  class IGImportCLI < Thor
    include CLIHelper

    @@logger = Logger.new($stdout)

    option :locations, type: :boolean
    desc 'import posts_1.json account_name', 'Import posts from IG json into account_name.'
    long_desc <<-LONG_DESC
      Import posts from IG json into account_name.

      With the --locations option, geo locations from posts_1.json will be
      added to toot texts as links to http://osm.org.
    LONG_DESC
    def import(json_fp, account_name)
      @root_path = File.join(File.dirname(json_fp), '..')
      @account = Account.find_local(account_name)
      file = File.read(json_fp)

      posts = JSON.parse(file)
      posts = posts.sort_by { |item| item['media'][0]['creation_timestamp'] }
      n_statuses = 0
      posts.each do |post|
        n_statuses += handle_post(post, options[:locations])
      end
      @@logger.info "Imported #{n_statuses} toots"
    end

    option :dryrun, type: :boolean
    desc 'delete_statuses account_name date', 'Delete all statuses of account_name before date, also deletes media attachments.'
    long_desc <<-LONG_DESC
      Delete all statuses of account_name before date, also deletes media attachments.

      With the --dryrun option, records are not actually deleted.
    LONG_DESC
    def delete_statuses(account_name, date)
      @account = Account.find_local(account_name)

      n_media_attachments = n_statuses = 0
      MediaAttachment.order(:created_at).includes(:status).where('media_attachments.account_id = ?', @account.id).where('statuses.created_at <= ?', date).references(:status).in_batches do |media_attachments|
        media_attachments.each_slice(50) do |slice|
          @@logger.info "Deleting media attachments #{slice.map(&:id)}"
          MediaAttachment.where(id: slice.map(&:id)).destroy_all unless options[:dryrun]
          n_media_attachments += slice.size unless options[:dryrun]
        end
      end

      @account.statuses.reorder(:created_at).where('created_at <= ?', date).in_batches do |statuses|
        statuses.each_slice(50) do |slice|
          @@logger.info "Deleting statuses #{slice.map(&:id)}"
          Status.where(id: slice.map(&:id)).destroy_all unless options[:dryrun]
          n_statuses += slice.size unless options[:dryrun]
        end
      end

      @@logger.info "Deleted #{n_statuses} statuses and #{n_media_attachments} attachments of #{account_name}"
    end

    no_commands do
      def handle_post(post, locations)
        ts = post['media'][0]['creation_timestamp']
        text = if post.key?('title') && !post['title'].empty?
                 post['title']
               else
                 post['media'][0]['title']
               end
        text = text.encode('ISO-8859-1').force_encoding('utf-8')

        if locations && post['media'][0].key?('media_metadata') # add OSM link with marker to text
          media_metadata = post['media'][0]['media_metadata']
          post_metadata = if media_metadata.key?('photo_metadata')
                            media_metadata['photo_metadata']
                          elsif media_metadata.key?('video_metadata')
                            media_metadata['video_metadata']
                          end

          unless post_metadata.nil?
            text = "#{text} #{osm_url(post_metadata['latitude'], post_metadata['longitude'])}"
          end
        end

        if text.size > MAX_CHARS
          # due the pagination for a max number of blocks equal to 99, chunks should never be longer than 500 chars for chunk_size = 491
          chunk_size = MAX_CHARS - 9
          text_chunks = text.scan(/.{0,#{chunk_size}}[a-z.!?,;](?:\b|$)/mi)
          n_chunks = text_chunks.size
          raise "Text too long: #{text.size} chars would become #{n_chunks} chunks" unless n_chunks < 100
          text_chunks = text_chunks.map.with_index { |s, i| "#{s.strip} (#{i + 1}/#{n_chunks})" }
          @@logger.warn "Text size #{text.size} longer than 500, splitting into #{n_chunks} chunks"
        else
          text_chunks = [text]
        end

        # Has a status with text already been created ? (false negative if the user
        # actually has two posts with the exact same title)
        return 0 if post_exists?(text_chunks[0])

        ApplicationRecord.transaction do
          # Post first chunk:
          # Post media only on first chunk
          media = post['media'].map { |item| create_media(item) }
          status_attributes = {
            text: text_chunks[0],
            created_at: DateTime.strptime(ts.to_s, '%s'),
            media_attachments: media || [],
            thread: nil,
            sensitive: false,
            spoiler_text:  '',
            visibility: 'public',
            language: @account.user&.setting_default_language&.presence || LanguageDetector.instance.detect(text, @account),
            rate_limit: false,
          }
          status = @account.statuses.create!(status_attributes)
          @@logger.info "Created status with ID #{status.id}"

          # Post remaining chunks (if any) in same thread:
          status_attributes[:media_attachments] = []
          text_chunks[1..-1].each do |txt|
            status_attributes[:text] = txt
            # New chunk is always reply to previous chunk
            status_attributes[:thread] = status # Status.find(status.id)
            # add one second to each subsequent chunk so they show up chronologically in the feed
            status_attributes[:created_at] = status_attributes[:created_at] + Rational(1, 86_400)
            status = @account.statuses.create!(status_attributes)
            @@logger.info "Created status with ID #{status.id} (reply) "
          end
        end

        return text_chunks.size
      end

      def post_exists?(post_text)
        !@account.statuses.find_by(text: post_text).nil?
      end

      def create_media(media_item, mime_type = 'image/jpeg')
        path = File.join(@root_path, media_item['uri'])
        media_attachment_params = {
          file: Rack::Test::UploadedFile.new(path, mime_type),
          # thumbnail: nil,
          # description: "test",
          # focus: nil
        }

        @account.media_attachments.create!(media_attachment_params)
      end

      def osm_url(lat, long)
        # Link to openstreetmap.org with a marker shown at lat, long coords
        "https://osm.org/?mlat=#{lat}&mlon=#{long}"
      end
    end
  end
end
