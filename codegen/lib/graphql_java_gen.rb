require 'graphql_java_gen/version'
require 'graphql_java_gen/reformatter'
require 'graphql_java_gen/scalar'
require 'graphql_java_gen/annotation'

require 'erb'
require 'set'

class GraphQLJavaGen
  attr_reader :schema, :package_name, :scalars, :imports, :script_name, :schema_name, :include_deprecated, :annotations, :mutation_returns

  def initialize(schema,
    package_name:, nest_under:, script_name: 'graphql_java_gen gem',
    custom_scalars: [], custom_annotations: [], include_deprecated: false,
    mutation_returns: {}
  )
    @schema = schema
    @schema_name = nest_under
    @script_name = script_name
    @package_name = package_name
    @scalars = (BUILTIN_SCALARS + custom_scalars).reduce({}) { |hash, scalar| hash[scalar.type_name] = scalar; hash }
    @scalars.default_proc = ->(hash, key) { DEFAULT_SCALAR }
    @annotations = custom_annotations
    @imports = (@scalars.values.map(&:imports) + @annotations.map(&:imports)).flatten.sort.uniq
    @include_deprecated = include_deprecated
    @mutation_returns = mutation_returns
  end

  def save(path)
    FileUtils.rm_rf(path)

    write(path, "", "QLBuilder.java", BASE, {schema: schema})
    [[:query, schema.query_root_name], [:mutation, schema.mutation_root_name]].each do |operation_type, root_name|
      next unless root_name
      write(path, "", "#{operation_type.capitalize}Response.java", RESPONSE, {root_name: root_name, operation_type: operation_type})
    end

    schema.types.reject{ |type| type.name.start_with?('__') || type.scalar? }.each do |type|
      mutation_ret = mutation_returns.detect {|k, v| v.include?(type.name)}
      mutation_ret = mutation_ret[0] unless mutation_ret.nil?
      case type.kind
      when 'OBJECT', 'INTERFACE', 'UNION'
        fields = type.fields(include_deprecated: include_deprecated) || []
        name = replace_name(type.name + 'Query')
        where = replace_path(type, mutation_ret)
        write(path, where, "#{name}Definition.java", QUERY_DEF, {type: type, name: name})
        mutations = mutation_returns.detect {|k, v| v.include?(type.name)}
        mutations = mutations[1] unless mutations.nil?
        write(path, where, "#{name}.java", TYPE_QUERY, {type: type, fields: fields, name: name, where: package_name+where, mutations: mutations})
        fields.each do |field|
          next if field.name == "id" && type.object? && type.implement?("Node")
          unless field.optional_args.empty?
            field_where = where + '/' + field.classify_name.underscore.singularize + '_arguments'
            write(path,  field_where, "#{field.classify_name}Arguments.java", FIELD_ARGS, {field: field})
            write(path, field_where, "#{field.classify_name}ArgumentsDefinition.java", ARG_DEF, {field: field})
          end
        end
        unless type.object?
          write(path, where, "#{type.name}.java", OBJECT_INT, {type: type})
        end
        class_name = type.object? ? type.name : "Unknown#{type.name}"
        where = replace_path(type, mutation_ret)
        class_name = replace_name(class_name)
        write(path, where, "#{class_name}.java", TYPE, {type: type, class_name: class_name, fields: fields, where: package_name+where, mutations: mutations})
      when 'INPUT_OBJECT'
        write(path, "/inputs", "#{type.name}.java", INPUT_OBJECT, {type: type})
      when 'ENUM'
        where = replace_path(type, mutation_ret)
        write(path, where, "#{type.name}.java", ENUM_DEF, {type: type})
      else
        raise NotImplementedError, "unhandled #{type.kind} type #{type.name}"
      end
    end
  end

  class << self
    private

    def erb_for(template_filename)
      ERB.new(File.read(template_filename), nil, '-')
    end
  end

  BASE = erb_for(File.expand_path("../graphql_java_gen/templates/base.erb", __FILE__))
  RESPONSE = erb_for(File.expand_path("../graphql_java_gen/templates/response.erb", __FILE__))
  QUERY_DEF = erb_for(File.expand_path("../graphql_java_gen/templates/query_def.erb", __FILE__))
  TYPE_QUERY = erb_for(File.expand_path("../graphql_java_gen/templates/type_query.erb", __FILE__))
  FIELD_ARGS = erb_for(File.expand_path("../graphql_java_gen/templates/field_args.erb", __FILE__))
  ARG_DEF = erb_for(File.expand_path("../graphql_java_gen/templates/arg_def.erb", __FILE__))
  OBJECT_INT = erb_for(File.expand_path("../graphql_java_gen/templates/object_int.erb", __FILE__))
  TYPE = erb_for(File.expand_path("../graphql_java_gen/templates/type.erb", __FILE__))
  INPUT_OBJECT = erb_for(File.expand_path("../graphql_java_gen/templates/input_object.erb", __FILE__))
  ENUM_DEF = erb_for(File.expand_path("../graphql_java_gen/templates/enum_def.erb", __FILE__))

  private_constant :BASE, :RESPONSE, :QUERY_DEF, :TYPE_QUERY, :FIELD_ARGS, :FIELD_ARGS, :ARG_DEF, :OBJECT_INT, :TYPE, :INPUT_OBJECT, :ENUM_DEF

  class HashBinding < GraphQLJavaGen

    attr_reader :schema, :scalars, :imports, :script_name, :schema_name, :include_deprecated, :mutation_returns

    def initialize(data, hash)
      @schema = data.schema
      @schema_name = data.schema_name
      @script_name = data.script_name
      @scalars = data.scalars
      @imports = data.imports
      @annotations = data.annotations
      @include_deprecated = data.include_deprecated
      @mutation_returns = data.mutation_returns
      hash.each do |key, value|
        singleton_class.send(:define_method, key) { value }
      end
    end

    def context
      binding
    end
  end

  require 'fileutils'

  def replace_name(string)
    string = string.gsub('Payload', '')

    string
  end

  def replace_path(type, mut)
    string = "/types/#{type.name.underscore}"
    string = "/mutations/#{mut.to_s.underscore}/#{type.name.underscore}" unless mut.nil?
    string = type.name.include?('Payload') ? "/mutations/#{type.name.underscore}" : string
    string = type.name.include?('Mutation') ? "/mutations" : string
    string = string.gsub('_query', '')
    string = string.gsub('_payload', '')

    string
  end

  def write(root, path, name, template, args)
    dirname = File.dirname(root+path+'/'+name)
    unless File.directory?(dirname)
      FileUtils.mkdir_p(dirname)
    end
    args[:package_name] = package_name + path.gsub('/', '.')
    args[:root_package] = package_name
    hash_binding = HashBinding.new(self, args)
    File.write(root+path+'/'+name, reformat(template.result(hash_binding.context)))
  end

  DEFAULT_SCALAR = Scalar.new(
    type_name: nil,
    java_type: 'String',
    deserialize_expr: ->(expr) { "jsonAsString(#{expr}, key)" },
  )
  private_constant :DEFAULT_SCALAR

  BUILTIN_SCALARS = [
    Scalar.new(
      type_name: 'Int',
      java_type: 'int',
      deserialize_expr: ->(expr) { "jsonAsInteger(#{expr}, key)" },
    ),
    Scalar.new(
      type_name: 'Float',
      java_type: 'double',
      deserialize_expr: ->(expr) { "jsonAsDouble(#{expr}, key)" },
    ),
    Scalar.new(
      type_name: 'String',
      java_type: 'String',
      deserialize_expr: ->(expr) { "jsonAsString(#{expr}, key)" },
    ),
    Scalar.new(
      type_name: 'Boolean',
      java_type: 'boolean',
      deserialize_expr: ->(expr) { "jsonAsBoolean(#{expr}, key)" },
    ),
    Scalar.new(
      type_name: 'ID',
      java_type: 'ID',
      deserialize_expr: ->(expr) { "new ID(jsonAsString(#{expr}, key))" },
      imports: ['com.shopify.graphql.support.ID'],
    ),
  ]
  private_constant :BUILTIN_SCALARS

  # From: http://docs.oracle.com/javase/tutorial/java/nutsandbolts/_keywords.html
  RESERVED_WORDS = [
    "abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float",
    "for", "goto", "if", "implements", "import", "instanceof", "int", "interface", "long", "native", "new", "package", "private", "protected", "public", "return", "short", "static", "strictfp", "super",
    "switch", "synchronized", "this", "throw", "throws", "transient", "try", "void", "volatile", "while"
  ]
  private_constant :RESERVED_WORDS

  def escape_reserved_word(word)
    return word unless RESERVED_WORDS.include?(word)
    "#{word}Value"
  end

  def class_head
    res = "
    package #{package_name};

    import com.google.gson.Gson;
    import com.google.gson.GsonBuilder;
    import com.google.gson.JsonElement;
    import com.google.gson.JsonObject;
    import com.shopify.graphql.support.AbstractResponse;
    import com.shopify.graphql.support.Arguments;
    import com.shopify.graphql.support.Error;
    import com.shopify.graphql.support.Query;
    import com.shopify.graphql.support.SchemaViolationError;
    import com.shopify.graphql.support.TopLevelResponse;

    import java.io.Serializable;
    import java.util.ArrayList;
    import java.util.List;
    import java.util.Map;

    import #{root_package}.inputs.*;
    "

    schema.types.reject{ |type| type.name.start_with?('__') || type.scalar? }.each do |type|
      name = type.name
      unless type.kind == 'INPUT_OBJECT'
        pack_name = name.underscore.gsub('_query', '').gsub('_payload', '')
        where = name.include?('Mutation') ? 'mutations' : "types.#{pack_name}"
        where = "mutations.#{pack_name}" if name.include?('Payload')
        mutations = mutation_returns.detect {|k, v| v.include?(type.name)}
        mutations = mutations[0] unless mutations.nil?
        where = "mutations.#{mutations.to_s.underscore}.#{pack_name}" unless mutations.nil?
        res += "\nimport #{root_package}.#{where}.*;" unless name.include?('Payload')
      end
    end

    imports.each do |import|
      res += "\nimport #{import};"
    end
    res
  end

  def reformat(code)
    Reformatter.new(indent: " " * 4).reformat(code)
  end

  def java_input_type(type, non_null: false)
    case type.kind
    when "NON_NULL"
      java_input_type(type.of_type, non_null: true)
    when "SCALAR"
      non_null ? scalars[type.name].non_nullable_type : scalars[type.name].nullable_type
    when 'LIST'
      "List<#{java_input_type(type.of_type.unwrap_non_null)}>"
    when 'INPUT_OBJECT', 'ENUM'
      replace_name(type.name)
    else
      raise NotImplementedError, "Unhandled #{type.kind} input type"
    end
  end

  def java_output_type(type)
    type = type.unwrap_non_null
    case type.kind
    when "SCALAR"
      scalars[type.name].nullable_type
    when 'LIST'
      "List<#{java_output_type(type.of_type)}>"
    when 'ENUM', 'OBJECT', 'INTERFACE', 'UNION'
      replace_name(type.name)
    else
      raise NotImplementedError, "Unhandled #{type.kind} response type"
    end
  end

  def generate_build_input_code(expr, type, depth: 1, name: 'builder()')
    type = type.unwrap_non_null
    case type.kind
    when 'SCALAR'
      if ['Int', 'Float', 'Boolean'].include?(type.name)
        "#{name}.append(#{expr});"
      else
        "Query.appendQuotedString(#{name}, #{expr}.toString());"
      end
    when 'ENUM'
      "#{name}.append(#{expr}.toString());"
    when 'LIST'
      item_type = type.of_type
      <<-JAVA
        #{name}.append('[');

        String listSeperator#{depth} = "";
        for (#{java_input_type(item_type)} item#{depth} : #{expr}) {
          #{name}.append(listSeperator#{depth});
          listSeperator#{depth} = ",";
          #{generate_build_input_code("item#{depth}", item_type, depth: depth + 1, name: name)}
        }
        #{name}.append(']');
      JAVA
    when 'INPUT_OBJECT'
      "#{expr}.appendTo(#{name});"
    else
      raise NotImplementedError, "Unexpected #{type.kind} argument type"
    end
  end

  def generate_build_output_code(expr, type, depth: 1, non_null: false, &block)
    if type.non_null?
      return generate_build_output_code(expr, type.of_type, depth: depth, non_null: true, &block)
    end

    statements = ""
    unless non_null
      optional_name = "optional#{depth}"
      generate_build_output_code(expr, type, depth: depth, non_null: true) do |item_statements, item_expr|
        statements = <<-JAVA
          #{java_output_type(type)} #{optional_name} = null;
          if (!#{expr}.isJsonNull()) {
            #{item_statements}
            #{optional_name} = #{item_expr};
          }
        JAVA
      end
      return yield statements, optional_name
    end

    expr = case type.kind
    when 'SCALAR'
      scalars[type.name].deserialize(expr)
    when 'LIST'
      list_name = "list#{depth}"
      element_name = "element#{depth}"
      generate_build_output_code(element_name, type.of_type, depth: depth + 1) do |item_statements, item_expr|
        statements = <<-JAVA
          #{java_output_type(type)} #{list_name} = new ArrayList<>();
          for (JsonElement #{element_name} : jsonAsArray(#{expr}, key)) {
            #{item_statements}
            #{list_name}.add(#{item_expr});
          }
        JAVA
      end
      list_name
    when 'OBJECT'
      "new #{replace_name(type.name)}(jsonAsObject(#{expr}, key))"
    when 'INTERFACE', 'UNION'
      "Unknown#{type.name}.create(jsonAsObject(#{expr}, key))"
    when 'ENUM'
       "#{type.name}.fromGraphQl(jsonAsString(#{expr}, key))"
    else
      raise NotImplementedError, "Unexpected #{type.kind} argument type"
    end
    yield statements, expr
  end

  def java_arg_defs(field, skip_optional: false)
    defs = []
    field.required_args.each do |arg|
      defs << "#{java_input_type(arg.type)} #{escape_reserved_word(arg.camelize_name)}"
    end
    unless field.optional_args.empty? || skip_optional
      defs << "#{field.classify_name}ArgumentsDefinition argsDef"
    end
    if field.subfields?
      defs << "#{replace_name(field.type.unwrap.name)}QueryDefinition queryDef"
    end
    defs.join(', ')
  end

  def java_required_arg_defs(field)
    defs = []
    field.required_args.each do |arg|
      defs << "#{java_input_type(arg.type)} #{escape_reserved_word(arg.camelize_name)}"
    end
    unless field.optional_args.empty?
      defs << "#{field.classify_name}ArgumentsDefinition argsDef"
    end
    if field.subfields?
      defs << "#{field.type.unwrap.classify_name}QueryDefinition queryDef"
    end
    defs.join(', ')
  end

  def java_arg_expresions_with_empty_optional_args(field)
    expressions = field.required_args.map { |arg| escape_reserved_word(arg.camelize_name) }
    expressions << "args -> {}"
    if field.subfields?
      expressions << "queryDef"
    end
    expressions.join(', ')
  end

  def java_implements(type)
    return "implements #{type.name} " unless type.object?
    interfaces = abstract_types.fetch(type.name)
    return "" if interfaces.empty?
    "implements #{interfaces.to_a.join(', ')} "
  end

  def java_annotations(field, in_argument: false)
    annotations = @annotations.map do |annotation|
      "@#{annotation.name}" if annotation.annotate?(field)
    end.compact
    return "" unless annotations.any?

    if in_argument
      annotations.join(" ") + " "
    else
      annotations.join("\n")
    end
  end

  def type_names_set
    @type_names_set ||= schema.types.map(&:name).to_set
  end

  def abstract_types
    @abstract_types ||= schema.types.each_with_object({}) do |type, result|
      case type.kind
      when 'OBJECT'
        result[type.name] ||= Set.new
      when 'INTERFACE', 'UNION'
        type.possible_types.each do |possible_type|
          (result[possible_type.name] ||= Set.new).add(type.name)
        end
      end
    end
  end

  def java_doc(element)
    doc = ''
    unless element.description.nil?
      description = wrap_text(element.description, 100)
      description = description.chomp("\n").gsub("\n", "\n* ")
      doc << '* '
      doc << description
    end

    if element.respond_to?(:deprecated?) && element.deprecated?
      unless doc.empty?
        doc << "\n*"
        doc << "\n*"
      else
        doc << '*'
      end
      doc << ' @deprecated '
      doc << element.deprecation_reason
    end

    doc.empty? ? doc : "/**\n" + doc + "\n*/"
  end

  def wrap_text(text, col_width=80)
    text.gsub!( /(\S{#{col_width}})(?=\S)/, '\1 ' )
    text.gsub!( /(.{1,#{col_width}})(?:\s+|$)/, "\\1\n" )
    text
  end
end
