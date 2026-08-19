require "net/http"
require "json"
require "uri"

# Client for the Ubicloud API, used to run one long lived runner VM per user.
# The token is that user's personal access token, so every VM is created in
# their own project and billed to them.
#
# Schema confirmed against openapi/openapi.yml in ubicloud/ubicloud:
#   POST   /project/{project}/location/{location}/vm/{name}   create
#   GET    /project/{project}/location/{location}/vm/{name}   details
#   DELETE /project/{project}/location/{location}/vm/{name}   destroy
#   POST   .../vm/{name}/start   .../stop                     lifecycle
#   GET    /project/{project}/vm                              list
class Ubicloud
  BASE = "https://api.ubicloud.com".freeze

  class Error < StandardError
    attr_reader :status

    def initialize(message, status = nil)
      super(message)
      @status = status
    end
  end

  class AuthError < Error; end

  def initialize(token:, project_id:, base: BASE, http: nil)
    @token = token.to_s
    @project_id = project_id.to_s
    @base = base
    @http = http   # tests inject a callable; production uses Net::HTTP
    raise Error, "missing Ubicloud token" if @token.empty?
    raise Error, "missing Ubicloud project id" if @project_id.empty?
  end

  def create_vm(name:, location:, public_key:, boot_image: nil, size: nil,
                storage_size: nil, init_script: nil, unix_user: nil)
    body = {public_key: public_key}
    body[:boot_image] = boot_image if boot_image
    body[:size] = size if size
    body[:storage_size] = storage_size if storage_size
    body[:init_script] = init_script if init_script
    body[:unix_user] = unix_user if unix_user
    request(:post, vm_path(location, name), body)
  end

  def vm(name:, location:) = request(:get, vm_path(location, name))

  def delete_vm(name:, location:) = request(:delete, vm_path(location, name))

  def start_vm(name:, location:) = request(:post, "#{vm_path(location, name)}/start", {})

  def stop_vm(name:, location:) = request(:post, "#{vm_path(location, name)}/stop", {})

  def list_vms = request(:get, "/project/#{esc(@project_id)}/vm")

  # Cheapest call that proves the token and the project are both usable.
  def check!
    list_vms
    true
  end

  private

  def esc(value) = URI.encode_www_form_component(value.to_s)

  def vm_path(location, name) = "/project/#{esc(@project_id)}/location/#{esc(location)}/vm/#{esc(name)}"

  def request(method, path, body = nil)
    return @http.call(method, path, body) if @http

    uri = URI("#{@base}#{path}")
    klass = {get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete}.fetch(method)
    req = klass.new(uri)
    req["Authorization"] = "Bearer #{@token}"
    req["Accept"] = "application/json"
    req["User-Agent"] = "review-queue"
    if body
      req["Content-Type"] = "application/json"
      req.body = JSON.generate(body)
    end

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https",
      open_timeout: 10, read_timeout: 30) do |http|
      http.request(req)
    end
    handle(res.code.to_i, res.body)
  end

  def handle(status, raw)
    parsed = begin
      raw.to_s.empty? ? {} : JSON.parse(raw)
    rescue JSON::ParserError
      {}
    end

    return parsed if status.between?(200, 299)

    message = parsed.dig("error", "message") || parsed["message"] || "HTTP #{status}"
    raise AuthError.new("Ubicloud rejected the token: #{message}", status) if [401, 403].include?(status)
    raise Error.new("Ubicloud API #{status}: #{message}", status)
  end
end
