require 'json'
require 'rack'
require 'seg'
require 'yaml'
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

  def self.call(env)
    @app.call(env)
  end

  def self.config(&block)
    config = YAML.load_file('config/database.yml')[TRAIM_ENV]
    ActiveRecord::Base.establish_connection(config)
    yield self 
  end

  def self.routes; @routes ||= {} end

  def resources(name, &block)
    self.class.routes[name] = block 
  end

  def call(env); dup.call!(env) end

  def call!(env)
    request = Rack::Request.new(env)
    seg = Seg.new(request.path_info)
    
    inbox = {}
    seg.capture(:segment, inbox)  
    segment = inbox[:segment].to_sym
    raise BadRequestError unless block = self.class.routes[segment]

    resource = Resource.new(&block)
    resource.run(seg)
    resource.render(request)

    [resource.status, resource.header, [resource.to_json]]
  rescue Error => e
    [e.status, e.header, [JSON.dump(e.body)]]
  rescue Exception => e
    puts "message: #{e.message}, b: #{e.backtrace}"
    error = Error.new
    [error.status, error.header, [JSON.dump(error.body)]]
  end

  class Error < StandardError
    def status; 500 end
    def header; DEFAULT_HEADER end
    def body; {message: 'error'} end
  end
  class NotImplementedError < Error
    def status; 501 end
  end
  class BadRequestError < Error
    def status; 400 end
  end
  class NotFoundError < Error
    def status; 404 end
  end

  class Resource 
    attr :header
    attr :id

    def status; @status || ok end

    # status code sytax suger
    def ok;                    @status = 200 end
    def created;               @status = 201 end
    def no_cotent;             @status = 204 end
    def bad_request;           @status = 400 end
    def not_found;             @status = 404 end
    def internal_server_error; @status = 500 end
    def not_implemented;       @status = 501 end
    def bad_gateway;           @status = 502 end

    def run(seg)  
      inbox = {}

      while seg.capture(:segment, inbox)
        segment = inbox[:segment].to_sym

        if @id.nil? && !defined?(@collection_name)
          if collection = collections[segment]
            @collection_name = segment
            return instance_eval(&collection)
          else
            @id = segment
            resource(model_delegator.show(@id))
            next 
          end
        end

        if !defined?(@member_name)
          if member = members[segment]
            @member_name = segment
            return instance_eval(&member)
          end
        end

        raise BadRequestError 
      end
    end

    def render(request)
      raise NotImplementedError unless method_block = actions[request.request_method]
      @result = execute(request.params, &method_block)
    end

    def execute(params, &block)
      @results = yield params
    end

    def element_type?; !defined?(@results) || !@results.kind_of?(Collection) end 

    def initialize(&block) 
      @status = nil 
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
      default_actions if @default_actions.nil?
      block = @default_actions[name] unless block_given?
      actions[action_methods[name]] = block
    end

    def default_actions
      @default_actions = {} 
      @default_actions[:create] = lambda do |params|
        model_delegator.create(params)
      end
      @default_actions[:show] = lambda do |params|
        model_delegator.show(id)
      end
      @default_actions[:update] = lambda do |params|
        result = model_delegator.update(id, params)
        result
      end
      @default_actions[:destory] = lambda do |params|
        model_delegator.delete(id)
      end
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

    def attributes; @attributes ||= [] end
    def attribute(name)
      attributes << name
    end

    def has_many(name)
    end

    def show(&block);    actions["GET"]    = block end
    def create(&block);  actions["POST"]   = block end
    def update(&block);  actions["PUT"]    = block end
    def destory(&block); actions["DELETE"] = block end

    def to_hash(object) 
      new_hash = attributes.inject({}) do | h, attr|
        h[attr] = object.attributes[attr.to_s]
        h
      end
    end

    def to_json
      if @result.kind_of?(ActiveRecord::Relation)
        hash = @result.map do |r|
          to_hash(r) 
        end
        JSON.dump(hash)
      else
        new_hash = {}
        if @result.errors.size == 0
          new_hash = to_hash(@result)
        else
          new_hash = @result.errors.messages
        end
        JSON.dump(new_hash)
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
