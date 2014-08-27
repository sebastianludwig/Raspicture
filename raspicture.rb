require 'bundler'
Dir.chdir File.dirname(__FILE__) do
  Bundler.require(:default)
end
require 'gosu/preview'

PICTURES_FOLDER = ARGV[1] || File.join(File.dirname(__FILE__), 'pictures')
THUMBNAILS_FOLDER = File.join(File.dirname(__FILE__), 'thumbnails')

def is_raspberry?
  `uname` == "Linux\n"
end

class Raspicture < Gosu::Window
  attr_accessor :scale_mode

  def initialize(source_folder, cycle_time)
    super Gosu::screen_width, Gosu::screen_height, fullscreen: is_raspberry?, update_interval: 100
    self.caption = 'PictureFrame'

    @cycle_time = cycle_time

    refresh_file_list
    @target_image_index = Gosu::random(0, @files.size).floor

    @target_image_blend = 0.0

    @scale_mode = :aspect_fill
  end

  def update
    return if @target_image

    if @target_image_index != @current_image_index
      @last_auto_cycle = Time.now
      @target_image = Gosu::Image.new @files[@target_image_index]
      @current_image_index = @target_image_index
    end

    next_image if Time.now - @last_auto_cycle > @cycle_time
  end

  def draw
    if @current_image
      draw_image @current_image, 0, 1 - @target_image_blend
    end

    if @target_image
      draw_image @target_image, 1, @target_image_blend

      @target_image_blend += 0.1

      if @target_image_blend >= 1
        @current_image = @target_image
        @target_image = nil
        GC.start
        @target_image_blend = 0
      end
    end
  end

  def draw_image(image, z_index, blend)
    case @scale_mode
    when :aspect_fit
        x_scale = width / image.width.to_f
        y_scale = height / image.height.to_f
        scale = [x_scale, y_scale].min
    when :aspect_fill
        x_scale = width / image.width.to_f
        y_scale = height / image.height.to_f
        scale = [x_scale, y_scale].max
    end

    x = (width - image.width * scale) / 2
    y = (height - image.height * scale) / 2

    color = Gosu::Color.new blend * 255, 255, 255, 255

    image.draw(x, y, z_index, scale, scale, color)
  end

  def button_down(key)
    close if key == Gosu::KbEscape
    next_image if key == Gosu::KbRight
    previous_image if key == Gosu::KbLeft
  end

  def refresh_file_list
    @files = Dir["#{PICTURES_FOLDER}/*.{png,jpeg,jpg}"]
  end

  def next_image
    @target_image_index = (@target_image_index + 1) % @files.size
  end

  def previous_image
    @target_image_index = (@target_image_index - 1) % @files.size
  end

  def list_images
    JSON.generate @files.map { |file| File.basename(file) }
  end

  def show_image(name)
    index = @files.index { |file| File.basename(file) == name }
    return if index.nil?
    @target_image_index = index
  end
end

raspicture = Raspicture.new(PICTURES_FOLDER, 30 * 60)

web_server = WEBrick::HTTPServer.new :Port => (ARGV[0] || 80)

index_action = Proc.new do |req, res|
  raspicture.refresh_file_list
  res['Content-Type'] = 'text/html; charset=utf-8'
  res.body = IO.read File.join(File.dirname(__FILE__), 'index.html')
end
web_server.mount_proc('/index', index_action)
web_server.mount_proc('/', index_action)
web_server.mount_proc('/next') { |req, res| raspicture.next_image }
web_server.mount_proc('/prev') { |req, res| raspicture.previous_image }
web_server.mount_proc('/list') { |req, res| res.body = raspicture.list_images }
web_server.mount_proc('/show') { |req, res| raspicture.show_image(req.query['image']) }
web_server.mount_proc('/shutdown') { |req, res| `shutdown -h now` if is_raspberry? }
web_server.mount_proc('/reboot') { |req, res| `reboot` if is_raspberry? }
web_server.mount_proc('/fill') { |req, res| raspicture.scale_mode = :aspect_fill }
web_server.mount_proc('/fit') { |req, res| raspicture.scale_mode = :aspect_fit }
web_server.mount_proc('/images/') do |req, res|

  picture_path = File.join(PICTURES_FOLDER, File.basename(req.path))
  thumbnail_path = File.join(THUMBNAILS_FOLDER, File.basename(req.path))
  if not File.exist?(thumbnail_path) or File.ctime(picture_path) > File.ctime(thumbnail_path)
    image = MiniMagick::Image.open(picture_path)
    image.combine_options do |c|
      c.auto_orient
      c.thumbnail "100x100^"
      c.gravity "center"
      c.extent "100x100"
    end
    image.write thumbnail_path
    puts "writte #{thumbnail_path}"
  end

  extension = File.extname(req.path).slice(1..-1).downcase
  extension = 'jpeg' if extension == 'jpg'
  res['Content-Type'] = "image/#{extension}"

  res.body = IO.binread thumbnail_path
end


# thumbnail cleanup
Dir.foreach(THUMBNAILS_FOLDER) do |filename|
  File.delete(File.join(THUMBNAILS_FOLDER, filename)) unless File.exist? File.join(PICTURES_FOLDER, filename)
end


web_thread = Thread.new do
  web_server.start
end


# HINT ['INT', 'TERM'].each ...?
trap('INT') do
  raspicture.close
  web_server.stop
  web_thread.join
end

raspicture.show

web_server.stop

web_thread.join

puts 'clean exit - yay'

