require 'graphql'
require 'dry/graphql/types'
require 'dry/graphql/type_mappings'
require 'dry/core/class_builder'

module Dry
  module GraphQL
    # Module for generated types
    module GeneratedTypes
    end

    # Reduces a DRY type to a GraphQL type
    class SchemaBuilder
      attr_reader :field, :type, :options, :schema, :name, :parent

      class TypeMappingError < StandardError; end
      class NameGenerationError < StandardError; end

      def initialize(name: nil, type: nil, schema: nil, parent: nil, options: {})
        @name = name
        @type = type
        @schema = schema
        @options = options
        @parent = parent
      end

      def with(opts)
        self.class.new({
          name: @name, type: @type, schema: @schema, options: @options,
          parent: self
        }.merge(opts))
      end

      def reduce_with(*args)
        with(*args).reduce
      end

      def graphql_type
        reduce
      end

      def self.build_graphql_schema_class(name)
        Class.new(::GraphQL::Schema::Object)
        Dry::Core::ClassBuilder.new(
          name: name,
          parent: ::GraphQL::Schema::Object,
          namespace: Dry::GraphQL::GeneratedTypes
        ).call
      end

      protected

      def reduce
        case type
        when specified_in_meta?
          type.meta[:graphql_type]
        when scalar?
          TypeMappings.map_scalar type
        when primitive?
          TypeMappings.map_type(type.primitive)
        when hash_schema?
          map_hash type.options[:member_types]
        when raw_hash_type?
          # FIXME: this should be configurable
          ::Dry::GraphQL::Types::JSON
        when Dry::Types::Array::Member
          map_array type
        when ::Hash
          map_hash type
        when schema?
          map_schema type
        when ::Dry::Types::Hash
          schema
        when ::Dry::Types::Constrained, Dry::Types::Constructor
          reduce_with type: type.type
        when ::Dry::Types::Sum::Constrained, ::Dry::Types::Sum
          reduce_with type: type.right
        when ::Dry::Types::Definition
          reduce_with type: type.primitive
        else
          raise_type_mapping_error(type)
        end
      end

      def raise_type_mapping_error(type)
        raise TypeMappingError,
              "Cannot map #{type}. Please make sure " \
              "it is registered by calling:\n" \
              "Dry::GraphQL.register_type_mapping #{type}, MyGraphQLType"
      end

      def primitive?
        lambda do |type|
          begin
            type.respond_to?(:primitive) && TypeMappings.scalar?(type.primitive)
          rescue NoMethodError # when respond_to is incorrect (i.e. Dry::Types::Constructor)
            false
          end
        end
      end

      def scalar?
        TypeMappings.method(:scalar?)
      end

      def schema?
        ->(type) { type.respond_to?(:schema) }
      end

      def hash_schema?
        ->(type) { type.respond_to?(:options) && type.options.key?(:member_types) }
      end

      def specified_in_meta?
        ->(type) { type.respond_to?(:meta) && type.meta.key?(:graphql_type) }
      end

      def raw_hash_type?
        ->(type) { type.is_a?(Dry::Types::Hash) && !type.options.key(:member_types) }
      end

      def map_hash(hash)
        hash.each do |field_name, field_type|
          next if skip?(field_name)

          schema.field(
            field_name,
            with(name: field_name, type: field_type).reduce,
            null: nullable?(field_type)
          )
        end
        schema
      end

      def skip?(field_name)
        return false unless options.key?(:only) || options.key?(:skip)

        if options.key?(:only) && options.key?(:skip)
          return InvalidOptionsError, 'Can only use :skip or :only, not both'
        end

        return options.fetch(:skip, []).include?(field_name.to_sym) if options.key?(:skip)

        return !options.fetch(:only, []).include?(field_name.to_sym) if options.key?(:only)

        false
      end

      def map_array(type)
        member_type = type.options[:member]
        member_graphql_type = with(type: member_type).reduce
        [member_graphql_type]
      end

      def map_schema(type)
        graphql_name = generate_name
        graphql_schema = self.class.build_graphql_schema_class(graphql_name)
        graphql_schema.graphql_name
        type_to_map = if type.respond_to?(:schema) && type.method(:schema).arity.zero?
                        type.schema
                      else
                        type.type
                      end
        opts = { name: graphql_name, type: type_to_map, schema: graphql_schema, options: options }
        SchemaBuilder.new(opts).reduce
      end

      def generate_name
        name_tree = []
        cursor = self
        loop do
          break if cursor.nil?

          sanitized_name = cursor.name.to_s.capitalize.gsub('::', '__')
          name_tree.unshift(sanitized_name)
          cursor = cursor.parent
        end
        name_tree.join('__')
      rescue StandardError => e
        raise NameGenerationError, "Could not generate_name for #{type}: #{e.message}"
      end

      def nullable?(type)
        return false unless type.respond_to?(:left)

        type.left.type.primitive == NilClass
      end
    end
  end
end
