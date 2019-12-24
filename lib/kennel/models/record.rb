# frozen_string_literal: true
module Kennel
  module Models
    class Record < Base
      LOCK = "\u{1F512}"
      READONLY_ATTRIBUTES = [
        :deleted, :id, :created, :created_at, :creator, :org_id, :modified, :modified_at, :api_resource
      ].freeze
      API_LIST_INCOMPLETE = false

      settings :id, :kennel_id

      class << self
        private

        def normalize(_expected, actual)
          self::READONLY_ATTRIBUTES.each { |k| actual.delete k }
        end

        def ignore_default(expected, actual, defaults)
          definitions = [actual, expected]
          defaults.each do |key, default|
            if definitions.all? { |r| !r.key?(key) || r[key] == default }
              actual.delete(key)
              expected.delete(key)
            end
          end
        end
      end

      attr_reader :project

      def initialize(project, *args)
        raise ArgumentError, "First argument must be a project, not #{project.class}" unless project.is_a?(Project)
        @project = project
        super(*args)
      end

      def diff(actual)
        expected = as_json
        expected.delete(:id)

        self.class.send(:normalize, expected, actual)

        HashDiff.diff(actual, expected, use_lcs: false)
      end

      def tracking_id
        "#{project.kennel_id}:#{kennel_id}"
      end

      def resolve_linked_tracking_ids(*)
      end

      private

      def resolve_link(id, id_map, force: false)
        found = id_map[id]
        return found if found && found != :new

        if found == :new
          if force
            invalid! "Monitor #{id} will be created in the current run and can only be used after that"
          else
            Kennel.err.puts "Monitor #{id} will be created in the current run, the next run will link it properly"
            Kennel::MISSING_ID
          end
        else
          invalid! "Unable to find monitor #{id} (does not exist and is not being created by the current run)"
        end
      end

      # let users know which project/resource failed when something happens during diffing where the backtrace is hidden
      def invalid!(message)
        raise ValidationError, "#{tracking_id} #{message}"
      end

      def raise_with_location(error, message)
        super error, "#{message} for project #{project.kennel_id}"
      end
    end
  end
end