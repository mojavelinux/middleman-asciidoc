require 'asciidoctor' unless defined? Asciidoctor

module Middleman
  module AsciiDoc
    class AsciiDocExtension < ::Middleman::Extension
      # run after front matter (priority: 20) is processed and before other third-party extensions (priority: 50)
      self.resource_list_manipulator_priority = 30

      IMPLICIT_ATTRIBUTES = {
        'env' => 'site',
        'env-site' => '',
        'site-gen' => 'middleman',
        'site-gen-middleman' => '',
        'builder' => 'middleman',
        'builder-middleman' => '',
        'middleman-version' => ::Middleman::VERSION
      }

      option :attributes, [], 'Custom AsciiDoc attributes (Hash or Array)'
      option :backend, :html5, 'Moniker used to select output format (Symbol)'
      option :base_dir, nil, 'Base directory to use for the current AsciiDoc document; if nil, defaults to docdir (String)'
      option :safe, :safe, 'Safe mode level (Symbol)'

      def initialize app, options_hash = {}, &block
        super
        app.config.define_setting :asciidoc, {}, 'AsciiDoc processor options (Hash)'
        # NOTE support global :asciidoc_attributes setting for backwards compatibility
        app.config.define_setting :asciidoc_attributes, [], 'Custom AsciiDoc attributes (Hash or Array)'
      end

      # NOTE options passed to activate take precedence (e.g., activate :asciidoc, attributes: ['foo=bar'])
      def after_configuration
        if app.config.setting(:asciidoc).value_set?
          warn 'Using `set :asciidoc` to define options is deprecated. Please define options on `activate :asciidoc` instead.'
        end
        app.config[:asciidoc].tap do |cfg|
          attributes = {
            'site-root' => app.root.to_s,
            'site-source' => app.source_dir.to_s,
            'site-destination' => (app.root_path.join app.config[:build_dir]).to_s
          }
          attributes.update(attrs_as_hash cfg[:attributes]) if cfg.key? :attributes
          if options.setting(:attributes).value_set?
            attributes.update(attrs_as_hash options[:attributes])
          elsif app.config.setting(:asciidoc_attributes).value_set?
            attributes.update(attrs_as_hash app.config[:asciidoc_attributes])
          end
          unless (attributes.key? 'imagesdir') || (attributes.key? '!imagesdir')
            attributes['imagesdir'] = %(#{File.join((app.config[:http_prefix] || '/').chomp('/'), app.config[:images_dir])}@)
          end
          cfg[:attributes] = attributes.update IMPLICIT_ATTRIBUTES
          cfg[:base_dir] = (dir = options[:base_dir]) ? dir.to_s : dir if options.setting(:base_dir).value_set?
          # QUESTION ^ should we call expand_path on :base_dir if non-nil?
          cfg[:backend] = options[:backend] if options.setting(:backend).value_set?
          cfg[:backend] = (cfg[:backend] || :html5).to_sym
          cfg[:safe] = options[:safe] if options.setting(:safe).value_set?
          cfg[:safe] = (cfg[:safe] || :safe).to_sym
        end
      end

      def manipulate_resource_list resources
        default_page_layout = app.config[:layout] == :_auto_layout ? '' : app.config[:layout]
        asciidoc_opts = app.config[:asciidoc].merge parse_header_only: true
        asciidoc_opts[:attributes] = (asciidoc_attrs = asciidoc_opts[:attributes].merge 'skip-front-matter' => '')
        use_docdir_as_base_dir = asciidoc_opts[:base_dir].nil?
        resources.each do |resource|
          next unless (path = resource.source_file).present? && (path.end_with? '.adoc')

          # read AsciiDoc header only to set page options and data
          # header values can be accessed via app.data.page.<name> in the layout
          asciidoc_attrs['page-layout'] = %(#{resource.options[:layout] || default_page_layout}@)
          asciidoc_opts[:base_dir] = ::File.dirname path if use_docdir_as_base_dir
          doc = Asciidoctor.load_file path, asciidoc_opts
          opts = {}
          page = {}

          opts[:base_dir] = asciidoc_opts[:base_dir] if use_docdir_as_base_dir

          # NOTE page layout value cascades from site config -> front matter -> page-layout header attribute
          if doc.attr? 'page-layout'
            if (layout = doc.attr 'page-layout').empty?
              opts[:layout] = :_auto_layout
            else
              opts[:layout] = layout
            end
            opts[:layout_engine] = doc.attr 'page-layout-engine' if doc.attr? 'page-layout-engine'
          else
            opts[:layout] = false
            opts[:header_footer] = true
          end

          page[:title] = doc.doctitle if doc.header?
          ['author', 'email'].each do |key|
            page[key.to_sym] = doc.attr key if doc.attr? key
          end
          if !(page.key? :date) && (doc.attr? 'revdate')
            begin
              page[:date] = ::DateTime.parse(doc.attr 'revdate').to_time
            rescue
            end
          end

          unless (adoc_front_matter = doc.attributes
              .select {|name| name != 'page-layout' && name != 'page-layout-engine' && name.start_with?('page-') }
              .map {|name, val|
                  val = (val == '' ? '\'\'' : (val == '-' ? '\'-\'' : val))
                  %(:#{name[5..-1]}: #{val})
              }).empty?
            page.update(::YAML.load(adoc_front_matter * %(\n)))
          end

          # QUESTION should we use resource.ext == doc.outfilesuffix instead?
          unless resource.destination_path.end_with? doc.outfilesuffix
            # NOTE we must use << or else the layout gets disabled
            resource.destination_path << doc.outfilesuffix
          end

          resource.add_metadata options: opts, page: page
        end
      end

      def attrs_as_hash attrs
        if ::Hash === attrs
          ::Hash[attrs.map {|key, val|
            if key.end_with? '!'
              [%(!#{key.chop}), '']
            elsif val
              [key, (key.start_with? '!') ? '' : val]
            else
              [(key.start_with? '!') ? key : %(!#{key}), '']
            end
          }]
        else
          Array(attrs).inject({}) do |accum, entry|
            key, val = entry.split '=', 2
            if key.end_with? '!'
              accum[%(!#{key.chop})] = ''
            elsif key.start_with? '!'
              accum[key] = ''
            else
              accum[key] = val || ''
            end
            accum
          end
        end
      end
    end
  end
end
