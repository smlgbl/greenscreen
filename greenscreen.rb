require 'rubygems'
require 'bundler/setup'

require 'sinatra'
require 'erb'
require 'rexml/document'
require 'hpricot'
require 'open-uri'
require 'yaml'
require 'erb'
require 'timeout' # to catch error
require 'httparty'

get '/' do
  servers = load_servers
  return "Add the details of build server to the config.yml file to get started" unless servers

  @projects = []

  servers.each do |server|
    open_opts = {}
    if server["username"] || server["password"]
      open_opts[:http_basic_authentication] = [ server["username"], server["password"] ]
    end
    begin
      xml = REXML::Document.new(open(server["url"], open_opts))
      @projects.push(*accumulate_projects(server, xml))
    rescue => e
      @projects.push(MonitoredProject.server_down(server, e))
    rescue Timeout::Error => e
      @projects.push(MonitoredProject.server_down(server, e))
    end
  end

  @projects = @projects.sort_by { |p| p.name.downcase }

  @columns = 1.0
  @columns = 2.0 if @projects.size > 4
  @columns = 3.0 if @projects.size > 10
  @columns = 4.0 if @projects.size > 21

  @rows = (@projects.size / @columns).ceil

  erb :index
end

def load_servers
  YAML.load(StringIO.new(ERB.new(File.read 'config.yml').result))
end

def accumulate_projects(server, xml)
  projects = xml.elements["//Projects"]

  job_matchers =
    if server["jobs"]
      server["jobs"].collect do |j|
        if j =~ %r{^/.*/$}
          Regexp.new(j[1..(j.size-2)])
        else
          Regexp.new("^#{Regexp.escape(j)}$")
        end
      end
    end

  projects.collect do |project|
    monitored_project = MonitoredProject.create(project, server)
    if job_matchers
      if job_matchers.detect { |matcher| monitored_project.name =~ matcher }
        monitored_project
      end
    else
      monitored_project
    end
  end.flatten.compact
end

class MonitoredProject
  attr_accessor :name, :last_build_status, :activity, :last_build_time, :web_url, :last_build_label, :binfo
  @jsonsuffix = 'lastBuild/api/json'

  def self.create(project, server)
    MonitoredProject.new.tap do |mp|
      mp.activity = project.attributes["activity"]
      mp.last_build_time = Time.parse(project.attributes["lastBuildTime"]).localtime
      mp.web_url = project.attributes["webUrl"]
      mp.last_build_label = project.attributes["lastBuildLabel"]
      mp.last_build_status = project.attributes["lastBuildStatus"].downcase
      mp.name = project.attributes["name"]
	  mp.binfo = BuildInfo.new( mp.web_url, server )
    end
  end

  def self.server_down(server, e)
    MonitoredProject.new.tap do |mp|
      mp.name = e.to_s
      mp.last_build_time = Time.now.localtime
      mp.last_build_label = server["url"]
      mp.web_url = server["url"]
      mp.last_build_status = "Failure"
      mp.activity = "Sleeping"
	  mp.binfo = ""
    end
  end

  def building?
    self.activity =~ /building/i
  end

end

class BuildInfo
	include HTTParty
	attr_accessor :comitter, :msg, :branch

	def initialize(url, server)
		response = HTTParty.get( url + "lastBuild/api/json" , :basic_auth => { :username => server['username'], :password => server['password'] })
		resp = response.parsed_response
		resp["actions"].each do |action|
			next if action.nil?
			if !action["causes"].nil?
				causes = action["causes"][0]
				cause = causes["shortDescription"]
				if cause =~ /Started by an SCM change/
					hash = resp["changeSet"]["items"][0]
					self.comitter = hash["author"]["fullName"]
					self.msg = hash["msg"]
				elsif cause =~ /Started by user/
					self.msg = "Started by user "
					self.comitter = causes["userName"]
				elsif cause =~ /Started by upstream project/
					self.msg = "no change"
					self.comitter = "Upstream Project " + causes["upStreamProject"]
				end
			elsif !action["parameters"].nil?
				next if action["parameters"][0].nil?
				next if action["parameters"][0]["value"].nil?
				self.branch = action["parameters"][0]["value"]
			end
		end
	end

end
	
