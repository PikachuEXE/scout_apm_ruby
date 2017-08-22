module ScoutApm
  class DbQueryMetricSet
    include Enumerable

    attr_reader :metrics

    def initialize
      # A hash of DbQueryMetricStats values, keyed by DbQueryMetricStats.key
      @metrics = Hash.new
    end

    def each
      metrics.values.each do |db_query_metric_stat|
        yield db_query_metric_stat
      end
    end

    # Looks up a DbQueryMetricStats instance in the +@metrics+ hash. Sets the value to +other+ if no key
    # Returns a DbQueryMetricStats instance
    def lookup(other)
      metrics[other.key] ||= other
    end

    # Combines two DbQueryMetricStats intances. It's ok to call `combine!` on itself (results in a noop)
    # Returns a DbQueryMetricStats instance
    def combine!(other)
      lookup(other).combine!(other)
    end
  end
end