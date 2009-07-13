#==
# RailsCollab
# Copyright (C) 2007 - 2008 James S Urquhart
# Portions Copyright (C) René Scheibe
# Portions Copyright (C) Ariejan de Vroom
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
# 
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#++

class ProjectController < ApplicationController

  layout :project_layout

  verify :method      => :post,
         :only        => [ :delete, :remove_user, :remove_company, :open, :complete ],
         :add_flash   => { :error => true, :message => :invalid_request.l },
         :redirect_to => { :controller => 'project' }

  before_filter :process_session
  
  after_filter  :user_track, :only => [:index, :overview, :search, :tags, :people]


  def index
    overview
    render :template => 'project/overview'
  end

  def overview
    project = @active_project
    include_private = @logged_user.member_of_owner?
    when_fragment_expired "user#{@logged_user.id}_#{@active_project.id}_dblog", Time.now.utc + (60 * AppConfig.minutes_to_activity_log_expire) do
      @project_log_entries = (@logged_user.member_of_owner? ? project.application_logs : project.application_logs.public)[0..(AppConfig.project_logs_per_page-1)]
    end

    @time_now = Time.zone.now
    @late_milestones = project.project_milestones.late(include_private)
    @upcoming_milestones = ProjectMilestone.all_assigned_to(@logged_user, nil, @time_now.utc.to_date, (@time_now.utc + 14.days).to_date, [@active_project])

    @calendar_milestones = @upcoming_milestones.group_by do |obj| 
      date = obj.due_date.to_date
      "#{date.month}-#{date.day}"
    end

    @project_companies = project.companies(include_private)
    @important_messages = project.project_messages.important(include_private)
    @important_files = project.project_files.important(include_private)

    @content_for_sidebar = 'overview_sidebar'
  end

  def search
    @project = @active_project
    @current_search = params[:search_id]

    unless @current_search.nil?
      @last_search = @current_search

      current_page = params[:page].to_i
      current_page = 1 unless current_page > 0

      @search_results, @total_search_results = @project.search(@last_search, !@logged_user.member_of_owner?, {:page => current_page, :per_page => AppConfig.search_results_per_page})

      @tag_names, @total_search_tags = @project.search(@last_search, !@logged_user.member_of_owner?, {}, true)
      @pagination = []
      @start_search_results = AppConfig.search_results_per_page * (current_page-1)
      (@total_search_results.to_f / AppConfig.search_results_per_page).ceil.times {|page| @pagination << page+1}
    else
      @last_search = :search_box_default.l
      @search_results = []

      @tag_names = Tag.list_by_project(@project, !@logged_user.member_of_owner?, false)
    end

    @content_for_sidebar = 'search_sidebar'
  end

  def people
    @project = @active_project

    unless @project.can_be_seen_by(@logged_user)
      error_status(true, :insufficient_permissions)
      redirect_back_or_default :controller => 'dashboard'
      return
    end

    @project_companies = @project.companies
  end

  def permissions
    @project = @active_project

    unless @project.can_be_managed_by(@logged_user)
      error_status(true, :insufficient_permissions)
      redirect_back_or_default :controller => 'dashboard'
      return
    end

    case request.method
    when :get
      @project_users = @project.users
      @user_projects = @logged_user.projects

      @companies = [Company.owner]
      @permissions = ProjectUser.permission_names()
      clients = Company.owner.clients
      if clients.length > 0
        @companies += clients
      end
    when :post
      project_attribs = params[:project]

      # Sort out changes to the company set

      if params[:project_company]
        has_owner = false
        owner_company = Company.owner
        owner_id = owner_company.id

        valid_company_ids = params[:project_company].collect do |id|
          has_owner = true if !has_owner and id.to_i == owner_id
          id
        end

        valid_companies = Company.all(:conditions => { :id => valid_company_ids }, :select => 'id')

        @project.companies.clear
        @project.companies << owner_company unless has_owner

        valid_companies.each{ |valid_company| @project.companies << valid_company }
      else
        # No member companies except the owner
        @project.companies.clear
        @project.companies << Company.owner
      end

      # Grab a full list of companies for comparison
      real_companies = [Company.owner]
      clients = Company.owner.clients
      real_companies += clients unless clients.empty?
      real_companies_ids = real_companies.collect{ |company| company.id }

      # Grab the user set
      project_users = User.all(:conditions => { :company_id => real_companies_ids }, :select => ['id, company_id, username'])

      # Destroy the ProjectUser entry for each non-active user
      project_users.each do |user|
        next if user.owner_of_owner?

        found_id = nil

        # Have a look to see if it is on our list
        if params[:project_user]
          found_id = params[:project_user].detect{ |id| id.to_i == user.id }
        end

        # Have another look to see if his company is enabled
        has_valid_company = valid_companies.any?{ |company| company.id == user.company_id }

        if found_id.nil? or !has_valid_company
          # Exterminate! (maybe better if this was a single query?)
          ProjectUser.delete_all(['user_id = ? AND project_id = ?', user.id, @project.id])

          if !found_id.nil? and !has_valid_company
            params[:project_user].delete(found_id)
          end
        elsif ProjectUser.all(:conditions => ['user_id = ? AND project_id = ?', user.id, @project.id]).length > 0
          # Re-apply permissions
          if params[:project_user_permissions] and params[:project_user_permissions][found_id]
            ProjectUser.update_all(ProjectUser.update_str(params[:project_user_permissions][found_id], user), "user_id = #{user.id} AND project_id = #{@project.id}")
          else
            ProjectUser.update_all(ProjectUser.update_str({}, user), ['user_id = ? AND project_id = ?', user.id, @project.id])
          end

          params[:project_user].delete(found_id)
        end

        # Also check if he is activated
        #
      end

      # Create new ProjectUser entries for new users

      if params[:project_user]
        params[:project_user].each do |id|
          proj_user = User.find(id.to_i)
          next if proj_user.owner_of_owner?

          @project.users << proj_user
          if params[:project_user_permissions] && params[:project_user_permissions][id]
            ProjectUser.update_all(ProjectUser.update_str(params[:project_user_permissions][id], proj_user), "user_id = #{proj_user.id} AND project_id = #{@project.id}")
          else
            ProjectUser.update_all(ProjectUser.update_str({}, proj_user), "user_id = #{proj_user.id} AND project_id = #{@project.id}")
          end
        end
      end

      # Now we can do the log keeping!
      #@project.updated_by = @logged_user

      #if @project.save
      #  flash[:flash_success] = "Error updating permissions"
      #  redirect_to :controller => 'project', :action => 'permissions'
      #else
      error_status(false, :success_updated_permissions)
      redirect_to :controller => 'project', :action => 'people'
      #end
    end
  end

  def remove_user
    @project = @active_project

    unless @project.can_be_managed_by(@logged_user)
      error_status(true, :insufficient_permissions)
      redirect_back_or_default :controller => 'dashboard'
      return
    end

    user = User.find(params[:user])
    unless user.owner_of_owner?
      ProjectUser.delete_all(['user_id = ? AND project_id = ?', params[:user], @project.id])
    end

    redirect_back_or_default :controller => 'project', :action => 'people'
  end

  def remove_company
    @project = @active_project

    unless @project.can_be_managed_by(@logged_user)
      error_status(true, :insufficient_permissions)
      redirect_back_or_default :controller => 'dashboard'
      return
    end


    company = Company.find(params[:company])
    unless company.is_owner?
      company_user_ids = company.users.collect{ |user| user.id }
      ProjectUser.delete_all({ :user_id => company_user_ids, :project_id => @project.id })
      @project.companies.delete(company)
    end

    redirect_back_or_default :controller => 'project', :action => 'people'
  end

  def add
    unless Project.can_be_created_by(@logged_user)
      error_status(true, :insufficient_permissions)
      redirect_back_or_default :controller => 'dashboard'
      return
    end

    @project = Project.new

    case request.method
    when :post
      project_attribs = params[:project]

      @project.attributes = project_attribs
      @project.created_by = @logged_user
      @project.companies << Company.owner

      @auto_assign_users = Company.owner.auto_assign_users

      if @project.save
        # Add auto assigned people (note: we assume default permissions are all access)
        @auto_assign_users.each do |user|
          @project.users << user unless (user == @logged_user)
        end

        @project.users << @logged_user

        # Add default folders
        AppConfig.default_project_folders.each do |folder_name|
          folder = ProjectFolder.new(:name => folder_name)
          folder.project = @project

          ApplicationLog::new_log(folder, @logged_user, :add) if folder.save
        end

        # Add default message categories
        AppConfig.default_project_message_categories.each do |category_name|
          category = ProjectMessageCategory.new(:name => category_name)
          category.project = @project

          ApplicationLog::new_log(category, @logged_user, :add) if category.save
        end

        error_status(false, :success_added_project)
        redirect_to :controller => 'project', :action => 'permissions', :active_project => @project.id
      end
    end
  end

  def edit
    @project = @active_project

    unless @project.can_be_edited_by(@logged_user)
      error_status(true, :insufficient_permissions)
      redirect_back_or_default :controller => 'dashboard'
      return
    end

    case request.method
    when :post
      project_attribs = params[:project]

      @project.attributes = project_attribs
      @project.updated_by = @logged_user

      if @project.save
        error_status(false, :success_edited_project)
        redirect_back_or_default :controller => 'project'
      end
    end
  end

  def delete
    @project = @active_project

    unless @project.can_be_deleted_by(@logged_user)
      error_status(true, :insufficient_permissions)
      redirect_back_or_default :controller => 'dashboard'
      return
    end

    @project.updated_by = @logged_user
    @project.destroy

    error_status(false, :success_deleted_project)
    redirect_back_or_default :controller => 'dashboard'
  end

  def complete
    @project = @active_project

    unless @project.status_can_be_changed_by(@logged_user)
      error_status(true, :insufficient_permissions)
      redirect_back_or_default :controller => 'administration', :action => 'projects'
      return
    end

    unless @project.is_active?
      error_status(true, :project_already_completed)
      redirect_back_or_default :controller => 'administration', :action => 'projects'
      return
    end

    @project.set_completed(true, @logged_user)

    error_status(true, :error_saving) unless @project.save

    redirect_back_or_default :controller => 'administration', :action => 'projects'
  end

  def open
    @project = @active_project

    unless @project.status_can_be_changed_by(@logged_user)
      error_status(true, :insufficient_permissions)
      redirect_back_or_default :controller => 'administration', :action => 'projects'
      return
    end

    if @project.is_active?
      error_status(true, :project_already_open)
      redirect_back_or_default :controller => 'administration', :action => 'projects'
      return
    end

    @project.set_completed(false, @logged_user)

    error_status(true, :error_saving) unless @project.save

    redirect_back_or_default :controller => 'administration', :action => 'projects'
  end

  protected

  def project_layout
    ['add', 'edit', 'permissions'].include?(action_name) ? 'administration' : 'project_website'
  end
end
