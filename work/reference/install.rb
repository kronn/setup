require 'optparse'
require 'setup/config'

# TODO: we need to abort install if tests fail (check return code of TESTER)
#       We will also need to add a force install option then to by pass failed tests.
#
# TODO: Generate rdocs... Package developer may want to deactivate this. How?
#
# TODO: Should be using Rdoc programmatically, but load issue arose and an error
#       was being generated on ri generation. Reverting back to shelling out for now.

# The name of the package, used to install docs in system doc/ruby-{name}/ location.
# The information must be provided in a file called meta/package.
PACKAGE =(
  if file = Dir["{meta,.meta}/package"].first
    File.read(file).strip
  else
    nil
  end
)

# This is needed if a project has loadpaths other than the standard lib/.
# Not the routine is designed to handle YAML arrays or line by line list.
LOADPATH =(
  if file = Dir.glob('{meta,.meta}/loadpath').first
    raw = File.read(file).strip.chomp(']')
    raw.split(/[\n,]/).map do |e|
      e.strip.sub(/^[\[-]\s*/,'')
    end
  else
    nil
  end
)

# A ruby script that instructs setup how to run tests, located at meta/setup/test.rb
# If the tests fail, the script should exit with a fail status (eg. -1).
TESTER = Dir.glob('{meta,.meta}/setup/test{,rc}.rb', File::FNM_CASEFOLD).first

# A ruby script that instructs setup how to generate docs, located at meta/setup/doc.rb
# NOTE: Docs must be generate into the doc/ for them to be installed.
DOCTOR = Dir.glob('{meta,.meta}/setup/doc{,rc}.rb', File::FNM_CASEFOLD).first



module Setup

  # Installer class handles the actual install procedure,
  # as well as the other tasks, such as testing.

  class Installer

    MANIFEST  = '.cache/setup/installedfiles'

    FILETYPES = %w( bin lib ext data etc man doc )

    # Configuration
    attr :config

    attr_writer :trial
    attr_writer :trace
    attr_writer :quiet

    attr_accessor :install_prefix
    attr_accessor :install_no_test

    # New Installer.
    def initialize(config=nil) #:yield:
      srcroot = '.'
      objroot = '.'

      @config = config || Configuration.new

      @srcdir = File.expand_path(srcroot)
      @objdir = File.expand_path(objroot)
      @currdir = '.'

      self.quiet   = ENV['quiet']   if ENV['quiet']
      self.trace = ENV['trace'] if ENV['trace']
      self.trial = ENV['nowrite'] if ENV['nowrite']

      yield(self) if block_given?
    end

    #
    def inspect
      "#<#{self.class} #{File.basename(@srcdir)}>"
    end

    # Are we running an installation?
    def installation?; @installation; end
    def installation!; @installation = true; end

    def trial? ; @trial ; end
    def trace? ; @trace ; end
    def quiet? ; @quiet ; end

    #
    def trace_off #:yield:
      begin
        save, @trace = trace?, false
        yield
      ensure
        @trace = save
      end
    end

    #
    def report_header(phase)
       return if quiet?
       #center = "            "
       #c = (center.size - phase.size) / 2
       #center[c,phase.size] = phase.to_s.upcase
       line = '- ' * 4 + ' -' * 24
       #c = (line.size - phase.size) / 2
       line[5,phase.size] = " #{phase.to_s.upcase} "
       puts "\n" + line + "\n\n"
    end

    # Added these for future use in simplificaiton of design.

    def extensions
      @extensions ||= Dir['ext/**/extconf.rb']
    end

    def compiles?
      !extensions.empty?
    end

    #
    def noop(rel); end

    ##
    # Hook Script API bases
    #

    def srcdir_root
      @srcdir
    end

    def objdir_root
      @objdir
    end

    def relpath
      @currdir
    end

    ##
    # Task all
    #

    def exec_all
      exec_config
      exec_setup
      exec_test
      exec_doc
      exec_install
    end

    ##
    # TASK config
    #

    def exec_config
      report_header('config')
      config.env_config
      config.save_config
      config.show if trace?
      puts("Configuration saved.") unless quiet?
      exec_task_traverse 'config'
    end

    alias config_dir_bin noop
    alias config_dir_lib noop

    def config_dir_ext(rel)
      extconf if extdir?(curr_srcdir())
    end

    alias config_dir_data noop
    alias config_dir_etc noop
    alias config_dir_man noop
    alias config_dir_doc noop

    def extconf
      ruby "#{curr_srcdir()}/extconf.rb", config.extconfopt
    end

    ##
    # TASK show
    #

    def exec_show
      config.show
    end

    ##
    # TASK setup
    #
    # FIXME: Update shebang on install rather than before.
    def exec_setup
      report_header('setup')
      exec_task_traverse 'setup'
      puts "Ok."
    end

    def setup_dir_bin(rel)
      files_of(curr_srcdir()).each do |fname|
        update_shebang_line "#{curr_srcdir()}/#{fname}"  # MOVE TO INSTALL (BUT HOW?)
      end
    end

    alias setup_dir_lib noop

    def setup_dir_ext(rel)
      make if extdir?(curr_srcdir())
    end

    alias setup_dir_data noop
    alias setup_dir_etc noop
    alias setup_dir_man noop
    alias setup_dir_doc noop

    def update_shebang_line(path)
      return if trial?
      return if config.shebang == 'never'
      old = Shebang.load(path)
      if old
        if old.args.size > 1
          $stderr.puts "warning: #{path}"
          $stderr.puts "Shebang line has too many args."
          $stderr.puts "It is not portable and your program may not work."
        end
        new = new_shebang(old)
        return if new.to_s == old.to_s
      else
        return unless config.shebang == 'all'
        new = Shebang.new(config.rubypath)
      end
      $stderr.puts "updating shebang: #{File.basename(path)}" if trace?
      open_atomic_writer(path) {|output|
        File.open(path, 'rb') {|f|
          f.gets if old   # discard
          output.puts new.to_s
          output.print f.read
        }
      }
    end

    def new_shebang(old)
      if /\Aruby/ =~ File.basename(old.cmd)
        Shebang.new(config.rubypath, old.args)
      elsif File.basename(old.cmd) == 'env' and old.args.first == 'ruby'
        Shebang.new(config.rubypath, old.args[1..-1])
      else
        return old unless config.shebang == 'all'
        Shebang.new(config.rubypath)
      end
    end

    def open_atomic_writer(path, &block)
      tmpfile = File.basename(path) + '.tmp'
      begin
        File.open(tmpfile, 'wb', &block)
        File.rename tmpfile, File.basename(path)
      ensure
        File.unlink tmpfile if File.exist?(tmpfile)
      end
    end

    class Shebang
      def Shebang.load(path)
        line = nil
        File.open(path) {|f|
          line = f.gets
        }
        return nil unless /\A#!/ =~ line
        parse(line)
      end

      def Shebang.parse(line)
        cmd, *args = *line.strip.sub(/\A\#!/, '').split(' ')
        new(cmd, args)
      end

      def initialize(cmd, args = [])
        @cmd = cmd
        @args = args
      end

      attr_reader :cmd
      attr_reader :args

      def to_s
        "#! #{@cmd}" + (@args.empty? ? '' : " #{@args.join(' ')}")
      end
    end

    ##
    # TASK test
    #
    # Complexities arise in trying to figure out what test framework
    # is used, and how to run tests. To simplify the process, this
    # simply looks for a script in meta/setup called testrc.rb,
    # or just test.rb.
    #
    def exec_test
      return if install_no_test
      file = TESTER
      if file
        report_header('test')
        ruby(file)
      end
      #puts "Ok." unless quiet?
    end

    ### DEPRECATED
    #def exec_test
      #runner = config.testrunner
      #case runner
      #when 'testrb'  # TODO: needs work
      #  opt = []
      #  opt << " -v" if trace?
      #  opt << " --runner #{runner}"
      #  if File.file?('test/suite.rb')
      #    notests = false
      #    opt << "test/suite.rb"
      #  else
      #    notests = Dir["test/**/*.rb"].empty?
      #    lib = ["lib"] + config.extensions.collect{ |d| File.dirname(d) }
      #    opt << "-I" + lib.join(':')
      #    opt << Dir["test/**/{test,tc}*.rb"]
      #  end
      #  opt = opt.flatten.join(' ').strip
      #  # run tests
      #  if notests
      #    $stderr.puts 'no test in this package' if trace?
      #  else
      #    cmd = "testrb #{opt}"
      #    $stderr.puts cmd if trace?
      #    system cmd  #config.ruby "-S testrb", opt
      #  end
      #else # autorunner
      #  unless File.directory?('test')
      #    $stderr.puts 'no test in this package' if trace?
      #    return
      #  end
      #  begin
      #    require 'test/unit'
      #  rescue LoadError
      #    setup_rb_error 'test/unit cannot loaded.  You need Ruby 1.8 or later to invoke this task.'
      #  end
      #  lib = ["lib"] + config.extensions.collect{ |d| File.dirname(d) }
      #  lib.each{ |l| $LOAD_PATH << l }
      #  autorunner = Test::Unit::AutoRunner.new(true)
      #  autorunner.to_run << 'test'
      #  autorunner.run
      #end
    #end

    # MAYBE: We could traverse and run each test independently (?)
    #def test_dir_test
    #end

    ##
    # TASK doc

    def exec_doc
      return if config.withoutdoc?
      report_header('doc')
      if file = DOCTOR
        ruby(file)
      else
        exec_rdoc
      end
      exec_ri
    end

    # Generate rdocs.
    #
    # meta/package or .meta/package
    #
    def exec_rdoc
      main = Dir.glob("README{,.*}", File::FNM_CASEFOLD).first

      if File.exist?('.document')
        files = File.read('.document').split("\n")
        files.reject!{ |l| l =~ /^\s*[#]/ || l !~ /\S/ }
        files.collect!{ |f| f.strip }
      else
        files = []
        files << main  if main
        files << 'lib' if File.directory?('lib')
        files << 'ext' if File.directory?('ext')
      end

      checkfiles = (files + files.map{ |f| Dir[File.join(f,'*','**')] }).flatten.uniq
      if FileUtils.uptodate?('doc/rdoc', checkfiles)
        puts "RDocs look current."
        return
      end

      output    = 'doc/rdoc'
      title     = (PACKAGE.capitalize + " API").strip if PACKAGE
      template  = config.doctemplate || 'html'

      opt = []
      opt << "-U"
      opt << "-q" #if quiet?
      opt << "--op=#{output}"
      #opt << "--template=#{template}"
      opt << "--title=#{title}"
      opt << "--main=#{main}"     if main
      #opt << "--debug"
      opt << files

      opt = opt.flatten

      cmd = "rdoc " + opt.join(' ')

      if trial?
        puts cmd 
      else
        begin
          system(cmd)
          #require 'rdoc/rdoc'
          #::RDoc::RDoc.new.document(opt)
          puts "Ok rdoc." unless quiet?
        rescue Exception
          puts "Fail rdoc."
          puts "Command was: '#{cmd}'"
          puts "Proceeding with install anyway."
        end
      end
    end

    # Generate ri documentation.

    def exec_ri
      case config.installdirs
      when 'std'
        output = "--ri-system"
      when 'site'
        output = "--ri-site"
      when 'home'
        output = "--ri"
      else
        abort "bad config: sould not be possible -- installdirs = #{config.installdirs}"
      end

      if File.exist?('.document')
        files = File.read('.document').split("\n")
        files.reject!{ |l| l =~ /^\s*[#]/ || l !~ /\S/ }
        files.collect!{ |f| f.strip }
      else
        files = []
        files << 'lib' if File.directory?('lib')
        files << 'ext' if File.directory?('ext')
      end

      opt = []
      opt << "-U"
      opt << "-q" #if quiet?
      #opt << "-D" #if $DEBUG
      opt << output
      opt << files

      opt = opt.flatten

      cmd = "rdoc " + opt.join(' ')

      if trial?
        puts cmd
      else
        # Generate in system location specified
        begin
          system(cmd)
          #require 'rdoc/rdoc'
          #::RDoc::RDoc.new.document(opt)
          puts "Ok ri." unless quiet?
        rescue Exception
          puts "Fail ri."
          puts "Command was: '#{cmd}'"
          puts "Proceeding with install anyway."
        end
        # Now in local directory
        #opt = []
        #opt << "-U"
        #opt << "--ri --op 'doc/ri'"
        #opt << files
        #opt = opt.flatten
        #::RDoc::RDoc.new.document(opt)
      end
    end

    ##
    # TASK install
    #

    def exec_install
      report_header('install')
      installation!  # we are installing
      #rm_f MANIFEST # we'll append rather then delete!
      exec_task_traverse 'install'
      $stderr.puts "Done.\n\n" unless quiet?
    end

    def install_dir_bin(rel)
      install_files targetfiles(), "#{config.bindir}/#{rel}", 0755
    end

    def install_dir_lib(rel)
      install_files libfiles(), "#{config.rbdir}/#{rel}", 0644
    end

    def install_dir_ext(rel)
      return unless extdir?(curr_srcdir())
      install_files rubyextentions('.'),
                    "#{config.sodir}/#{File.dirname(rel)}", 0555
    end

    def install_dir_data(rel)
      install_files targetfiles(), "#{config.datadir}/#{rel}", 0644
    end

    def install_dir_etc(rel)
      # FIXME: should not remove current config files
      # (rename previous file to .old/.org)
      install_files targetfiles(), "#{config.sysconfdir}/#{rel}", 0644
    end

    def install_dir_man(rel)
      install_files targetfiles(), "#{config.mandir}/#{rel}", 0644
    end

    # doc installs to directory named: "ruby-#{package}"
    def install_dir_doc(rel)
      return if config.withoutdoc?
      return unless PACKAGE
      dir = "#{config.docdir}/ruby-#{PACKAGE}/#{rel}" # "#{config.docdir}/#{rel}"
      install_files targetfiles(), dir, 0644
    end

    def install_files(list, dest, mode)
      mkdir_p dest, install_prefix
      list.each do |fname|
        install fname, dest, mode, install_prefix
      end
    end

    def libfiles
      glob_reject(%w(*.y *.output), targetfiles())
    end

    def rubyextentions(dir)
      ents = glob_select("*.#{dllext}", targetfiles())
      if ents.empty?
        setup_rb_error "no ruby extention exists: 'ruby #{$0} setup' first"
      end
      ents
    end

    def dllext
      ConfigTable::RBCONFIG['DLEXT']
    end

    def targetfiles
      mapdir(existfiles() - hookfiles())
    end

    def mapdir(ents)
      ents.map {|ent|
        if File.exist?(ent)
        then ent                         # objdir
        else "#{curr_srcdir()}/#{ent}"   # srcdir
        end
      }
    end

    # picked up many entries from cvs-1.11.1/src/ignore.c
    JUNK_FILES = %w(
      core RCSLOG tags TAGS .make.state
      .nse_depinfo #* .#* cvslog.* ,* .del-* *.olb
      *~ *.old *.bak *.BAK *.orig *.rej _$* *$

      *.org *.in .*
    )

    def existfiles
      glob_reject(JUNK_FILES, (files_of(curr_srcdir()) | files_of('.')))
    end

    def hookfiles
      %w( pre-%s post-%s pre-%s.rb post-%s.rb ).map {|fmt|
        %w( etc setup install clean ).map {|t| sprintf(fmt, t) }
      }.flatten
    end

    def glob_select(pat, ents)
      re = globs2re([pat])
      ents.select {|ent| re =~ ent }
    end

    def glob_reject(pats, ents)
      re = globs2re(pats)
      ents.reject {|ent| re =~ ent }
    end

    GLOB2REGEX = {
      '.' => '\.',
      '$' => '\$',
      '#' => '\#',
      '*' => '.*'
    }

    def globs2re(pats)
      /\A(?:#{
        pats.map {|pat| pat.gsub(/[\.\$\#\*]/) {|ch| GLOB2REGEX[ch] } }.join('|')
      })\z/
    end

    ##
    # TASK uninstall
    #

    def exec_uninstall
      paths = File.read(MANIFEST).split("\n")
      dirs, files = paths.partition{ |f| File.dir?(f) }

      remove = []
      files.uniq.each do |file|
        next if /^\#/ =~ file  # skip comments
        remove << file if File.exist?(file)
      end

      if trace? && !trial?
        puts remove.collect{ |f| "rm #{f}" }.join("\n")
        ans = ask("Continue?", "yN")
        case ans
        when 'y', 'Y', 'yes'
        else
          return # abort?
        end
      end

      remove.each do |file|
        rm_f(file)
      end

      dirs.each do |dir|
        # okay this is over kill, but playing it safe...
        empty = Dir[File.join(dir,'*')].empty?
        begin
          if trial?
            $stderr.puts "rmdir #{dir}"
          else
            rmdir(dir) if empty
          end
        rescue Errno::ENOTEMPTY
          $stderr.puts "may not be empty -- #{dir}" if trace?
        end
      end

      rm_f(MANIFEST)
    end

    ##
    # TASK clean
    #

    def exec_clean
      exec_task_traverse 'clean'
      rm_f ConfigTable::CONFIGFILE
      #rm_f MANIFEST  # only on clobber!
    end

    alias clean_dir_bin noop
    alias clean_dir_lib noop
    alias clean_dir_data noop
    alias clean_dir_etc noop
    alias clean_dir_man noop
    alias clean_dir_doc noop

    def clean_dir_ext(rel)
      return unless extdir?(curr_srcdir())
      make 'clean' if File.file?('Makefile')
    end

    ##
    # TASK distclean
    #

    def exec_distclean
      exec_task_traverse 'distclean'
      rm_f ConfigTable::CONFIGFILE
      rm_f MANIFEST
    end

    alias distclean_dir_bin noop
    alias distclean_dir_lib noop

    def distclean_dir_ext(rel)
      return unless extdir?(curr_srcdir())
      make 'distclean' if File.file?('Makefile')
    end

    alias distclean_dir_data noop
    alias distclean_dir_etc noop
    alias distclean_dir_man noop

    def distclean_dir_doc(rel)
      #rm_rf('rdoc') if File.directory?('rdoc')  # RDOC HERE
    end

    ##
    # Traversing
    #

    def exec_task_traverse(task)
      run_hook "pre-#{task}"
      FILETYPES.each do |type|
        if type == 'ext' and config.withoutext? #== 'yes'
          $stderr.puts 'skipping ext/* by user option' if trace?
          next
        end
        # TODO: I think setup.rb would have to rewritten to handle this.
        if type == 'lib' && LOADPATH
          LOADPATH.each do |lp|
            dirs = Dir[File.join(lp,'*/')]
            dirs.each do |d|
              traverse task, d.chomp('/'), "#{task}_dir_#{type}", "#{lp}/"
            end
          end
        else
          traverse task, type, "#{task}_dir_#{type}"
        end
      end
      run_hook "post-#{task}"
    end

    def traverse(task, rel, mid, clip=nil)
      dive_into(rel) {
        run_hook "pre-#{task}"
        if clip
          rel2 = rel.sub(/\A#{Regexp.escape(clip)}/,'')
        else
          rel2 = rel.sub(%r[\A.*?(?:/|\z)], '')  # trans: this clips off 'lib/'. Why so complex?
        end
        __send__ mid, rel2
        directories_of(curr_srcdir()).each do |d|
          traverse task, "#{rel}/#{d}", mid
        end
        run_hook "post-#{task}"
      }
    end

    #
    def dive_into(rel)
      return unless File.dir?("#{@srcdir}/#{rel}")

      dir = File.basename(rel)
      Dir.mkdir dir unless File.dir?(dir)
      prevdir = Dir.pwd
      Dir.chdir dir
      $stderr.puts '---> ' + rel if trace?
      @currdir = rel
      yield
      Dir.chdir prevdir
      $stderr.puts '<--- ' + rel if trace?
      @currdir = File.dirname(rel)
    end

    #
    def run_hook(id)
      path = [ "#{curr_srcdir()}/#{id}",
               "#{curr_srcdir()}/#{id}.rb" ].detect {|cand| File.file?(cand) }
      return unless path
      begin
        instance_eval File.read(path), path, 1
      rescue
        raise if $DEBUG
        setup_rb_error "hook #{path} failed:\n" + $!.message
      end
    end

    ##
    # File Operations
    #
    # This module requires: #trace?, #trial?

    def binread(fname)
      File.open(fname, 'rb'){ |f|
        return f.read
      }
    end

    def mkdir_p(dirname, prefix = nil)
      dirname = prefix + File.expand_path(dirname) if prefix
      $stderr.puts "mkdir -p #{dirname}" if trace?
      return if trial?

      # Does not check '/', it's too abnormal.
      dirs = File.expand_path(dirname).split(%r<(?=/)>)
      if /\A[a-z]:\z/i =~ dirs[0]
        disk = dirs.shift
        dirs[0] = disk + dirs[0]
      end
      dirs.each_index do |idx|
        path = dirs[0..idx].join('')
        Dir.mkdir path unless File.dir?(path)
        record_installation(path)  # also record directories made
      end
    end

    def rm_f(path)
      $stderr.puts "rm -f #{path}" if trace?
      return if trial?
      force_remove_file path
    end

    def rm_rf(path)
      $stderr.puts "rm -rf #{path}" if trace?
      return if trial?
      remove_tree path
    end

    def rmdir(path)
      $stderr.puts "rmdir #{path}" if trace?
      return if trial?
      Dir.rmdir path
    end

    def remove_tree(path)
      if File.symlink?(path)
        remove_file path
      elsif File.dir?(path)
        remove_tree0 path
      else
        force_remove_file path
      end
    end

    def remove_tree0(path)
      Dir.foreach(path) do |ent|
        next if ent == '.'
        next if ent == '..'
        entpath = "#{path}/#{ent}"
        if File.symlink?(entpath)
          remove_file entpath
        elsif File.dir?(entpath)
          remove_tree0 entpath
        else
          force_remove_file entpath
        end
      end
      begin
        Dir.rmdir path
      rescue Errno::ENOTEMPTY
        # directory may not be empty
      end
    end

    def move_file(src, dest)
      force_remove_file dest
      begin
        File.rename src, dest
      rescue
        File.open(dest, 'wb') {|f|
          f.write binread(src)
        }
        File.chmod File.stat(src).mode, dest
        File.unlink src
      end
    end

    def force_remove_file(path)
      begin
        remove_file path
      rescue
      end
    end

    def remove_file(path)
      File.chmod 0777, path
      File.unlink path
    end

    def install(from, dest, mode, prefix = nil)
      $stderr.puts "install #{from} #{dest}" if trace?
      return if trial?

      realdest = prefix ? prefix + File.expand_path(dest) : dest
      realdest = File.join(realdest, File.basename(from)) if File.dir?(realdest)
      str = binread(from)
      if diff?(str, realdest)
        trace_off {
          rm_f realdest if File.exist?(realdest)
        }
        File.open(realdest, 'wb') {|f|
          f.write str
        }
        File.chmod mode, realdest

        if prefix
          path = realdest.sub(prefix, '')
        else
          path = realdest
        end

        record_installation(path)
      end
    end

    def record_installation(path)
      FileUtils.mkdir_p(File.dirname("#{objdir_root()}/#{MANIFEST}"))
      File.open("#{objdir_root()}/#{MANIFEST}", 'a') do |f|
        f.puts(path)
      end
    end

    def diff?(new_content, path)
      return true unless File.exist?(path)
      new_content != binread(path)
    end

    def command(*args)
      $stderr.puts args.join(' ') if trace?
      system(*args) or raise RuntimeError,
          "system(#{args.map{|a| a.inspect }.join(' ')}) failed"
    end

    def ruby(*args)
      command config.rubyprog, *args
    end

    def make(task = nil)
      command(*[config.makeprog, task].compact)
    end

    def extdir?(dir)
      File.exist?("#{dir}/MANIFEST") or File.exist?("#{dir}/extconf.rb")
    end

    def files_of(dir)
      Dir.open(dir) {|d|
        return d.select {|ent| File.file?("#{dir}/#{ent}") }
      }
    end

    DIR_REJECT = %w( . .. CVS SCCS RCS CVS.adm .svn )

    def directories_of(dir)
      Dir.open(dir) {|d|
        return d.select {|ent| File.dir?("#{dir}/#{ent}") } - DIR_REJECT
      }
    end

    # Ask a question of the user.
    def ask(question, answers=nil)
      $stdout << "#{question}"
      $stdout << " [#{answers}] " if answers
      until inp = $stdin.gets ; sleep 1 ; end
      inp.strip
    end

    ##
    # Hook Script API
    #
    # These require: #srcdir_root, #objdir_root, #relpath
    #

    #
    def get_config(key)
      config[key]
    end

    # obsolete: use metaconfig to change configuration
    # TODO: what to do with?
    def set_config(key, val)
      config[key] = val
    end

    # srcdir/objdir (works only in the package directory)
    #
    # TODO: Since package directory has been deprecated these
    # probably can be worked out of the system. ?

    #
    def curr_srcdir
      "#{srcdir_root()}/#{relpath()}"
    end

    def curr_objdir
      "#{objdir_root()}/#{relpath()}"
    end

    def srcfile(path)
      "#{curr_srcdir()}/#{path}"
    end

    def srcexist?(path)
      File.exist?(srcfile(path))
    end

    def srcdirectory?(path)
      File.dir?(srcfile(path))
    end

    def srcfile?(path)
      File.file?(srcfile(path))
    end

    def srcentries(path = '.')
      Dir.open("#{curr_srcdir()}/#{path}") {|d|
        return d.to_a - %w(. ..)
      }
    end

    def srcfiles(path = '.')
      srcentries(path).select {|fname|
        File.file?(File.join(curr_srcdir(), path, fname))
      }
    end

    def srcdirectories(path = '.')
      srcentries(path).select {|fname|
        File.dir?(File.join(curr_srcdir(), path, fname))
      }
    end

  end

end

