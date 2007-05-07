module Ruport
  
  # This module is designed to be mixed in with an ActiveRecord model
  # to add easy conversion to Ruport's data structures.
  module Reportable
    
    def self.included(base) # :nodoc:
      base.extend ClassMethods  
    end
    
    module ClassMethods 
      
      # In the ActiveRecord model you wish to integrate with Ruport, add the 
      # following line just below the class definition:
      #
      #   acts_as_reportable
      #
      # This will automatically make all the methods in this module available
      # in the model.
      #
      # You may pass the acts_as_reportable method the :only, :except,
      # :methods, and :include options.  See report_table for the format
      # of these options.
      #
      def acts_as_reportable(options = {})
        cattr_accessor :aar_options, :aar_columns

        self.aar_options = options

        include Ruport::Reportable::InstanceMethods
        extend Ruport::Reportable::SingletonMethods
      end
    end
    
    module SingletonMethods
      
      # Creates a Ruport::Data::Table from an ActiveRecord find. Takes 
      # parameters just like a regular find. If you use the :include 
      # option, it will return a table with all columns from the model and 
      # the included associations. If you use the :only option, it will
      # return a table with only the specified columns. If you use the
      # :except option, it will return a table with all columns except
      # those specified.
      # 
      # Options may be passed to the :include option in order to specify
      # the output for any associated models. In this case, the :include
      # option must be a hash, where the keys are the names of the
      # associations and the values are hashes of options.
      #
      # Use the :methods option to include a column with the same name as
      # the method and the value resulting from calling the method on the
      # model object.
      #
      # Any options passed to report_table will disable the options set by
      # the acts_as_reportable class method.
      #
      # Example:
      # 
      # class Book < ActiveRecord::Base
      #   belongs_to :author
      #   acts_as_reportable
      # end
      #
      # Book.report_table(:all, :only => ['title'],
      #   :include => { :author => { :only => 'name' } }).as(:html)
      #
      # Returns: an html version of a report with two columns, title from 
      # the book, and name from the associated author.
      #
      # Calling Book.report_table(:all, :include => [:author]).as(:html) will 
      # return a table with all columns from books and authors.
      #
      def report_table(number = :all, options = {})
        only = options.delete(:only)
        except = options.delete(:except)
        methods = options.delete(:methods)
        includes = options.delete(:include)
        self.aar_columns = []

        options[:include] = get_include_for_find(includes)
        
        data = [find(number, options)].flatten
        data = data.map {|r| r.reportable_data(:include => includes,
                               :only => only,
                               :except => except,
                               :methods => methods) }.flatten

        Ruport::Data::Table.new(:data => data, :column_names => aar_columns)
      end
      
      private
      
      def get_include_for_find(report_option)
        includes = report_option.blank? ? aar_options[:include] : report_option
        includes.is_a?(Hash) ? includes.keys : includes
      end
    end
    
    module InstanceMethods
      
      # Creates a Ruport::Data::Table from an instance of the model.
      # Works just like the class method, except doesn't take the
      # ActiveRecord find parameters since we're already working with an
      # instance.
      #
      def report_table(options = {})
        self.class.aar_columns = []
        Ruport::Data::Table.new(:data => reportable_data(options),
          :column_names => self.class.aar_columns)
      end
      
      # Grabs all of the object's attributes and the attributes of the
      # associated objects and returns them as an array of record hashes.
      # 
      # Associated object attributes are stored in the record with
      # "association.attribute" keys.
      # 
      # Passing :only as an option will only get those attributes.
      # Passing :except as an option will exclude those attributes.
      # Must pass :include as an option to access associations.  Options
      # may be passed to the included associations by providing the :include
      # option as a hash.
      # Passing :methods as an option will include any methods on the object.
      #
      # Example:
      # 
      # class Book < ActiveRecord::Base
      #   belongs_to :author
      #   acts_as_reportable
      # end
      # 
      # abook.reportable_data(:only => ['title'], :include => [:author])
      #
      # Returns:  [{'title' => 'book title',
      #             'author.id' => 'author id',
      #             'author.name' => 'author name' }]
      #  
      # NOTE: title will only be returned if the value exists in the table.
      # If the books table does not have a title column, it will not be
      # returned.
      #
      # Example:
      #
      # abook.reportable_data(:only => ['title'],
      #   :include => { :author => { :only => ['name'] } })
      #
      # Returns:  [{'title' => 'book title',
      #             'author.name' => 'author name' }]
      #
      def reportable_data(options = {})
        options = options.merge(self.class.aar_options) unless
          has_report_options?(options)
        
        data_records = [get_attributes_with_options(options)]
        Array(options[:methods]).each do |method|
          data_records.first[method.to_s] = send(method)
        end
        
        self.class.aar_columns |= data_records.first.keys
        
        data_records =
          add_includes(data_records, options[:include]) if options[:include]
        data_records
      end
      
      private

      # Add data for all included associations
      #
      def add_includes(data_records, includes)
        include_has_options = includes.is_a?(Hash)
        associations = include_has_options ? includes.keys : Array(includes)
        
        associations.each do |association|
          existing_records = data_records.dup
          data_records = []
          
          if include_has_options
            assoc_options =
              includes[association].merge({ :qualify_attribute_names => true })
          else
            assoc_options = { :qualify_attribute_names => true }
          end
          
          association_objects = [send(association)].flatten.compact
          
          existing_records.each do |existing_record|
            if association_objects.empty?
              data_records << existing_record
            else
              association_objects.each do |obj|
                association_records = obj.reportable_data(assoc_options)
                association_records.each do |assoc_record|
                  data_records << existing_record.merge(assoc_record)
                end
                self.class.aar_columns |= data_records.last.keys
              end
            end
          end
        end
        data_records
      end
      
      # Check if the options hash has any report options
      # (:only, :except, :methods, or :include).
      #
      def has_report_options?(options)
        options[:only] || options[:except] || options[:methods] ||
          options[:include]
      end

      # Get the object's attributes using the supplied options.
      # 
      # Use the :only or :except options to limit the attributes returned.
      #
      # Use the :qualify_attribute_names option to append the underscored
      # model name to the attribute name as model.attribute
      #
      def get_attributes_with_options(options = {})
        only_or_except =
          if options[:only] or options[:except]
            { :only => options[:only], :except => options[:except] }
          end
        attrs = attributes(only_or_except)
        attrs = attrs.inject({}) {|h,(k,v)|
                  h["#{self.class.to_s.underscore}.#{k}"] = v; h
                } if options[:qualify_attribute_names]
        attrs
      end
    end
  end
end
