require "fileutils"
require "pathname"
require "tempfile"

require "active_support/ordered_options"
require "sprockets"

require "requirejs/rails/builder"
require "requirejs/rails/config"

namespace :requirejs do
  # This method was backported from an earlier version of Sprockets.
  def ruby_rake_task(task, force = true)
    env = ENV["RAILS_ENV"] || "production"
    groups = ENV["RAILS_GROUPS"] || "assets"
    args = [$0, task, "RAILS_ENV=#{env}", "RAILS_GROUPS=#{groups}"]
    args << "--trace" if Rake.application.options.trace
    ruby *args
  end

  # From Rails 3 assets.rake; we have the same problem:
  #
  # We are currently running with no explicit bundler group
  # and/or no explicit environment - we have to reinvoke rake to
  # execute this task.
  def invoke_or_reboot_rake_task(task)
    if ENV['RAILS_GROUPS'].to_s.empty? || ENV['RAILS_ENV'].to_s.empty?
      ruby_rake_task task
    else
      Rake::Task[task].invoke
    end
  end

  requirejs = ActiveSupport::OrderedOptions.new
  path_extension_pattern = Regexp.new("\\.(\\w+)\\z")

  task clean: ["requirejs:setup"] do
    FileUtils.remove_entry_secure(requirejs.config.source_dir, true)
    FileUtils.remove_entry_secure(requirejs.driver_path, true)
  end

  task setup: ["assets:environment"] do
    unless defined?(Sprockets)
      warn "Cannot precompile assets if sprockets is disabled. Please set config.assets.enabled to true"
      exit
    end

    # Ensure that action view is loaded and the appropriate
    # sprockets hooks get executed
    _ = ActionView::Base

    requirejs.env = Rails.application.config.assets

    requirejs.sprockets = Rails.application.assets || ::Sprockets::Railtie.build_environment(Rails.application)

    # Preserve the original asset paths, as we'll be manipulating them later
    requirejs.env_paths = requirejs.env.paths.dup
    requirejs.config = Rails.application.config.requirejs
    requirejs.builder = Requirejs::Rails::Builder.new(requirejs.config)
    requirejs.manifest = {}
  end

  task :test_node do
    begin
      `node -v`
    rescue Errno::ENOENT
      STDERR.puts <<-EOM
Unable to find 'node' on the current path, required for precompilation
using the requirejs-ruby gem. To install node.js, see http://nodejs.org/
OS X Homebrew users can use 'brew install node'.
      EOM
      exit 1
    end
  end

  namespace :precompile do
    task all: ["requirejs:precompile:prepare_source",
               "requirejs:precompile:generate_rjs_driver",
               "requirejs:precompile:run_rjs",
               "requirejs:precompile:digestify_and_compress"]

    # Invoke another ruby process if we're called from inside
    # assets:precompile so we don't clobber the environment
    #
    # We depend on test_node here so we'll fail early and hard if node
    # isn't available.
    task external: ["requirejs:test_node"] do
      ruby_rake_task "requirejs:precompile:all"
    end

    # Copy all assets to the temporary staging directory.
    task prepare_source: ["requirejs:setup",
                          "requirejs:clean"] do
      bower_json_pattern = Regexp.new("\\A(.*)/bower\\.json\\z")

      js_ext = if requirejs.env.respond_to?(:extension_for_mime_type)
        requirejs.env.extension_for_mime_type("application/javascript")
      else
        requirejs.env.mime_types["application/javascript"][:extensions].first
      end

      requirejs.config.source_dir.mkpath

      # Save the original JS compressor and cache, which will be restored later.

      original_js_compressor = requirejs.env.js_compressor
      requirejs.env.js_compressor = false

      original_cache = requirejs.env.cache
      requirejs.env.cache = nil

      requirejs.sprockets.each_file do |file|
        begin
          asset_uri, _ = requirejs.sprockets.resolve! file
          asset = requirejs.sprockets.load asset_uri
          asset_logical_path = asset.logical_path
          if requirejs.config.logical_path_patterns.any? { |pattern| pattern.match asset_logical_path }
            m = ::Requirejs::Rails::Config::BOWER_PATH_PATTERN.match(asset_logical_path)
            if !m
              target_file = requirejs.config.source_dir.join(asset_logical_path)
              puts "Copying js file #{target_file}"
              asset.write_to(target_file)
            else
              raise "Not supported yet"
            end
          end
        rescue
          # Ignore if precompiled assets fail.
          # This happens for example if we stumble on a scss file that has
          # a variable defined elsewhere.
        end
      end

      # Restore the original JS compressor and cache.
      requirejs.env.js_compressor = original_js_compressor
      requirejs.env.cache = original_cache
    end

    task generate_rjs_driver: ["requirejs:setup"] do
      requirejs.builder.generate_rjs_driver
    end

    task run_rjs: ["requirejs:setup",
                   "requirejs:test_node"] do
      requirejs.config.build_dir.mkpath
      requirejs.config.target_dir.mkpath
      requirejs.config.driver_path.dirname.mkpath

      result = `node "#{requirejs.config.driver_path}"`
      unless $?.success?
        raise RuntimeError, "Asset compilation with node failed with error:\n\n#{result}\n"
      end
    end

    # Copy each built asset, identified by a named module in the
    # build config, to its Sprockets digestified name.
    task digestify_and_compress: ["requirejs:precompile:run_rjs"] do
      requirejs.config.build_config["modules"].each do |m|
        module_name = requirejs.config.module_name_for(m)
        paths = requirejs.config.build_config["paths"] || {}
        module_script_name = "#{module_name}.js"

        # Is there a `paths` entry for the module?
        if !paths[module_name]
          asset_name = module_script_name
        else
          asset_name = "#{paths[module_name]}.js"
        end

        asset = requirejs.sprockets.find_asset(asset_name)

        built_asset_path = requirejs.config.build_dir.join(asset_name)

        # Compute the digest based on the contents of the compiled file, *not* on the contents of the RequireJS module.
        hex_digest = requirejs.sprockets.pack_hexdigest(requirejs.sprockets.digest_class.digest(built_asset_path.to_s))
        digest_name = asset.logical_path.gsub(path_extension_pattern) { |ext| "-#{hex_digest}#{ext}" }

        digest_asset_path = requirejs.config.target_dir + digest_name

        # Ensure that the parent directory `a/b` for modules with names like `a/b/c` exist.
        digest_asset_path.dirname.mkpath

        requirejs.manifest[module_script_name] = digest_name
        FileUtils.cp built_asset_path, digest_asset_path

        # Create the compressed versions
        File.open("#{built_asset_path}.gz", 'wb') do |f|
          zgw = Zlib::GzipWriter.new(f, Zlib::BEST_COMPRESSION)
          zgw.write built_asset_path.read
          zgw.close
        end
        FileUtils.cp "#{built_asset_path}.gz", "#{digest_asset_path}.gz"

        requirejs.config.manifest_path.open('wb') do |f|
          YAML.dump(requirejs.manifest, f)
        end
      end
    end
  end

  desc "Precompile RequireJS-managed assets"
  task :precompile do
    invoke_or_reboot_rake_task "requirejs:precompile:all"
  end
end

task "assets:precompile" => ["requirejs:precompile:external"]
