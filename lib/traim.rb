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
    instance_eval(&block)
  end

  def self.settings; @settings ||= {} end

  def self.application(&block)
    @app = new(&block) 
  end

  def self.logger=(logger); @logger = logger end
  def self.logger; @logger end

  def self.call(env)
    @app.call(env)
  end

  def self.config(&block)
    config = YAML.load_file('config/database.yml')[TRAIM_ENV]
    ActiveRecord::Base.establish_connection(config)
    yield self 
  end

  def resources(name, &block)
    Router.resources[name] = Resource.new(block) 
  end

  def logger; Traim.logger end

  def call(env); dup.call!(env) end

  def call!(env)
    request = Rack::Request.new(env)
    logger.info("#{request.request_method} #{request.path_info} from #{request.ip}")
    logger.debug("Parameters: #{request.params}")

    router = Router.new
    router.run(Seg.new(request.path_info))
    router.render(request)
  rescue Error => e
    logger.error(e) 
    [e.status, e.header, [JSON.dump(e.body)]]
  rescue Exception => e
    logger.error(e) 
    error = Error.new
    [error.status, error.header, [JSON.dump(error.body)]]
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
    def body; {body: @body} end
  end
  class NotImplementedError < Error
    def error_message; "Not Implemented Error" end
    def status; 501 end
  end
  class BadRequestError < Error
    def error_message; "Bad Request Error" end
    def status; 400 end
  end
  class NotFoundError < Error
    def error_message; "Not Found Error" end
    def status; 404 end
  end
   
  class Router

    def status; @status || ok end
    def logger; Traim.logger  end 

    # status code sytax suger
    def ok;                    @status = 200 end
    def created;               @status = 201 end
    def no_cotent;             @status = 204 end
    def bad_request;           @status = 400 end
    def not_found;             @status = 404 end
    def internal_server_error; @status = 500 end
    def not_implemented;       @status = 501 end
    def bad_gateway;           @status = 502 end

    def initialize 
      @status = nil
      @namespace = nil
      # @resource = resource
    end

    def self.resources; @resources ||= {} end

    def resources(name)
      self.class.resources[name]
    end

    def show(&block);    @resource.actions["GET"]    = block end
    def create(&block);  @resource.actions["POST"]   = block end
    def update(&block);  @resource.actions["PUT"]    = block end
    def destory(&block); @resource.actions["DELETE"] = block end

    def run(seg)  
      inbox = {}

      while seg.capture(:segment, inbox)
        segment = inbox[:segment].to_sym

        if @resource.nil?
          raise BadRequestError unless @resource = resources(segment)
          next
        end 

        if @id.nil? && !defined?(@collection_name)
          if collection = @resource.collections[segment]
            @collection_name = segment
            return instance_eval(&collection)
          else
            @id = segment
            @record = @resource.model_delegator.show(@id)
            next 
          end
        end

        if !defined?(@member_name)
          if member = @resource.members[segment]
            @member_name = segment
            return instance_eval(&member)
          end
        end

        raise BadRequestError 
      end
    end
    
    def to_json
      if @result.kind_of?(ActiveRecord::Relation)
        hash = @result.map do |r|
          @resource.to_hash(r) 
        end
        JSON.dump(hash)
      else
        new_hash = {}
        if @result.errors.size == 0
          new_hash = @resource.to_hash(@result)
        else
          new_hash = @result.errors.messages
        end
        JSON.dump(new_hash)
      end
    end

    def action(name)
      return @resource.actions[name] if @resource.actions[name]

      default_actions if @default_actions.nil?
      block = @default_actions[name]
      block
    end

    def default_actions
      @default_actions = {} 
      delegator = @resource.model_delegator
      @default_actions["POST"] = lambda do |params|
        delegator.create(params)
      end
      @default_actions["GET"] = lambda do |params|
        delegator.show(@id)
      end
      @default_actions["PUT"] = lambda do |params|
        result = delegator.update(@id, params)
        result
      end
      @default_actions["DELETE"] = lambda do |params|
        delegator.delete(@id)
      end
    end

    def model;  @resource.model end
    def record; @record; end

    def render(request)
      raise NotImplementedError unless method_block = action(request.request_method)
      @result = execute(request.params, &method_block)
      [status, '', [to_json]]
    end

    def execute(params, &block)
      yield params
    end
  end

  class Resource 
    def initialize(block) 
      instance_eval(&block) 
    end

    def model(object = nil, options = {})
      @model = object unless object.nil? 
      @model
    end

    def model_delegator
      @model_delegator ||= Model.new(model)
    end

    def actions; @actions ||= {} end
    def action(name, &block)
      action_methods = {create: 'POST', show: 'GET', update: 'PUT', destory: 'DELETE'}
      actions[action_methods[name]] = block unless block_given?
      actions[action_methods[name]]
    end

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
    def attribute(name)
      fields << {name: name, type: 'attribute'} 
    end

    def has_many(name)
      fields << {name: name, type: 'association'}
    end

    def has_one(name)
      fields << {name: name, type: 'connection'}
    end

    def to_hash(object, nest_associations = []) 
      fields.inject({}) do | hash, attr|
        name = attr[:name]
        hash[name] = if attr[:type] == 'attribute'
          object.attributes[name.to_s]
        elsif  attr[:type] == 'association'
          raise Error if nest_associations.include?(name)
          raise Error if object.class.reflections[name.to_s].blank?
          nest_associations << name
          object.send(name).map do |association|
            Router.resources[name].to_hash(association, nest_associations) 
          end
        else
          resource_name = name.to_s.pluralize.to_sym
          raise Error.new(message: "Inifinite Association") if nest_associations.include?(resource_name)
          raise Error if object.class.reflections[name.to_s].blank?
          nest_associations << resource_name 
          Router.resources[resource_name].to_hash(object.send(name), nest_associations)
        end
        hash
      end
    end
  end

  class Model

    def initialize(model)
      @model = model 
    end

    def create(params)
      resource = @model.new(params)
      resource.save
      resource
    end

    def show(id)
      @model.find id.to_s.to_i
    end

    def delete(id)
      show(id).delete
    end

    def update(id, params)
      resource = show(id)
      resource.assign_attributes(params)
      resource.save
      resource 
    end
  end
end
