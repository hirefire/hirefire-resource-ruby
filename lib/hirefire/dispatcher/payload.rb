# frozen_string_literal: true

module HireFire
  class Dispatcher
    module Payload
      extend self

      def build(data, liveness:, since:, trace:, &omitted)
        series = {}
        watermark = nil

        if liveness
          claimed = claim(data.dig(liveness, Strategy::RQT) || {}, since)
          series[liveness] = {Strategy::RQT => claimed}
          watermark = claimed.keys.max
        end

        data.each do |name, strategies|
          strategies.each do |strategy, buckets|
            (series[name] ||= {})[strategy] ||= buckets
          end
        end

        entries = series.filter_map do |name, strategies|
          metrics = strategies.filter_map do |strategy, buckets|
            leaves = encode(name, strategy, buckets, &omitted)
            [strategy, leaves] unless leaves.empty?
          end
          {"name" => name, "metrics" => metrics.to_h} unless metrics.empty?
        end

        entries.first["sample_trace"] = trace if trace && entries.any?
        [entries, watermark]
      end

      def traced?(entries)
        entries.first.key?("sample_trace")
      end

      def without_trace(entries)
        [entries.first.except("sample_trace"), *entries.drop(1)]
      end

      private

      def claim(buckets, since)
        now = Time.now.to_i
        from = (since ? since + 1 : now).clamp(now - RQT_BACKFILL_LIMIT, now)
        (from..now).each_with_object(buckets.dup) { |second, claimed| claimed[second] ||= Buffer::EMPTY_BUCKET }
      end

      def encode(name, strategy, buckets)
        buckets.each_with_object({}) do |(second, bucket), leaves|
          leaf = Strategy.rqt?(strategy) ? rqt_leaf(bucket) : value_leaf(bucket)
          if leaf
            leaves[second.to_s] = leaf
          else
            yield name, strategy
          end
        end
      end

      def rqt_leaf(bucket)
        return [] if bucket[:count].zero?

        mean = value_leaf(bucket[:sum] / bucket[:count])
        [mean, bucket[:count]] if mean
      end

      def value_leaf(value)
        value if value.between?(0, METRIC_VALUE_LIMIT)
      end
    end
  end
end
