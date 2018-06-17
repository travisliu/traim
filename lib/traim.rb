require 'json'
require 'rack'
require 'seg'
require 'yaml'
require 'logger'
require 'active_record'

class Traim 
  DEFAULT_HEADER = {"Content-Type" => 'application/json;charset=UTF-8'}
  TRAIM_ENV = ENV['TRAIM_ENV'] || 'development'

  def initialize(&block)
    if self.class.logger == nil
      self.class.logger = Logger.new(STDOUT)
      self.class.logger.level = Logger::INFO
    end

    @app = Application.new
    @app.compile(&block)
  end

  def self.settings; @settings ||= {} end

  def self.application(&block)
    @instance = new(&block) 
  end

  def self.logger=(logger); @logger = logger end
  def self.logger; @logger end

  def self.call(env)
    @instance.dup.call(env)
  end

  def self.config(&block)
    config_file = YAML.load_file("#{Dir.pwd}/config/database.yml")
    ActiveRecord::Base.establish_connection(config_file[TRAIM_ENV])
    yield self 
  end

  def logger; Traim.logger end

  def call(env)
    request = Rack::Request.new(env)
    logger.info("#{request.request_method} #{request.path_info} from #{request.ip}")
    logger.debug("Parameters: #{request.params}")
    
    @app.route(request)
  rescue Error => e
    logger.error(e) 
    [e.status, e.header, [JSON.dump(e.body)]]
  rescue Exception => e
    logger.error(e) 
    error = Error.new
    [error.status, error.header, [JSON.dump(error.body)]]
  end

  class Application 
    def logger; Traim.logger end 

    def initialize(name = :default)
      @name         = name
      @resources    = {}
      @applications = {}
    end

    def resources(name, &block)
      @resources[name] = Resource.new(block) 
    end

    def namespace(name, &block)
      logger.debug("application namespace #{name}")
      application(name).compile(&block)
    end

    def application(name = :default)
      logger.debug("Lunch application #{name}")
      app = @applications[name] ||= Application.new(name)
    end

    def helpers(&block)
      @helpers_block = block
    end

    def route(request, seg = nil)
      inbox = {}
      seg ||= Seg.new(request.path_info) 
      seg.capture(:segment, inbox)
      segment = inbox[:segment].to_sym

      if app = @applications[segment]
        app.route(request, seg)
      else 
        controller = run(seg, inbox, request)
        render(request, controller)
      end
    end

    def run(seg, inbox, request) 
      controller = nil 
      begin
        segment = inbox[:segment].to_sym

        if controller.nil?
          raise BadRequestError unless @resource = @resources[segment]
          controller = @resource.build_controller(request)
          next
        end 

        if controller.id.nil?
          if collection = @resource.collections[segment]
            controller.instance_eval(&collection)
            break
          else
            controller.id = segment.to_s.to_i
            next 
          end
        end

        if member = @resource.members[segment]
          controller.instance_eval(&member)
          break
        end

        raise BadRequestError 
      end while seg.capture(:segment, inbox) 

      controller.instance_eval(&@helpers_block)  unless @helpers_block.nil?
      controller 
    end
    
    def default_actions
      @default_actions ||= begin 
        actions = {}
        actions["POST"] = lambda do 
          create_record(params)
        end
        actions["GET"] = lambda do 
          find_record(id)
        end
        actions["PUT"] = lambda do 
          result = update_record(id, params)
          result
        end
        actions["DELETE"] = lambda do 
          delete_record(id)
        end
        actions
      end
    end

    def to_json(resources, controller)
      if @result.is_collection?
        hash = @result.map_record do |object, controller|
          @resource.to_hash(controller, resources) 
        end
        JSON.dump(hash)
      else
        new_hash = {}
        if @result.errors.size == 0
          new_hash = @resource.to_hash(controller, resources)
        else
          new_hash = @result.errors.messages
        end
        JSON.dump(new_hash)
      end
    end

    def render(request, controller)
      raise NotImplementedError unless method_block = controller.actions(request.request_method) 
      method_block[:block] = default_actions[request.request_method] if method_block[:block].nil?

      if (method_block[:options][:permit])
        if not_permmited_payload = request.params.detect { |key, value| !method_block[:options][:permit].include?(key) }  
          raise BadRequestError.new(message: "Not permitted payload: #{not_permmited_payload}") 
        end
      end

      controller.params = request.params 
      controller.execute(method_block[:block])
      @result = controller 
      [controller.status, controller.headers, [to_json(@resources, controller)]]
    end

    def compile(&block)
      logger.debug("Compile application: #{@name}")
      instance_eval(&block)
    end
  end

  class Error < StandardError
    def initialize(options = {})
      @message = options[:message] || error_message 
      @body    = options[:body]    || error_message
      super(@message)
    end

    def status; 500 end
    def error_message; 'Internal Server Error' end
    def header; DEFAULT_HEADER end
    def body; {message: @body} end
  end
  class NotImplementedError < Error
    def error_message; "Not Implemented Error" end
    def status; 501 end
  end
  class BadRequestError < Error
    def error_message; "Bad Request Error" end
    def status; 400 end
  end
  class UnauthorizedError < Error
    def error_message; "Unauthorized Error" end
    def status; 401 end
  end
  class ForbiddenError < Error
    def error_message; "Forbidden Error" end
    def status; 403 end
  end
  class NotFoundError < Error
    def error_message; "Not Found Error" end
    def status; 404 end
  end
  class MethodNotAllowedError < Error
    def error_message; "Method Not Allowed" end
    def status; 405 end
  end
  class NotAcceptableError < Error
    def error_message; "Not Acceptable" end
    def status; 406 end
  end

  class Resource 
    ACTION_METHODS = {create: 'POST', show: 'GET', update: 'PUT', destory: 'DELETE'}


    def initialize(block) 
      instance_eval(&block) 
    end

    def model(object = nil, options = {})
      @model = object unless object.nil? 
      @model
    end

    def controller(object = nil)
      @controller = object unless object.nil?
      @controller || ArController
    end

    def actions; @actions ||= {} end
    def action(name, options = {}, &block)
      actions[ACTION_METHODS[name]] = {block: block, options: options}
    end

    def logger; Traim.logger  end 

    def resource(object = nil)
      @resource = object unless object.nil?
      @resource
    end

    def collections; @collections ||= {} end

    def collection(name, &block)
      collections[name] = block
    end
    
    def members; @members ||= {} end
    
    def member(name, &block)
      members[name] = block
    end

    def fields; @fields ||= [] end
    def attribute(name, &block)
      fields << {name: name, type: 'attribute', block: block} 
    end

    def has_many(name, &block)
      fields << {name: name, type: 'association', block: block}
    end

    def has_one(name)
      fields << {name: name, type: 'connection'}
    end

    def build_controller(request)
      controller.new(model, actions.dup, request)
    end

    def to_hash(controller, resources, nested_associations = []) 
      return if controller.nil?

      hash_fields = fields
      hash_fields += controller.fields if controller.respond_to? :fields
      hash_fields.inject({}) do | hash, attr|
        name = attr[:name]

        hash[name] = if attr[:type] == 'attribute'
          if attr[:block].nil?
            controller.attributes[name.to_s]
          else
            attribute_controller = build_controller(controller.request)
            attribute_controller.record = controller.record
            attribute_controller.execute(attr[:block])
          end
        elsif  attr[:type] == 'association'
          raise Error if nested_associations.include?(name)
          nested_associations << name
          resource = resources[name]
          associated_controller = resource.build_controller(controller.request)
          association = if attr[:block].nil?
            associated_controller.record = controller.send(name)
            associated_controller
          else
            associated_controller.execute(attr[:block])
            associated_controller 
          end
          association.map_record do |item, controller|
            resource.to_hash(controller, resources, nested_associations.dup) 
          end
        else
          resource_name = name.to_s.pluralize.to_sym
          raise Error.new(message: "Inifinite Association") if nested_associations.include?(resource_name)
          nested_associations << resource_name 
          resource = resources[resource_name]
          connected_controller = resource.build_controller(controller.request)
          connected_controller.record = controller.send(name) 
          resources[resource_name].to_hash(connected_controller, resources, nested_associations.dup)
        end
        hash
      end
    end
  end

  class Controller 

    def initialize(model, actions, request = nil)
      @model   = model 
      @request = request
      @headers = {}
      @actions = actions
      ok
    end

    attr_accessor :id
    attr_accessor :model
    attr_accessor :params
    attr_accessor :request
    attr_accessor :status

    def logger; Traim.logger  end 

    # status code sytax suger
    def ok;        @status = 200 end
    def created;   @status = 201 end
    def no_cotent; @status = 204 end

    def show(options = {}, &block);    @actions["GET"]    = {block: block, options: options} end
    def create(options = {}, &block);  @actions["POST"]  = {block: block, options: options} end
    def update(options = {}, &block);  @actions["PUT"]  = {block: block, options: options} end
    def destory(options = {}, &block); @actions["DELETE"] = {block: block, options: options} end
    
    def actions(name); @actions[name] end

    def fields; @fields ||= [] end
    def attribute(name, &block)
      fields << {name: name, type: 'attribute', block: block} 
    end
    def has_many(name, &block)
      fields << {name: name, type: 'association', block: block}
    end
    def has_one(name)
      fields << {name: name, type: 'connection'}
    end

    def instance_record(id)
      @id     = id
      @record = find_record(@id)
    end

    def headers(key = nil, value = nil)
      return @headers if key.nil?
      @headers[key] = value 
    end

    def record=(record); @record = record end
    def record; @record ||= find_record(id) end

    def create_record(params)
      resource = @model.new(params)
      resource.save
      resource
    end

    def find_record(id)
      @model.find id
    end

    def delete_record(id)
      find_record(id).delete
    end

    def method_missing(m, *args, &block)
      record.send(m, *args, &block)
    end

    def update_record(id, params)
      resource = find_record(id)
      resource.assign_attributes(params)
      resource.save
      resource 
    end

    def is_collection?; record.is_a?(Enumerable) end

    def map_record
      @record.map do |item|
        new_controller = self.class.new(@model, @actions)
        new_controller.record = item 
        yield item, new_controller 
      end
    end

    def execute(block)
      @record = instance_eval(&block) 
    end
  end

  # A controller design for ActiveRecord
  class ArController < Controller 
  end 

end
