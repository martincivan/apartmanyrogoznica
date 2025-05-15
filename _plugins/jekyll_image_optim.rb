require "digest"
require "fileutils"
require "image_optim"
require "mini_magick"
require "yaml"
require "thread"

Jekyll::Hooks.register :site, :pre_render do |site|
	config = YAML::load_file(File.join(site.source, "_config.yml"))
	config = config["jekyll_image_optim"] || {}
	image_optim_options = config["image_optim"] || {}
	resize_to = config["resize_to"] || "1600x1600>"
	cache_relative_dir = config["cache_dir"] || ".jekyll-cache"
	cache_dir = File.join(site.source, cache_relative_dir)
	out_dir = File.join(cache_dir, "out")
	index_yaml_path = File.join(cache_dir, "index.yml")

	FileUtils.mkdir_p(out_dir)
	FileUtils.touch(index_yaml_path)
	cache_index = YAML::load_file(index_yaml_path) || {}

	site.exclude << cache_relative_dir
	image_optim = ImageOptim.new(image_optim_options)

	# Mutex to protect shared resources
	index_mutex = Mutex.new

	# Prepare queue of images to process
	work_queue = Queue.new
	static_files = site.static_files.dup

	static_files.each do |static_file|
		next unless image_optim.optimizable?(static_file.path)
		work_queue << static_file
	end

	num_threads = config["threads"] || 4
	threads = []

	threads = num_threads.times.map do
		Thread.new do
			while !work_queue.empty?
				begin
					static_file = work_queue.pop(true)
				rescue ThreadError
					break
				end

				relative_path = static_file.relative_path
				new_path = File.join(out_dir, relative_path)

				begin
					image_md5 = Digest::MD5.file(static_file.path).hexdigest
					cc = nil
					index_mutex.synchronize { cc = cache_index[relative_path] }

					needs_processing = !cc || !File.exist?(new_path) || cc[:md5] != image_md5 || cc[:options] != image_optim_options

					if needs_processing
						puts "Processing image: #{relative_path}"
						FileUtils.mkdir_p(File.dirname(new_path))
						FileUtils.cp(static_file.path, new_path)

						# Resize image
						image = MiniMagick::Image.open(new_path)
						image.resize(resize_to)
						image.write(new_path)

						# Optimize
						image_optim.optimize_image!(new_path)

						# Update cache index thread-safely
						index_mutex.synchronize do
							cache_index[relative_path] = { md5: image_md5, options: image_optim_options }
							File.open(index_yaml_path, "w") { |f| f.write(cache_index.to_yaml) }
						end
					end
				rescue => e
					puts "Error processing #{relative_path}: #{e.message}"
				end
			end
		end
	end

	threads.each(&:join)

	# Replace the original files with optimized ones
	site.static_files.map! do |static_file|
		if image_optim.optimizable?(static_file.path)
			relative_path = static_file.relative_path
			Jekyll::StaticFile.new(site, out_dir, File.dirname(relative_path), File.basename(relative_path))
		else
			static_file
		end
	end
end
