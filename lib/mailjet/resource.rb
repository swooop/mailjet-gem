require 'mailjet/connection'
require 'mailjet/resource'
require 'active_support/hash_with_indifferent_access'
require 'active_support/core_ext/class'
require 'active_support/core_ext/string'
require 'active_support/core_ext/module/delegation'
require 'active_support/concern'
require 'active_support/json/decoding'


# This option automatically transforms the date output by the API into something a bit more readable.
# Setting this option to 'true' -- or having it at all -- may effect a users app by globally implementing this
# date transformation feature which may not be desired by the developer for whatever reason.
#
# ActiveSupport.parse_json_times = false

module Mailjet
  module Resource
    extend ActiveSupport::Concern

    included do
      cattr_accessor :resource_path, :public_operations, :read_only, :filters, :properties, :action
      cattr_writer :connection

      def self.connection
        class_variable_get(:@@connection) || default_connection
      end

      def self.default_connection
        Mailjet::Connection.new(
          "#{Mailjet.config.end_point}/#{resource_path}",
          Mailjet.config.api_key,
          Mailjet.config.secret_key,
          public_operations: public_operations,
          read_only: read_only)
      end

      def self.default_headers
        { accept: :json, accept_encoding: :deflate, content_type: :json}
      end
    end

    module ClassMethods
      def first(params = {})
        all(params.merge!(limit: 1)).first
      end

      def all(params = {})
        params = format_params(params)
        attribute_array = parse_api_json(connection.get(default_headers.merge(params: params)))
        attribute_array.map{ |attributes| instanciate_from_api(attributes) }
      end

      def count
        response_json = connection.get(default_headers.merge(params: {limit: 1, countrecords: 1}))
        response_hash = ActiveSupport::JSON.decode(response_json)
        response_hash['Total']
      end

      def find(id)
         # if action method, ammend url to appropriate id
         self.resource_path = create_action_resource_path(id) if self.action
         #
        attributes = parse_api_json(connection[id].get(default_headers)).first
        instanciate_from_api(attributes)
      rescue Mailjet::ApiError => e
        if e.code == 404
          nil
        else
          raise e
        end
      end

      def create(attributes = {})
         # if action method, ammend url to appropriate id
         self.resource_path = create_action_resource_path(attributes[:id]) if self.action
         #
        self.new(attributes).tap do |resource|
          resource.save!
          resource.persisted = true
        end
      end

      def delete(id)
         # if action method, ammend url to appropriate id
         self.resource_path = create_action_resource_path(id) if self.action
         #
        connection[id].delete(default_headers)
      end

      def instanciate_from_api(attributes = {})
        self.new(attributes.merge(persisted: true))
      end

      def parse_api_json(response_json)
        response_hash = ActiveSupport::JSON.decode(response_json)
        #Take the response from the API and put it through a method -- taken from the ActiveSupport library -- which converts
        #the date-time from "2014-05-19T15:31:09Z" to "Mon, 19 May 2014 15:31:09 +0000" format.
        response_hash = convert_dates_from(response_hash)
        #
        #
        response_data_array = response_hash['Data']
        response_data_array.map{ |response_data| underscore_keys(response_data) }
      end

      def create_action_resource_path(id)
         url_elements = self.resource_path.split("/")
         url_elements[3] = id.to_s
         return url_elements.join("/")
      end


      # Method -- taken from the ActiveSupport library -- which converts the date-time from
      #"2014-05-19T15:31:09Z" to "Mon, 19 May 2014 15:31:09 +0000" format.
      #We may have to change this in the future if ActiveSupport's JSON implementation changes
      def convert_dates_from(data)
        case data
        when nil
          nil
       when /^(?:\d{4}-\d{2}-\d{2}|\d{4}-\d{1,2}-\d{1,2}[T \t]+\d{1,2}:\d{2}:\d{2}(\.[0-9]*)?(([ \t]*)Z|[-+]\d{2}?(:\d{2})?))$/
          begin
            DateTime.parse(data)
          rescue ArgumentError
            data
          end
        when Array
          data.map! { |d| convert_dates_from(d) }
        when Hash
          data.each do |key, value|
            data[key] = convert_dates_from(value)
          end
        else
          data
        end
      end


      def format_params(params)
        if params[:sort]
          params[:sort] = params[:sort].map do |attribute, direction|
            attribute = attribute.to_s.camelcase
            direction = direction.to_s.upcase
            "#{attribute} #{direction}"
          end.join(', ')
        end
        params
      end

      def camelcase_keys(hash)
        map_keys(hash, :camelcase)
      end

      def underscore_keys(hash)
        map_keys(hash, :underscore)
      end

      def map_keys(hash, method)
        hash.inject({}) do |_hash, (key, value)|
          new_key = key.to_s.send(method)
          _hash[new_key] = value
          _hash
        end
      end
    end

    attr_accessor :attributes, :persisted

    def initialize(_attributes = nil)
      @attributes = ActiveSupport::HashWithIndifferentAccess.new(_attributes.reverse_merge(persisted: false))
    end

    def persisted?
      attributes[:persisted]
    end

    def save
      if persisted?
        response = connection[id].put(formatted_payload, default_headers)
      else
        response = connection.post(formatted_payload, default_headers)
      end

      self.attributes = parse_api_json(response).first
      return true
    rescue Mailjet::ApiError => e
      if e.code.to_s == "304"
        return true # When you save a record twice it should not raise error
      else
        raise e
      end
    end

    def save!
      save || raise(StandardError.new("Resource not persisted"))
    end

    def attributes=(attribute_hash = {})
      attribute_hash.each do |attribute_name, value|
        self.send("#{attribute_name}=", value)
      end
    end

    def update_attributes(attribute_hash = {})
      self.attributes = attribute_hash
      save
    end

    def delete
      self.class.delete(id)
    end

    private

    def connection
      self.class.connection
    end

    def default_headers
      self.class.default_headers
    end

    def formatted_payload
      payload = attributes.reject { |k,v| v.blank? }
      payload = payload.slice(*properties)
      payload = camelcase_keys(payload)
      payload.inject({}) do |h, (k, v)|
        v = v.utc.as_json if v.respond_to? :utc
        h.merge!({k => v})
      end
    end

    def camelcase_keys(hash)
      self.class.camelcase_keys(hash)
    end

    def underscore_keys(hash)
      self.class.underscore_keys(hash)
    end

    def parse_api_json(response_json)
      self.class.parse_api_json(response_json)
    end

    #my code!
    def convert_dates_from(data)
      self.class.convert_dates_from(data)
    end
    #end my code

    def method_missing(method_symbol, *arguments) #:nodoc:
      method_name = method_symbol.to_s

      if method_name =~ /(=|\?)$/
        case $1
        when "="
          attributes[$`] = arguments.first
        when "?"
          attributes[$`]
        end
      else
        return attributes[method_name] if attributes.include?(method_name)
        # not set right now but we know about it
        # return nil if known_attributes.include?(method_name)
        super
      end
    end
  end
end
