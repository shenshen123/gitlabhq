# frozen_string_literal: true
# rubocop:disable Style/Documentation

module Gitlab
  module BackgroundMigration
    class RemoveRestrictedTodos
      PRIVATE_FEATURE = 10
      PRIVATE_PROJECT = 0

      class Project < ActiveRecord::Base
        self.table_name = 'projects'
      end

      class ProjectAuthorization < ActiveRecord::Base
        self.table_name = 'project_authorizations'
      end

      class ProjectFeature < ActiveRecord::Base
        self.table_name = 'project_features'
      end

      class Todo < ActiveRecord::Base
        include EachBatch

        self.table_name = 'todos'
      end

      class Issue < ActiveRecord::Base
        include EachBatch

        self.table_name = 'issues'
      end

      def perform(start_id, stop_id)
        projects = Project.where('EXISTS (SELECT 1 FROM todos WHERE todos.project_id = projects.id)')
          .where(id: start_id..stop_id)

        projects.each do |project|
          remove_confidential_issue_todos(project.id)

          if project.visibility_level == PRIVATE_PROJECT
            remove_non_members_todos(project.id)
          else
            remove_restricted_features_todos(project.id)
          end
        end
      end

      private

      def remove_non_members_todos(project_id)
        Todo.where(project_id: project_id)
          .where('user_id NOT IN (?)', authorized_users(project_id))
          .each_batch(of: 5000) do |batch|
            batch.delete_all
          end
      end

      def remove_confidential_issue_todos(project_id)
        # min access level to access a confidential issue is reporter
        min_reporters = authorized_users(project_id)
          .select(:user_id)
          .where('access_level >= ?', 20)

        confidential_issues = Issue.select(:id, :author_id).where(confidential: true, project_id: project_id)
        confidential_issues.each_batch(of: 100) do |batch|
          batch.each do |issue|
            assigned_users = IssueAssignee.select(:user_id).where(issue_id: issue.id)

            todos = Todo.where(target_type: 'Issue', target_id: issue.id)
              .where('user_id NOT IN (?)', min_reporters)
              .where('user_id NOT IN (?)', assigned_users)
            todos = todos.where('user_id != ?', issue.author_id) if issue.author_id

            todos.delete_all
          end
        end
      end

      def remove_restricted_features_todos(project_id)
        ProjectFeature.where(project_id: project_id).each do |project_features|
          target_types = []
          target_types << 'Issue' if private?(project_features.issues_access_level)
          target_types << 'MergeRequest' if private?(project_features.merge_requests_access_level)
          target_types << 'Commit' if private?(project_features.repository_access_level)

          next if target_types.empty?

          Todo.where(project_id: project_id)
            .where('user_id NOT IN (?)', authorized_users(project_id))
            .where(target_type: target_types)
            .delete_all
        end
      end

      def private?(feature_level)
        feature_level == PRIVATE_FEATURE
      end

      def authorized_users(project_id)
        ProjectAuthorization.select(:user_id).where(project_id: project_id)
      end
    end
  end
end
