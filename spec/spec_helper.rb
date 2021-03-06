ENV["RAILS_ENV"] ||= 'test'

require File.expand_path("../../config/environment", __FILE__)
require 'simplecov'
SimpleCov.command_name "rspec-" + (ENV['TEST_RUN'] || '')
if ENV["CI"] == "true"
  # Only on Travis...
  require "codecov"
  SimpleCov.formatter = SimpleCov::Formatter::Codecov
end

require 'rspec/rails'
require 'factory_girl'
require 'database_cleaner'
require 'email_spec'

DatabaseCleaner.start

DatabaseCleaner.clean


# Requires supporting ruby files with custom matchers and macros, etc,
# in spec/support/ and its subdirectories.
Dir[Rails.root.join("spec/support/**/*.rb")].each {|f| require f}

FactoryGirl.find_definitions
FactoryGirl.definition_file_paths = %w(factories)

RSpec.configure do |config|
  config.mock_with :rspec

  config.expect_with :rspec do |c|
    c.syntax = [:should, :expect]
  end

  config.include FactoryGirl::Syntax::Methods
  config.include EmailSpec::Helpers
  config.include EmailSpec::Matchers
  config.include Devise::Test::ControllerHelpers, type: :controller
  config.include Capybara::DSL

  config.before :suite do
    DatabaseCleaner.strategy = :transaction
    DatabaseCleaner.clean
  end

  config.before :each do
    DatabaseCleaner.start
    User.current_user = nil
    clean_the_database

    # ES UPGRADE TRANSITION #
    # Remove $rollout activation & unless block
    $rollout.activate :start_new_indexing

    unless elasticsearch_enabled?($elasticsearch)
      $rollout.activate :stop_old_indexing
      $rollout.activate :use_new_search
    end
  end

  config.after :each do
    DatabaseCleaner.clean
    delete_test_indices
  end

  config.after :suite do
    DatabaseCleaner.clean_with :truncation
    delete_test_indices
  end

  # Remove this line if you're not using ActiveRecord or ActiveRecord fixtures
  config.fixture_path = "#{::Rails.root}/spec/fixtures"

  # If you're not using ActiveRecord, or you'd prefer not to run each of your
  # examples within a transaction, remove the following line or assign false
  # instead of true.
  config.use_transactional_fixtures = true

  BAD_EMAILS = ['Abc.example.com', 'A@b@c@example.com', 'a\"b(c)d,e:f;g<h>i[j\k]l@example.com', 'this is"not\allowed@example.com', 'this\ still\"not/\/\allowed@example.com', 'nodomain', 'foo@oops'].freeze
  INVALID_URLS = ['no_scheme.com', 'ftp://ftp.address.com', 'http://www.b@d!35.com', 'https://www.b@d!35.com', 'http://b@d!35.com', 'https://www.b@d!35.com'].freeze
  VALID_URLS = ['http://rocksalt-recs.livejournal.com/196316.html', 'https://rocksalt-recs.livejournal.com/196316.html'].freeze
  INACTIVE_URLS = ['https://www.iaminactive.com', 'http://www.iaminactive.com', 'https://iaminactive.com', 'http://iaminactive.com'].freeze

  # rspec-rails 3 will no longer automatically infer an example group's spec type
  # from the file location. You can explicitly opt-in to the feature using this
  # config option.
  # To explicitly tag specs without using automatic inference, set the `:type`
  # metadata manually:
  #
  #     describe ThingsController, type: :controller do
  #       # Equivalent to being in spec/controllers
  #     end
  config.infer_spec_type_from_file_location!
end

def clean_the_database
  # Now clear memcached
  Rails.cache.clear
  # Now reset redis ...
  REDIS_GENERAL.flushall
  REDIS_KUDOS.flushall
  REDIS_RESQUE.flushall
  REDIS_ROLLOUT.flushall
  REDIS_AUTOCOMPLETE.flushall

  ['work', 'bookmark', 'pseud', 'tag'].each do |index|
    update_and_refresh_indexes index
  end
end

# ES UPGRADE TRANSITION #
# Remove method
def elasticsearch_enabled?(elasticsearch_instance)
  elasticsearch_instance.cluster.health rescue nil
end

# ES UPGRADE TRANSITION #
# Remove method
def deprecate_unless(condition)
  return true unless condition

  yield
end

# ES UPGRADE TRANSITION #
# Remove method
def deprecate_old_elasticsearch_test
  deprecate_unless(elasticsearch_enabled?($elasticsearch)) do
    yield
  end
end

# ES UPGRADE TRANSITION #
# Replace all instances of $new_elasticsearch with $elasticsearch
def update_and_refresh_indexes(klass_name, shards = 5)
  # ES UPGRADE TRANSITION #
  # Remove block
  if elasticsearch_enabled?($elasticsearch)
    klass = klass_name.capitalize.constantize
    Tire.index(klass.index_name).delete
    klass.create_elasticsearch_index
    klass.import
    klass.tire.index.refresh
  end

  # NEW ES
  indexer_class = "#{klass_name.capitalize.constantize}Indexer".constantize

  indexer_class.delete_index
  indexer_class.create_index(shards)

  if klass_name == 'bookmark'
    bookmark_indexers = {
      BookmarkedExternalWorkIndexer => ExternalWork,
      BookmarkedSeriesIndexer => Series,
      BookmarkedWorkIndexer => Work
    }

    bookmark_indexers.each do |indexer, bookmarkable|
      indexer.new(bookmarkable.all.pluck(:id)).index_documents if bookmarkable.any?
    end
  end

  indexer = indexer_class.new(klass_name.capitalize.constantize.all.pluck(:id))
  indexer.index_documents if klass_name.capitalize.constantize.any?

  $new_elasticsearch.indices.refresh(index: "ao3_test_#{klass_name}s")
end

def refresh_index_without_updating(klass_name)
  $new_elasticsearch.indices.refresh(index: "ao3_test_#{klass_name}s")
end

def delete_index(index)
  # ES UPGRADE TRANSITION #
  # Remove block
  if elasticsearch_enabled?($elasticsearch)
    klass = index.capitalize.constantize
    Tire.index(klass.index_name).delete
  end

  # NEW ES
  index_name = "ao3_test_#{index}s"
  if $new_elasticsearch.indices.exists? index: index_name
    $new_elasticsearch.indices.delete index: index_name
  end
end

def delete_test_indices
  indices = $new_elasticsearch.indices.get_mapping.keys.select { |key| key.match("test") }
  indices.each do |index|
    $new_elasticsearch.indices.delete(index: index)
  end
end

def get_message_part (mail, content_type)
  mail.body.parts.find { |p| p.content_type.match content_type }.body.raw_source
end

shared_examples_for "multipart email" do
  it "generates a multipart message (plain text and html)" do
    expect(email.body.parts.length).to eq(2)
    expect(email.body.parts.collect(&:content_type)).to eq(["text/plain; charset=UTF-8", "text/html; charset=UTF-8"])
  end
end

def create_archivist
  user = create(:user)
  user.roles << Role.create(name: "archivist")
  user
end
