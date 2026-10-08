# frozen_string_literal: true

require "digest"
require "prism"

module Tools
  module Mutation
    Mutant = Struct.new(:id, :file, :line, :kind, :start, :stop, :original, :replacement, keyword_init: true) do
      def apply(source)
        bytes = source.b
        (bytes.byteslice(0, start) + replacement.b + bytes.byteslice(stop..)).force_encoding(Encoding::UTF_8)
      end
    end

    class Generator < Prism::Visitor
      OPERATOR_SWAPS = {
        :== => "!=", :!= => "==", :< => "<=", :<= => "<", :> => ">=", :>= => ">",
        :+ => "-", :- => "+", :* => "/", :/ => "*"
      }.freeze
      METHOD_SWAPS = {max: "min", min: "max", first: "last", last: "first", any?: "none?", all?: "any?"}.freeze
      DECLARATIONS = %i[
        require require_relative private public extend include attr_reader attr_writer
        attr_accessor private_constant private_class_method
      ].freeze
      DROPPABLE_CHAIN_CALLS = %i[where order joins due compact strip uniq sort].freeze
      DELETABLE_STATEMENTS = [
        Prism::CallNode, Prism::InstanceVariableWriteNode, Prism::InstanceVariableOperatorWriteNode,
        Prism::InstanceVariableOrWriteNode, Prism::LocalVariableOperatorWriteNode,
        Prism::IndexOperatorWriteNode, Prism::IndexOrWriteNode, Prism::CallOperatorWriteNode,
        Prism::CallOrWriteNode, Prism::YieldNode, Prism::NextNode, Prism::BreakNode
      ].freeze
      SQL_LINE_SWAPS = [
        [/^(\s*)AND .*$/, '\1', "sql_drop_and"],
        [/\bASC\b/, "DESC", "sql_order"],
        [/ IS NULL\b/, " IS NOT NULL", "sql_null"],
        [/ IS NOT NULL\b/, " IS NULL", "sql_not_null"],
        [/<= /, "> ", "sql_compare"]
      ].freeze

      def self.call(root, relative)
        source = File.read(File.join(root, relative))
        generator = new(relative, source)
        generator.visit(Prism.parse(source).value)
        generator.sql_mutants
        generator.mutants.uniq(&:id).select { |mutant| Prism.parse(mutant.apply(source)).success? }
      end

      attr_reader :mutants

      def initialize(file, source)
        super()
        @file = file
        @source = source
        @mutants = []
      end

      def visit_if_node(node)
        predicate(node)
        super
      end

      def visit_unless_node(node)
        predicate(node)
        super
      end

      def visit_while_node(node)
        add(node.predicate.location, "false", "loop_never", node)
        super
      end

      def visit_until_node(node)
        add(node.predicate.location, "true", "loop_never", node)
        super
      end

      def visit_and_node(node)
        logical(node, "||")
        super
      end

      def visit_or_node(node)
        logical(node, "&&")
        super
      end

      def visit_call_node(node)
        return if DECLARATIONS.include?(node.name) && node.receiver.nil?

        if OPERATOR_SWAPS.key?(node.name) && node.receiver && node.arguments&.arguments&.size == 1 && node.message_loc
          add(node.message_loc, OPERATOR_SWAPS.fetch(node.name), "operator", node)
        elsif node.name == :! && node.receiver && node.message_loc&.slice == "!"
          add(node.location, node.receiver.location.slice, "remove_not", node)
        elsif METHOD_SWAPS.key?(node.name) && node.message_loc
          add(node.message_loc, METHOD_SWAPS.fetch(node.name), "method_swap", node)
        end

        if node.name.end_with?("?") && node.message_loc
          add(node.location, "!(#{node.location.slice})", "negate_predicate", node)
        end

        if DROPPABLE_CHAIN_CALLS.include?(node.name) && node.receiver && node.block.nil?
          add(node.location, node.receiver.location.slice, "drop_call", node)
        end

        super
      end

      def visit_integer_node(node)
        add(node.location, (node.value + 1).to_s, "integer", node)
      end

      def visit_float_node(node)
        add(node.location, (node.value + 1.0).to_s, "float", node)
      end

      def visit_true_node(node)
        add(node.location, "false", "boolean", node)
      end

      def visit_false_node(node)
        add(node.location, "true", "boolean", node)
      end

      def visit_string_node(node)
        opening = node.opening_loc&.slice
        return if opening.nil? || opening.start_with?("<<")

        content = node.unescaped
        return if content.empty? || content.bytesize > 40 || content.start_with?("[HireFire]")

        add(node.location, '"__mutated__"', "string", node)
      end

      def visit_return_node(node)
        add(node.arguments.location, "nil", "return_nil", node) if node.arguments
        super
      end

      def visit_statements_node(node)
        node.body.each do |statement|
          next unless DELETABLE_STATEMENTS.any? { |type| statement.is_a?(type) }
          next if statement.is_a?(Prism::CallNode) && DECLARATIONS.include?(statement.name) && statement.receiver.nil?

          add(statement.location, "nil", "delete_statement", statement)
        end
        super
      end

      def sql_mutants
        offset = 0
        inside = false
        @source.each_line.with_index(1) do |line, number|
          if inside
            if line.match?(/^\s*SQL\b/)
              inside = false
            else
              SQL_LINE_SWAPS.each do |pattern, replacement, kind|
                next unless line.match?(pattern)

                body = line.chomp
                record(offset, offset + body.bytesize, body, body.sub(pattern, replacement), kind, number)
              end
            end
          elsif line.include?("<<~SQL")
            inside = true
          end
          offset += line.bytesize
        end
      end

      private

      def predicate(node)
        add(node.predicate.location, "true", "condition_true", node)
        add(node.predicate.location, "false", "condition_false", node)
      end

      def logical(node, other)
        add(node.operator_loc, other, "logical_swap", node)
        add(node.location, node.left.location.slice, "logical_left", node)
        add(node.location, node.right.location.slice, "logical_right", node)
      end

      def add(location, replacement, kind, node)
        record(location.start_offset, location.end_offset, location.slice, replacement, kind, node.location.start_line)
      end

      def record(start, stop, original, replacement, kind, line)
        return if original == replacement

        id = Digest::SHA1.hexdigest([@file, start, stop, kind, replacement].join("\0"))[0, 12]
        @mutants << Mutant.new(id: id, file: @file, line: line, kind: kind, start: start, stop: stop, original: original, replacement: replacement)
      end
    end
  end
end
