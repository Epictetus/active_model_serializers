require "active_support/core_ext/class/attribute"
require "active_support/core_ext/module/anonymous"

module ActiveModel
  # Active Model Array Serializer
  #
  # It serializes an array checking if each element that implements
  # the +active_model_serializer+ method passing down the current scope.
  class ArraySerializer
    attr_reader :object, :scope

    def initialize(object, scope, options={})
      @object, @scope, @options = object, scope, options
      @hash = options[:hash]
    end

    def serializable_array
      @object.map do |item|
        if item.respond_to?(:active_model_serializer) && (serializer = item.active_model_serializer)
          serializer.new(item, scope, :hash => @hash)
        else
          item
        end
      end
    end

    def as_json(*args)
      @hash = {}

      array = serializable_array.map(&:serializable_hash)

      if root = @options[:root]
        @hash.merge!(root => array)
      else
        array
      end
    end
  end

  # Active Model Serializer
  #
  # Provides a basic serializer implementation that allows you to easily
  # control how a given object is going to be serialized. On initialization,
  # it expects to object as arguments, a resource and a scope. For example,
  # one may do in a controller:
  #
  #     PostSerializer.new(@post, current_user).to_json
  #
  # The object to be serialized is the +@post+ and the scope is +current_user+.
  #
  # We use the scope to check if a given attribute should be serialized or not.
  # For example, some attributes maybe only be returned if +current_user+ is the
  # author of the post:
  #
  #     class PostSerializer < ActiveModel::Serializer
  #       attributes :title, :body
  #       has_many :comments
  #
  #       private
  #
  #       def attributes
  #         hash = super
  #         hash.merge!(:email => post.email) if author?
  #         hash
  #       end
  #
  #       def author?
  #         post.author == scope
  #       end
  #     end
  #
  class Serializer
    module Associations #:nodoc:
      class Config < Struct.new(:name, :options) #:nodoc:
        def serializer
          options[:serializer]
        end

        def key
          options[:key] || name
        end

        protected

        def find_serializable(object, scope, context, options)
          if serializer
            serializer.new(object, scope, options)
          elsif object.respond_to?(:active_model_serializer) && (ams = object.active_model_serializer)
            ams.new(object, scope, options)
          else
            object
          end
        end
      end

      class HasMany < Config #:nodoc:
        def serialize(collection, scope, context, options)
          array = collection.map do |item|
            find_serializable(item, scope, context, options).as_json(:root => false)
          end
          { key => array }
        end

        def serialize_ids(collection, scope)
          # Use pluck or select_columns if available
          # return collection.ids if collection.respond_to?(:ids)

          array = collection.map do |item|
            item.read_attribute_for_serialization(:id)
          end

          { key => array }
        end
      end

      class HasOne < Config #:nodoc:
        def serialize(object, scope, context, options)
          { key => object && find_serializable(object, scope, context, options).as_json(:root => false) }
        end

        def serialize_ids(object, scope)
          { key => object && object.read_attribute_for_serialization(:id) }
        end
      end
    end

    class_attribute :_attributes
    self._attributes = {}

    class_attribute :_associations
    self._associations = []

    class_attribute :_root
    class_attribute :_embed
    self._embed = :objects
    class_attribute :_root_embed

    class << self
      # Define attributes to be used in the serialization.
      def attributes(*attrs)
        self._attributes = _attributes.dup

        attrs.each do |attr|
          self._attributes[attr] = attr
        end
      end

      def attribute(attr, options={})
        self._attributes = _attributes.merge(attr => options[:key] || attr)
      end

      def associate(klass, attrs) #:nodoc:
        options = attrs.extract_options!
        self._associations += attrs.map do |attr|
          unless method_defined?(attr)
            class_eval "def #{attr}() object.#{attr} end", __FILE__, __LINE__
          end
          klass.new(attr, options)
        end
      end

      # Defines an association in the object should be rendered.
      #
      # The serializer object should implement the association name
      # as a method which should return an array when invoked. If a method
      # with the association name does not exist, the association name is
      # dispatched to the serialized object.
      def has_many(*attrs)
        associate(Associations::HasMany, attrs)
      end

      # Defines an association in the object should be rendered.
      #
      # The serializer object should implement the association name
      # as a method which should return an object when invoked. If a method
      # with the association name does not exist, the association name is
      # dispatched to the serialized object.
      def has_one(*attrs)
        associate(Associations::HasOne, attrs)
      end

      # Return a schema hash for the current serializer. This information
      # can be used to generate clients for the serialized output.
      #
      # The schema hash has two keys: +attributes+ and +associations+.
      #
      # The +attributes+ hash looks like this:
      #
      #     { :name => :string, :age => :integer }
      #
      # The +associations+ hash looks like this:
      #
      #     { :posts => { :has_many => :posts } }
      #
      # If :key is used:
      #
      #     class PostsSerializer < ActiveModel::Serializer
      #       has_many :posts, :key => :my_posts
      #     end
      #
      # the hash looks like this:
      #
      #     { :my_posts => { :has_many => :posts }
      #
      # This information is extracted from the serializer's model class,
      # which is provided by +SerializerClass.model_class+.
      #
      # The schema method uses the +columns_hash+ and +reflect_on_association+
      # methods, provided by default by ActiveRecord. You can implement these
      # methods on your custom models if you want the serializer's schema method
      # to work.
      #
      # TODO: This is currently coupled to Active Record. We need to
      # figure out a way to decouple those two.
      def schema
        klass = model_class
        columns = klass.columns_hash

        attrs = _attributes.inject({}) do |hash, (name,key)|
          column = columns[name.to_s]
          hash.merge key => column.type
        end

        associations = _associations.inject({}) do |hash, association|
          model_association = klass.reflect_on_association(association.name)
          hash.merge association.key => { model_association.macro => model_association.name }
        end

        { :attributes => attrs, :associations => associations }
      end

      # The model class associated with this serializer.
      def model_class
        name.sub(/Serializer$/, '').constantize
      end

      # Define how associations should be embedded.
      #
      #   embed :objects               # Embed associations as full objects
      #   embed :ids                   # Embed only the association ids
      #   embed :ids, :include => true # Embed the association ids and include objects in the root
      #
      def embed(type, options={})
        self._embed = type
        self._root_embed = true if options[:include]
      end

      # Defines the root used on serialization. If false, disables the root.
      def root(name)
        self._root = name
      end

      def inherited(klass) #:nodoc:
        return if klass.anonymous?
        name = klass.name.demodulize.underscore.sub(/_serializer$/, '')

        klass.class_eval do
          alias_method name.to_sym, :object
          root name.to_sym unless self._root == false
        end
      end
    end

    attr_reader :object, :scope

    def initialize(object, scope, options={})
      @object, @scope, @options = object, scope, options
      @hash = options[:hash]
    end

    # Returns a json representation of the serializable
    # object including the root.
    def as_json(options=nil)
      options ||= {}
      if root = options.fetch(:root, @options.fetch(:root, _root))
        @hash = hash = {}
        hash.merge!(root => serializable_hash)
        hash
      else
        @hash = serializable_hash
      end
    end

    # Returns a hash representation of the serializable
    # object without the root.
    def serializable_hash
      if _embed == :ids
        merge_associations(@hash, associations) if _root_embed
        attributes.merge(association_ids)
      elsif _embed == :objects
        attributes.merge(associations)
      else
        attributes
      end
    end

    # Merge associations for embed case by always adding
    # root associations to the given hash.
    def merge_associations(hash, associations)
      associations.each do |key, value|
        if hash[key]
          hash[key] |= value
        elsif value
          hash[key] = value
        end
      end
    end

    # Returns a hash representation of the serializable
    # object associations.
    def associations
      hash = {}

      _associations.each do |association|
        associated_object = send(association.name)
        hash.merge! association.serialize(associated_object, scope, self, :hash => @hash)
      end

      hash
    end

    # Returns a hash representation of the serializable
    # object associations ids.
    def association_ids
      hash = {}

      _associations.each do |association|
        associated_object = send(association.name)
        hash.merge! association.serialize_ids(associated_object, scope)
      end

      hash
    end

    # Returns a hash representation of the serializable
    # object attributes.
    def attributes
      hash = {}

      _attributes.each do |name,key|
        hash[key] = @object.read_attribute_for_serialization(name)
      end

      hash
    end
  end
end

class Array
  # Array uses ActiveModel::ArraySerializer.
  def active_model_serializer
    ActiveModel::ArraySerializer
  end
end
