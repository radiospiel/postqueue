module Postqueue
  MAX_ATTEMPTS = 3

  module Processing
    # Processes many entries
    #
    # process limit: 100, skip_duplicates: true
    def process(options = {}, &block)
      limit           = options.fetch(:limit, 100)
      skip_duplicates = options.fetch(:skip_duplicates, true)
      options.delete :limit
      options.delete :skip_duplicates

      status, result = Item.transaction do
        process_inside_transaction options, limit: limit, skip_duplicates: skip_duplicates, &block
      end

      raise result if status == :err
      result
    end

    # Process a single entry from the queue
    #
    # Example:
    #
    #   process_one do |op, entity_type
    #   end
    def process_one(options = {}, &block)
      options = options.merge(limit: 1, skip_duplicates: false)
      process options, &block
    end

    private

    def select_and_lock(relation, limit:)
      relation = relation.where("failed_attempts < ? AND next_run_at < ?", MAX_ATTEMPTS, Time.now).order(:next_run_at, :id)

      sql = relation.to_sql + " FOR UPDATE SKIP LOCKED"
      sql += " LIMIT #{limit}" if limit
      items = Item.find_by_sql(sql)

      items
    end

    # The actual processing. Returns [ :ok, number-of-items ] or  [ :err, exception ]
    def process_inside_transaction(options, limit:, skip_duplicates:, &block)
      relation = Item.all
      relation = relation.where(options[:where]) if options[:where]

      first_match = select_and_lock(relation, limit: 1).first
      return [ :ok, nil ] unless first_match

      # find all matching entries with the same entity_type/op value
      if limit > 1
        batch_relation = relation.where(entity_type: first_match.entity_type, op: first_match.op)
        matches = select_and_lock(batch_relation, limit: limit)
      else
        matches = [ first_match ]
      end

      entity_ids = matches.map(&:entity_id)

      # When skipping dupes we'll find and lock all entries that match entity_type,
      # op, and one of the entity_ids in the first batch of matches
      if skip_duplicates
        entity_ids.uniq!
        process_relations = relation.where(entity_type: first_match.entity_type, op: first_match.op, entity_id: entity_ids)
        process_items = select_and_lock process_relations, limit: nil
      else
        process_items = matches
      end

      # Actually process the queue items
      result = [ first_match.op, first_match.entity_type, entity_ids ]
      result = yield *result if block_given?

      if result == false
        postpone process_items
      else
        Item.where(id: process_items.map(&:id)).delete_all 
      end

      [ :ok, result ]
    rescue => e
      postpone process_items
      [ :err, e ]
    end

    def postpone(items)
      ids = items.map(&:id)
      sql = "UPDATE postqueue SET failed_attempts = failed_attempts+1, next_run_at = next_run_at + interval '10 second' WHERE id IN (#{ids.join(",")})"
      Item.connection.exec_query(sql)
    end
  end
  
  extend Processing
end
