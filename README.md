# Instructure fork #
We use a fork of AirBnB's Inteferon with the following modifications:
  * changed alert key
  * added support for evaluation_delay
  * alerts can be read from a multi-level directory
  * support for fallback_groups

# Interferon #

[![Build Status](https://travis-ci.org/airbnb/interferon.svg?branch=master)](https://travis-ci.org/airbnb/interferon)

This repo contains the interferon gem.
This gem enables you to store your alerts configuration in code.
You should create your own repository, with a `Gemfile` which imports the interferon gem.
For an example of such a repository, along with example configuration and alerts files, see https://www.github.com/airbnb/alerts

## Running This Gem ##

This gem provides a single executable, called `interferon`.
You are meant to invoke it like so:

```bash
$ bundle exec interferon --config /path/to/config_file
```

Additional options:
* `-h`, `--help` -- prints out usage information
* `-n`, `--dry-run` -- runs interferon without making any changes to alerting destinations

## Configuration File ##

The configuration file is written in YAML.
It accepts the following parameters:
* `verbose_logging` -- whether to print more output
* `alerts_repo_path` -- the location to your alerts repo, containing your interferon DSL files
* `group_sources` -- a list of sources which can return groups of people to alert
* `host_sources` -- a list of sources which can read inventory systems and return lists of hosts to monitor
* `destinations` -- a list of alerting providers, which can monitor metrics and dispatch alerts as specified in your alerts dsl files

For more information, see [config.example.yaml](config.example.yaml) file in this repo.

## The Moving Parts ##

This repo knows about four kinds of objects:

* *host_sources*: these query various inventory systems and return lists of hosts or entities to alert on
* *destinations*: these are metric systems, which can watch metrics and alert engineers
* *groups*: these are groups of actual engineers who can be alerted in case of trouble
* *alerts*: these are ruby DSL files which specify when and how engineers and groups are alerted via the destination about hosts

### Host Sources ###

* optica: can read a list of AWS instances from [optica](https://www.github.com/airbnb/optica)
* optica_services: returns smartstack service information parsed from optica
* aws_rds: lists RDS instances
* aws_dynamo: lists dynamo-db tables
* aws_elasticache: lists elasticache nodes and clusters

### Destinations ###

#### Datadog ####

Datadog is our only alerting destination at the moment.
Datadog's alerting syntax rule are here: [http://docs.datadoghq.com/api/#alerts](http://docs.datadoghq.com/api/#alerts)
Here's a chart explaining the datadog metric syntax ([generated via asciiflow](http://www.asciiflow.com/#669823367132047287/1039453499)):

```
    +---------+ alert condition +-------------------------------------------------+
    |                                                                             |
    |              +-----+ metric to alert on                                     |
    |              |                                                              |
    |              |    tags to slice the metric by +------+                      |
    |              |                                       |                      |
    v              v                                       v                      v
  |----------| |-------------------------||--------------------------|          |---|
  max(last_5m):avg:haproxy_count_by_status{role:<%= role %>,status:up} by {host} > 0
  ^      ^      ^                                                          ^
  |      |      |                                                          |
  |      | +----+------------------------------+                           |
  |      | | math on the metric over all tags  |                           |
  |      | |-----------------------------------|            +------------------------------------+
  |      | | * max, min, avg, sum              |            |trigger a separate alert for each   |
  |      + +-----------------------------------+            |different value of these tags the   |
  | +----+----------------------------------------------+   |entire `by {}` clause can be omitted|
  | | the interval to look at; always starts with last_ |   +------------------------------------+
  | |---------------------------------------------------|
  | | * 5m, 10m, 15m, 30m                               |
  | | * 1h, 2h, 4h                                      |
  + +---------------------------------------------------+
 +-------------------------------------------------------------------------------------------------+
 | metric condition, can be one of:                                                                |
 |-------------------------------------------------------------------------------------------------|
 | * max: the metric gets this high at least once during the interval                              |
 | * avg: the metric is this on average during the interval                                        |
 | * min: the metric is this small at least once during the interval                               |
 | * change: the metric changes this much between a value N minutes ago and now (raw difference).  |
 | * pct_change: the metric changes this much between a value N minutes ago and now (percentage).  |
 +-------------------------------------------------------------------------------------------------+
```

### Groups ###

Groups actually come from *group_sources*.
We only have a single group source right now, which reads groups in YAML files from the filesystem.
However, we would like to add additional group sources, such as LDAP-based ones.
