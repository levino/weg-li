class AnalyzerJob < ApplicationJob
  retry_on EXIFR::MalformedJPEG, attempts: 15, wait: :exponentially_longer
  retry_on ActiveStorage::FileNotFoundError, attempts: 15, wait: :exponentially_longer
  discard_on Encoding::UndefinedConversionError

  def self.time_from_filename(filename)
    token = filename[/.*(20\d{6}_\d{6})/, 1]
    token ||= filename[/.*(20\d{2}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})/, 1]

    return nil unless token
    Time.zone.parse(token.gsub('-', '')) rescue nil
  end

  def perform(notice)
    fail NotYetAnalyzedError unless notice.photos.all?(&:analyzed?)

    analyze(notice)
  end

  def analyze(notice)
    plates = []
    brands = []
    colors = []
    dates = []

    notice.status = :open
    prefixes = notice.user.district&.prefixes

    notice.photos.each do |photo|
      exif = photo.service.download_file(photo.key) { |file| exifer.metadata(file) }
      notice.data_sets.create!(data: exif, kind: :exif, keyable: photo)

      if !notice.coordinates? && exif[:latitude].to_i.positive? && exif[:longitude].to_i.positive?
        notice.latitude = exif[:latitude]
        notice.longitude = exif[:longitude]
        notice.handle_geocoding
        prefixes = notice.district&.prefixes
      end

      dates << (time_from_meta(exif[:date_time]) || AnalyzerJob.time_from_filename(photo.filename.to_s))

      result = annotator.annotate_object(photo.key)
      if result.present?
        notice.data_sets.create!(data: result, kind: :google_vision, keyable: photo)
        if Annotator.unsafe?(result)
          notify("safe search violated for notice #{notice.id} with photo #{photo.id} on user #{notice.user.id}: https://www.weg.li/admin/notices/#{notice.token}")
        end

        plates += Annotator.grep_text(result) { |string| Vehicle.plate?(string, prefixes: prefixes) }
        brands += Annotator.grep_text(result) { |string| Vehicle.brand?(string) }
        colors += Annotator.dominant_colors(result)
      end
    end

    notice.apply_dates(dates)

    most_likely_registraton = Vehicle.most_likely?(plates)
    notice.apply_favorites(most_likely_registraton)

    notice.registration ||= most_likely_registraton
    notice.brand ||= Vehicle.most_likely?(brands)
    notice.color ||= Vehicle.most_likely?(colors)

    notice.save_incomplete!
  end

  private

  def time_from_meta(timestamp)
    timestamp.to_s.to_time
  rescue
    nil
  end

  def exifer
    @exifer ||= EXIFAnalyzer.new
  end

  def annotator
    @annotator ||= Annotator.new
  end
end
