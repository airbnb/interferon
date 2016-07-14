require "spec_helper"

require 'treetop'

describe 'DatadogQueryParser' do
  let(:query_parser) {
    Treetop.load 'datadog.treetop'
    DatadogQueryParser.new
  }

  it 'passes basic queries'do
    expect(query_parser.parse('metric{*}').nil?).to be false
  end

  it 'rejects basic invalid queries'do
    expect(query_parser.parse('*').nil?).to be true
  end

  it 'passes queries with comma separated scopes'do
    expect(query_parser.parse('metric{host:foo, host:bar}').nil?).to be false
    expect(query_parser.parse('metric{host:foo , host:bar}').nil?).to be false
    expect(query_parser.parse('metric{host:foo ,host:bar}').nil?).to be false
    expect(query_parser.parse('metric{host:foo,host:bar}').nil?).to be false
  end

  it 'passes queries with group by'do
    expect(query_parser.parse('metric{host:foo, host:bar} by {host}').nil?).to be false
    expect(query_parser.parse('metric{host:foo, host:bar} by {host,zone}').nil?).to be false
    expect(query_parser.parse('metric{host:foo, host:bar} by {host, zone}').nil?).to be false
    expect(query_parser.parse('metric{host:foo, host:bar} by {host , zone}').nil?).to be false
    expect(query_parser.parse('metric{host:foo, host:bar} by {host ,zone}').nil?).to be false
  end

  it 'passes queries with space_aggrations'do
    expect(query_parser.parse('avg:metric{*}').nil?).to be false
    expect(query_parser.parse('min:metric{*}').nil?).to be false
    expect(query_parser.parse('max:metric{*}').nil?).to be false
    expect(query_parser.parse('sum:metric{*}').nil?).to be false
    expect(query_parser.parse('sum:metric{*} by {host}').nil?).to be false
  end

  it 'rejects queries with invalid space_aggrations'do
    expect(query_parser.parse('mean:metric{*}').nil?).to be true
    expect(query_parser.parse('median:metric{*}').nil?).to be true
    expect(query_parser.parse('mode:metric{*} by {host}').nil?).to be true
  end

  it 'passes queries enclosed in parentheses'do
    expect(query_parser.parse('(metric{*})').nil?).to be false
    expect(query_parser.parse('(avg:metric{*} by {host})').nil?).to be false
  end

  it 'passes queries with arithmetic operators'do
    expect(query_parser.parse('1 + avg:metric{*} by {host}').nil?).to be false
    expect(query_parser.parse('1.5 + avg:metric{*} by {host}').nil?).to be false
    expect(query_parser.parse('avg:metric{*} by {host} - 1').nil?).to be false
    expect(query_parser.parse('avg:metric{*} by {host} - 1.5').nil?).to be false
    expect(query_parser.parse('avg:metric{*} by {host} + avg:metric_2{*} by {host}').nil?).to be false
    expect(query_parser.parse('avg:metric{*} by {host} + avg:metric_2{*} by {host} / avg:metric_3{*} by {host}').nil?).to be false
    expect(query_parser.parse('(avg:metric{*} by {host} + avg:metric_2{*} by {host}) / avg:metric_3{*} by {host}').nil?).to be false
  end

  it 'rejects queries with invalid arithmetic operators'do
    expect(query_parser.parse('avg:metric{*} by {host} % 2').nil?).to be true
  end

  it 'passes queries with append functions'do
    expect(query_parser.parse('avg:metric{*}.as_count()').nil?).to be false
    expect(query_parser.parse('avg:metric{*} by {host}.as_count()').nil?).to be false
    expect(query_parser.parse('avg:metric{*}.as_rate()').nil?).to be false
    expect(query_parser.parse('avg:metric{*}.rollup("avg",15)').nil?).to be false
    expect(query_parser.parse('avg:metric{*}.rollup(count, 15)').nil?).to be false
    expect(query_parser.parse('avg:metric{*}.rollup(count, 15) + 15').nil?).to be false
  end

  it 'reject queries with invalid append functions'do
    expect(query_parser.parse('avg:metric{*}.as_counter()').nil?).to be true
    expect(query_parser.parse('avg:metric{*}.rollup("mean",15)').nil?).to be true
  end

  it 'passes queries with functions'do
    expect(query_parser.parse('diff(avg:metric{*})').nil?).to be false
    expect(query_parser.parse('ewma_5(avg:metric{*})').nil?).to be false
    expect(query_parser.parse('top5(avg:metric{*})').nil?).to be false
    expect(query_parser.parse('top(avg:metric{*}, 10, last, asc)').nil?).to be false
    expect(query_parser.parse('top_offset(avg:metric{*}, 10, last, asc, 10)').nil?).to be false
    expect(query_parser.parse('forecast(avg:metric{*}, median, hourly, 3)').nil?).to be false
    expect(query_parser.parse('forecast(avg:metric{*}, median, hourly, 3).as_count()').nil?).to be false
  end

  it 'rejects queries with invalid functions'do
    expect(query_parser.parse('diff(avg:metric{*}').nil?).to be true
    expect(query_parser.parse('bad_function(avg:metric{*})').nil?).to be true
    expect(query_parser.parse('top_5(avg:metric{*})').nil?).to be true
    expect(query_parser.parse('top(avg:metric{*}, 10, last)').nil?).to be true
    expect(query_parser.parse('top_offset(avg:metric{*}, 10, last, asc)').nil?).to be true
    expect(query_parser.parse('forecast(avg:metric{*}, median, monthly, 3)').nil?).to be true
    expect(query_parser.parse('forecast(avg:metric{*}, average, weekly, 3)').nil?).to be true
    expect(query_parser.parse('forecast(avg:metric{*}, median, weekly, 1)').nil?).to be true
  end

  it 'passes alerts'do
    expect(query_parser.parse('avg(last_1m):metric{*} > 1').nil?).to be false
    expect(query_parser.parse('avg(last_1m):metric{*} != 1.0').nil?).to be false
    expect(query_parser.parse('avg(last_1m):min:metric{*} > 1').nil?).to be false
    expect(query_parser.parse('avg(last_1m):min:metric{*} + min:metric_2{*}> 1').nil?).to be false
    expect(query_parser.parse('avg(last_1m):min:metric{*} + min:metric_2{*}> 1').nil?).to be false
    expect(query_parser.parse('change(avg(last_1m), 5m_ago):metric{*} > 1').nil?).to be false
    expect(query_parser.parse('pct_change(avg(last_1m), 5m_ago):metric{*} > 1').nil?).to be false
  end

  it 'rejects bad alerts'do
    expect(query_parser.parse('median(last_1m):metric{*} > 1').nil?).to be true
    expect(query_parser.parse('avg(last_2m):metric{*} > 1').nil?).to be true
    expect(query_parser.parse('change(avg(last_1m)):metric{*} > 1').nil?).to be true
  end

end
