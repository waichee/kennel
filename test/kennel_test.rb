# frozen_string_literal: true
require_relative "test_helper"
require "tmpdir"

SingleCov.covered!

describe Kennel do
  def write(file, content)
    folder = File.dirname(file)
    FileUtils.mkdir_p folder unless File.exist?(folder)
    File.write file, content
  end

  let(:models_count) { 4 }

  capture_all
  in_temp_dir
  with_env DATADOG_APP_KEY: "app", DATADOG_API_KEY: "api"

  before do
    write "projects/simple.rb", <<~RUBY
      class TempProject < Kennel::Models::Project
        defaults(
          team: -> { TestTeam.new },
          parts: -> { [
            Kennel::Models::Monitor.new(
              self,
              type: -> { "query alert" },
              kennel_id: -> { 'foo' },
              query: -> { "avg(last_5m) > \#{critical}" },
              critical: -> { 1 }
            )
          ] }
        )
      end
    RUBY
  end

  before do
    Kennel.instance_variable_set(:@generated, nil)
    Kennel.instance_variable_set(:@api, nil)
    Kennel.instance_variable_set(:@syncer, nil)
    Zeitwerk::Loader.any_instance.stubs(:setup)
  end

  # we need to clean up so new definitions of TempProject trigger subclass addition
  # and leftover classes do not break other tests
  after do
    Kennel::Models::Project.subclasses.delete_if { |c| c.name.match?(/TestProject\d|TempProject/) }
    Object.send(:remove_const, :TempProject) if defined?(TempProject)
    Object.send(:remove_const, :TempProject2) if defined?(TempProject2)
  end

  describe ".generate" do
    it "generates" do
      Kennel.generate
      content = File.read("generated/temp_project/foo.json")
      assert content.start_with?("{\n") # pretty generated
      json = JSON.parse(content, symbolize_names: true)
      json[:query].must_equal "avg(last_5m) > 1"
    end

    it "keeps same" do
      old = Time.now - 10
      Kennel.generate
      FileUtils.touch "generated/temp_project/foo.json", mtime: old
      Kennel.generate
      File.mtime("generated/temp_project/foo.json").must_equal old
    end

    it "overrides different" do
      old = Time.now - 10
      Kennel.generate
      FileUtils.touch "generated/temp_project/foo.json", mtime: old
      File.write "generated/temp_project/foo.json", "x"
      Kennel.generate
      File.mtime("generated/temp_project/foo.json").wont_equal old
    end

    it "cleans up old stuff" do
      nested = "generated/foo/bar.json"
      write nested, "HO"
      plain = "generated/bar.json"
      write plain, "HO"
      Kennel.generate
      refute File.exist?(nested)
      refute File.exist?(plain)
    end

    it "can filter by project" do
      other = "generated/foo/bar.json"
      write other, "HO"
      with_env(PROJECT: "temp_project") { Kennel.generate }
      assert File.exist?(other)
      assert File.exist?("generated/temp_project/foo.json")
    end

    it "does not generate for other projects" do
      write "projects/no2.rb", File.read("projects/simple.rb").sub("TempProject", "TempProject2")
      with_env(PROJECT: "temp_project") { Kennel.generate }
      refute File.exist?("generated/temp_project2/foo.json")
      assert File.exist?("generated/temp_project/foo.json")
    end

    it "complains when everything would be filtered" do
      e = assert_raises(RuntimeError) { with_env(PROJECT: "foo") { Kennel.generate } }
      e.message.must_equal <<~TXT.strip
        foo does not match any projects, try any of these:
        sub_test_project
        temp_project
        test_project
      TXT
    end

    it "complains when duplicates would be written" do
      write "projects/a.rb", <<~RUBY
        class TestProject2 < Kennel::Models::Project
          defaults(parts: -> { Array.new(2).map { Kennel::Models::Monitor.new(self, kennel_id: -> {"bar"}) } })
        end
      RUBY
      e = assert_raises(RuntimeError) { Kennel.generate }
      e.message.must_equal <<~ERROR
        test_project2:bar is defined 2 times
        use a different `kennel_id` when defining multiple projects/monitors/dashboards to avoid this conflict
      ERROR
    end

    it "shows helpful autoload errors for parts" do
      write "projects/a.rb", <<~RUBY
        class TestProject3 < Kennel::Models::Project
          FooBar::BazFoo
        end
      RUBY
      e = assert_raises(NameError) { Kennel.generate }
      e.message.must_equal("\n" + <<~MSG.gsub(/^/, "  "))
        uninitialized constant TestProject3::FooBar
        Unable to load TestProject3::FooBar from parts/test_project3/foo_bar.rb
        - Option 1: rename the constant or the file it lives in, to make them match
        - Option 2: Use `require` or `require_relative` to load the constant
      MSG
    end

    it "shows helpful autoload errors for teams" do
      write "projects/a.rb", <<~RUBY
        class TestProject4 < Kennel::Models::Project
          Teams::BazFoo
        end
      RUBY
      e = assert_raises(NameError) { Kennel.generate }
      e.message.must_equal("\n" + <<~MSG.gsub(/^/, "  "))
        uninitialized constant Teams::BazFoo
        Unable to load Teams::BazFoo from teams/baz_foo.rb
        - Option 1: rename the constant or the file it lives in, to make them match
        - Option 2: Use `require` or `require_relative` to load the constant
      MSG
    end

    it "shows unparseable NameError" do
      write "projects/a.rb", <<~RUBY
        class TestProject5 < Kennel::Models::Project
          raise NameError, "wut"
        end
      RUBY
      e = assert_raises(NameError) { Kennel.generate }
      e.message.must_equal "wut"
    end
  end

  describe ".plan" do
    it "plans" do
      Kennel::Api.any_instance.expects(:list).times(models_count).returns([])
      Kennel.plan
      stdout.string.must_include "Plan:\n\e[32mCreate monitor temp_project:foo\e[0m\n"
    end
  end

  describe ".update" do
    before { STDIN.expects(:tty?).returns(true) }

    it "update" do
      Kennel::Api.any_instance.expects(:list).times(models_count).returns([])
      STDIN.expects(:gets).returns("y\n") # proceed ? ... yes!
      Kennel::Api.any_instance.expects(:create).returns(id: 123)

      Kennel.update

      stderr.string.must_include "press 'y' to continue"
      stdout.string.must_include "Created monitor temp_project:foo https://app.datadoghq.com/monitors#123"
    end

    it "does not update when user does not confirm" do
      Kennel::Api.any_instance.expects(:list).times(models_count).returns([])
      STDIN.expects(:gets).returns("n\n") # proceed ? ... no!

      Kennel.update

      stderr.string.must_match(/press 'y' to continue: \e\[0m\z/m) # nothing after
    end
  end
end
