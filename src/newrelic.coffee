# Description:
#   Display stats from New Relic
#
# Dependencies:
#
# Configuration:
#   HUBOT_NEWRELIC_API_KEY
#   HUBOT_NEWRELIC_INSIGHTS_API_KEY
#   HUBOT_NEWRELIC_INSIGHTS_API_ENDPOINT
#   HUBOT_NEWRELIC_API_HOST="api.newrelic.com"
#
# Commands:
#   hubot newrelic apps - Returns statistics for all applications from New Relic
#   hubot newrelic apps errors - Returns statistics for applications with errors from New Relic
#   hubot newrelic apps name <filter_string> - Returns a filtered list of applications
#   hubot newrelic apps instances <app_id> - Returns a list of one application's instances
#   hubot newrelic apps hosts <app_id> - Returns a list of one application's hosts
#   hubot newrelic cfgov-deployed - What's currently deployed to cfgov environments?
#   hubot newrelic deployments <app_id> - Returns a filtered list of application deployment events
#   hubot newrelic deployments recent <app_id> - Returns a filtered list of application deployment events from the past week
#   hubot newrelic ktrans - Lists stats for all key transactions from New Relic
#   hubot newrelic ktrans id <ktrans_id> - Returns a single key transaction
#   hubot newrelic infra - Returns statistics for all servers from New Relic
#   hubot newrelic infra name <filter_string> - Returns a filtered list of servers
#   hubot newrelic users - Returns a list of all account users from New Relic
#   hubot newrelic users email <filter_string> - Returns a filtered list of account users
#   hubot newrelic users emails - Returns a list of all user emails
#   hubot newrelic alerts - Returns a list of active alert violations matching the current channel's subscriptions
#   hubot newrelic alerts all - Returns a list of all active alerts
#   hubot newrelic alerts subscribe <pattern> subscribe the current channel to alerts whose policy name(s) matches <pattern>. Simple matching patterns such as '*' will work, eg cf.gov*
#   hubot newrelic alerts unsubscribe <subscription_id> remove an existing subscription
#   hubot newrelic alerts subscriptions - show the current channel's subscriptions
#   hubot newrelic alerts set <setting> - enable an optional alert setting, like "verbose"
#   hubot newrelic alerts unset <setting> - disable an optional alert setting, like "verbose"
#   hubot newrelic alerts show <setting> - display the value of an optional alert setting, like "verbose"
#
# Authors:
#   statianzo
#
# Contributors:
#   spkane
#   cmckni3
#   marcesher
#   rosskarchner

_ = require 'lodash'
cson = require 'cson'
diff = require 'fast-array-diff'
gist = require 'quick-gist'
mdTable = require('markdown-table')
moment = require 'moment'
minimatch = require 'minimatch'
uuidv4 = require 'uuid/v4'

CFGOV_DEPLOY_CONFIG_ENV_VAR = "HUBOT_NEWRELIC_CFGOV_DEPLOY_CONFIG"


plugin = (robot) ->

  apiKey = process.env.HUBOT_NEWRELIC_API_KEY
  insightsKey = process.env.HUBOT_NEWRELIC_INSIGHTS_API_KEY
  insightsEndpoint = process.env.HUBOT_NEWRELIC_INSIGHTS_API_ENDPOINT
  apiHost = process.env.HUBOT_NEWRELIC_API_HOST or 'api.newrelic.com'

  try
    cfgovDeployConfig = cson.parseCSONFile process.env[CFGOV_DEPLOY_CONFIG_ENV_VAR]
  catch e
    if e.name == "TypeError"
      robot.logger.error "#{CFGOV_DEPLOY_CONFIG_ENV_VAR} is not defined"
    else
      robot.logger.error(
        "#{process.env[CFGOV_DEPLOY_CONFIG_ENV_VAR]} could not be loaded"
      )
    cfgovDeployConfig = {}

  return robot.logger.error "Please provide your New Relic API key at HUBOT_NEWRELIC_API_KEY" unless apiKey
  return robot.logger.error "Please provide your New Relic Insights API key at HUBOT_NEWRELIC_INSIGHTS_API_KEY" unless insightsKey
  return robot.logger.error "Please provide your New Relic Insights API endpoint at HUBOT_NEWRELIC_INSIGHTS_API_ENDPOINT" unless insightsEndpoint

  apiBaseUrl = "https://#{apiHost}/v2/"
  maxMessageLength = 4000 # some chat servers have a limit of 4000 chars per message. Lame.
  config = {}

  config.up = ':white_check_mark:'
  config.down = ':no_entry_sign:'

  infraQuery = _.template("""
    SELECT
      average(cpuPercent) AS cpuPercent,
      average(memoryUsedBytes / memoryTotalBytes) * 100 AS memoryPercent,
      average(diskUsedPercent) as diskUsedPercent
    FROM SystemSample
    FACET fullHostname
    <%= extras %>
    SINCE 1 minute ago
    LIMIT 1000
  """.replace(/\s+/, " "))

  _parse_response = (cb) ->
    (err, res, body) ->
      if err
        cb(err)
      else
        if not body
          return cb(new Error("No JSON response"))
        json = JSON.parse(body)
        if json.error
          cb(new Error(body))
        else
          cb(null, json)

  _request = (path, cb) ->
    robot.http(apiBaseUrl + path)
      .header('X-Api-Key', apiKey)
      .header('Content-Type','application/x-www-form-urlencoded')

  get = (path, cb) ->
    _request(path).get() _parse_response(cb)

  post = (path, data, cb) ->
    _request(path).post(data) _parse_response(cb)

  getInsights = (query, cb) ->
    unquoted = query.replace /^['"]?(.*?)['"]?$/gi, "$1"
    robot.http(insightsEndpoint + '?nrql=' + encodeURIComponent(unquoted))
      .header('Accept', 'application/json')
      .header('X-Query-Key', insightsKey)
      .get() _parse_response(cb)

  send_message = (msg, messages, longMessageIntro="") ->
    if messages.length < maxMessageLength
      msg.send messages
    else
      gist {content: messages, enterpriseOnly: true, fileExtension: 'md'}, (err, resp, data) ->
        msg.send "#{longMessageIntro} View output at: #{data.html_url}"

  message_room = (robot, room, messages, longMessageIntro="") ->
    if messages.length < maxMessageLength
      robot.messageRoom room, messages
    else
      gist {content: messages, enterpriseOnly: true, fileExtension: 'md'}, (err, resp, data) ->
        robot.messageRoom room, "#{longMessageIntro} View output at: #{data.html_url}"

  subscriptions_for_subscriber = (subscriber) ->
    subscription_lookup = robot.brain.get "newrelicviolations_subscriptions"
    (sub for sub_id, sub of subscription_lookup when sub.subscriber == subscriber)

  setting_for_channel = (channel, setting) ->
    all_channel_settings  = robot.brain.get "newrelicalerts_channelsettings"
    settings = all_channel_settings[channel] or {}
    settings[setting]

  annotate_incident_links = (violations, incident_lookup) ->
    account_id = process.env.HUBOT_NEWRELIC_INSIGHTS_API_ENDPOINT.match(/accounts\/(\d+)/i)[1]
    for violation in violations
      incident_id = incident_lookup[violation.id]
      if incident_id
        violation['url'] = "https://alerts.newrelic.com/accounts/#{account_id}/incidents/#{incident_id}/violations"
      else
        # fail over to the policy page
        violation['url'] = "https://alerts.newrelic.com/accounts/#{account_id}/policies/#{violation.links.policy_id}"

    return violations

  violations_for_subscriber = (all_violations, subscriber) ->
    subs = subscriptions_for_subscriber subscriber
    violations = []
    for v in all_violations
      for sub in subs
        if v[sub.field] and minimatch v[sub.field], sub.pattern, {nocase: true}
          violations.push v
    return violations

  dispatch_to_subscribers = (robot, alerts, action) ->
    subscription_lookup = robot.brain.get "newrelicviolations_subscriptions"
    updated_channels = []
    for alert in alerts
      destinations = _.uniq (sub_details.subscriber for sub_id, sub_details of\
        subscription_lookup\
        when alert[sub_details.field] and minimatch alert[sub_details.field], sub_details.pattern, {nocase: true})
      for channel in destinations
        updated_channels.push channel
        robot.messageRoom channel, "Alert #{action}: #{alert.policy_name} | #{alert.condition_name} ([#{alert.id}](#{alert.url}))"
    return updated_channels

  poll_violations = (robot) ->
    get "alerts_incidents.json", (err, json)->
      if err
        console.log err
      else
        incident_lookup = {}
        for incident in json.incidents
          for violation_id in incident.links.violations
            incident_lookup[violation_id] = incident.id
        get "alerts_violations.json?only_open=true", (err, json) ->
          if err
            console.log err
          else
            previous = robot.brain.get 'newrelicviolations'

            current = annotate_incident_links json.violations, incident_lookup

            violation_diff_compare = (left, right) ->
              left.id == right.id

            compare = diff.diff(previous || [], current, violation_diff_compare)

            channels_updated = dispatch_to_subscribers robot, compare.added, "Opened"
            channels_updated.concat dispatch_to_subscribers robot, compare.removed, "Cleared"
            channels_updated = _.uniq channels_updated

            for channel in channels_updated
              if setting_for_channel channel, 'verbose'
                violations = violations_for_subscriber current, channel
                if violations.length
                  message_room robot, channel, (plugin.violations violations, config)
                else
                  message_room robot, channel, "No more alerts for this channel!"

            robot.brain.set 'newrelicviolations', current
            console.log "#{current.length} Violations found, #{compare.added.length} opened, #{compare.removed.length} cleared"

  start_violations_polling = (robot) ->
    setInterval ->
      poll_violations(robot)?
    , 1000 * 60 * 2

  start_violations_polling(robot)

  getCfgovDeploys = (deployEnv, parentResolve, page = 1, deploys) ->
    deploys ?= _.fromPairs(
      _.zip deployEnv.targets, _.map(deployEnv.targets, (e) -> null)
    )

    # this will go back 1200 deploys, hoping that will cover us sufficiently
    maxPagesToRequest = 6

    if page > maxPagesToRequest
      robot.logger.error """
        'cfgov-deployed' exceeded max API requests without finding deploys for
        all targets in #{deployEnv.name}; verify all targets are valid
      """.replace(/\n/, " ").replace(/\s+/, " ").trim()
      return parentResolve({})

    new Promise((resolve, reject) ->
      get(
        "applications/#{deployEnv.apmAppId}/deployments.json?page=#{page}",
        (err, json) -> resolve({err: err, json: json})
      )
    ).then (result) ->
      if result.err
        robot.logger.error "'cfgov-deployed' API request error: #{result.err}"
        parentResolve({})
      else
        _.each Object.keys(deploys), (target) ->
          if !deploys[target]
            found = _.first(
              _.filter result.json.deployments, (d) -> d.user == target
            )
            if found
              found['deployEnvName'] = deployEnv.name
              deploys[target] = found
        if _.filter(Object.values(deploys), (v) -> !v).length
          new Promise((resolve, reject) ->
            getCfgovDeploys deployEnv, resolve, page + 1, deploys
          ).then (result_) -> parentResolve(result_)
        else
          parentResolve(deploys)

  robot.respond /(newrelic|nr) apps$/i, (msg) ->
    get 'applications.json', (err, json) ->
      if err
        msg.send "Failed: #{err.message}"
      else
        send_message msg, (plugin.apps json.applications, config)

  robot.respond /(newrelic|nr) apps errors$/i, (msg) ->
    get 'applications.json', (err, json) ->
      if err
        msg.send "Failed: #{err.message}"
      else
        result = (item for item in json.applications when item.error_rate > 0)
        if result.length > 0
          send_message msg, (plugin.apps result, config)
        else
          msg.send "No applications with errors."

  robot.respond /(newrelic|nr) ktrans$/i, (msg) ->
    get 'key_transactions.json', (err, json) ->
      if err
        msg.send "Failed: #{err.message}"
      else
        send_message msg, (plugin.ktrans json.key_transactions, config)

  robot.respond /(newrelic|nr) infra$/i, (msg) ->
    getInsights infraQuery({'extras': ''}), (err, json) ->
      if err
        msg.send "Failed: #{err.message}"
      else
        send_message msg, plugin.insightsFacets(json)

  robot.respond /(newrelic|nr) apps name ([\s\S]+)$/i, (msg) ->
    data = encodeURIComponent('filter[name]') + '=' +  encodeURIComponent(msg.match[2])
    post 'applications.json', data, (err, json) ->
      if err
        msg.send "Failed: #{err.message}"
      else
        send_message msg, (plugin.apps json.applications, config)

  robot.respond /(newrelic|nr) apps hosts ([0-9]+)$/i, (msg) ->
    get "applications/#{msg.match[2]}/hosts.json", (err, json) ->
      if err
        msg.send "Failed: #{err.message}"
      else
        send_message msg, (plugin.hosts json.application_hosts, config)

  robot.respond /(newrelic|nr) apps instances ([0-9]+)$/i, (msg) ->
    get "applications/#{msg.match[2]}/instances.json", (err, json) ->
      if err
        msg.send "Failed: #{err.message}"
      else
        send_message msg, (plugin.instances json.application_instances, config)

  robot.respond /(newrelic|nr) ktrans id ([0-9]+)$/i, (msg) ->
    get "key_transactions/#{msg.match[2]}.json", (err, json) ->
      if err
        msg.send "Failed: #{err.message}"
      else
        send_message msg, (plugin.ktran json.key_transaction, config)

  robot.respond /(newrelic|nr) infra name ([a-zA-Z0-9\-.]+)$/i, (msg) ->
    # we _hope_ the regex above makes NRQL injections an impossibility :-)
    where = "WHERE fullHostname = '#{msg.match[2]}'"
    getInsights infraQuery({'extras': where}), (err, json) ->
      if err
        msg.send "Failed: #{err.message}"
      else
        send_message msg, plugin.insightsFacets(json)


  robot.respond /(newrelic|nr) users$/i, (msg) ->
    get 'users.json', (err, json) ->
      if err
        msg.send "Failed: #{err.message}"
      else
        send_message msg, (plugin.users json.users, config)

  robot.respond /(newrelic|nr) users email ([a-zA-Z0-9.@]+)$/i, (msg) ->
    data = encodeURIComponent('filter[email]') + '=' +  encodeURIComponent(msg.match[2])
    post 'users.json', data, (err, json) ->
      if err
        msg.send "Failed: #{err.message}"
      else
        send_message msg, (plugin.users json.users, config)

  robot.respond /(newrelic|nr) users emails$/i, (msg) ->
    get 'users.json', (err, json) ->
      if err
        msg.send "Failed: #{err.message}"
      else
        send_message msg, (plugin.useremails json.users, config)

  robot.respond /(newrelic|nr) cfgov-deployed$/i, (msg) ->
    if !cfgovDeployConfig.environments?
      return send_message msg, "The `cfgov-deployed` command is not configured."

    Promise.all(
      _.map(cfgovDeployConfig.environments, (deployEnv) ->
        new Promise((resolve, reject) -> getCfgovDeploys(deployEnv, resolve))
      )
    ).then(
      (deploys) ->
        send_message(
          msg, plugin.cfgovDeploys(deploys, cfgovDeployConfig.githubBase)
        )
    )

  robot.respond /(newrelic|nr) deployments ([0-9]+)$/i, (msg) ->
    get "applications/#{msg.match[2]}/deployments.json", (err, json) ->
      if err
        msg.send "Failed: #{err.message}"
      else
        send_message msg, (plugin.deployments json.deployments, config)

  robot.respond /(newrelic|nr) deployments recent ([0-9]+)$/i, (msg) ->
    get "applications/#{msg.match[2]}/deployments.json", (err, json) ->
      if err
        msg.send "Failed: #{err.message}"
      else
        send_message msg, (plugin.deployments json.deployments, {recent:true})


   robot.respond /(newrelic|nr) alerts*\ *(all)*$/i, (msg) ->
     all_violations = robot.brain.get "newrelicviolations"
     room = msg.envelope.room

     if msg.match[2] != 'all'
       violations = violations_for_subscriber all_violations, msg.envelope.room
     else
       violations = all_violations

     message_room robot, room, (plugin.violations violations, config)


   robot.respond /(newrelic|nr) alerts* (set|unset|show) (.*)$/i, (msg) ->
     action = msg.match[2]
     setting = msg.match[3]
     all_channel_settings  = robot.brain.get "newrelicalerts_channelsettings"

     if not all_channel_settings
       all_channel_settings = {}
     room = msg.envelope.room

     settings = all_channel_settings[room] or {}

     if action == 'set'
       settings[setting] = true

     else if action == 'unset'
       settings[setting] = false

     all_channel_settings[room] = settings
     robot.brain.set "newrelicalerts_channelsettings", all_channel_settings

     message_room robot, room, "#{setting} is set to #{settings[setting]}"

   robot.respond /(newrelic|nr) alerts* dump_subscriptions$/i, (msg) ->
     room = msg.envelope.room
     subscriptions = robot.brain.get "newrelicviolations_subscriptions"
    #  console.log subscriptions

     subs = [['id', 'subscriber', 'field', 'pattern']]
     for id, details of subscriptions
       subs.push [id, details.subscriber, details.field, details.pattern]
     if subs.length > 1
       message_room robot, room, mdTable subs
     else
       message_room robot, room, "There are no alerts subscriptions"

   robot.respond /(newrelic|nr) alerts* (subscriptions|subscribed)$/i, (msg) ->
     room = msg.envelope.room
     subscriber = msg.envelope.room
     subscriptions = robot.brain.get "newrelicviolations_subscriptions"

     # I'm sure there's a more idiomatic way of doing this:
     my_subs = [['id', 'field', 'pattern']]
     for id, details of subscriptions
       if details.subscriber == subscriber
         my_subs.push [id, details.field, details.pattern]
     if my_subs.length > 1
       message_room robot, room, mdTable my_subs
     else
       message_room robot, room, "You are not subscribed to any alerts"

   robot.respond /(newrelic|nr) alerts* unsubscribe (.*)$/i, (msg) ->
     subscription_id  = msg.match[2]
     room = msg.envelope.room

     subscriptions = robot.brain.get "newrelicviolations_subscriptions"

     subscription = subscriptions[subscription_id]

     if not subscription
       message_room robot, room, "No such subscription!"
       return

     if subscription.subscriber == room
       delete subscriptions[subscription_id]
       message_room robot, room, "subscription #{subscription_id} deleted!"
     else
       message_room robot, room, "It doesn't seem like that subscription belongs to you"


   robot.respond /(newrelic|nr) alerts* subscribe (.*)$/i, (msg) ->
     field = 'policy_name'
     pattern = msg.match[2]

     subscriber = msg.envelope.room
     subscription_id = uuidv4()

     subscriptions = robot.brain.get "newrelicviolations_subscriptions"

     if not subscriptions
       subscriptions = {}

     subscription = {pattern,field,subscriber}
     subscriptions[subscription_id] = subscription
     robot.brain.set "newrelicviolations_subscriptions", subscriptions
     message_room robot, msg.envelope.room, "Created subscription #{subscription_id}. This channel will receive any alerts where #{field} matches #{pattern}"
     message_room robot, msg.envelope.room, "Unsubscribe with `nr alerts unsubscribe #{subscription_id}`"
     message_room robot, msg.envelope.room, "show all subscriptions with `nr alerts subscriptions`"

   robot.respond /(newrelic|nr) testpollalerts$/i, (msg) ->
     poll_violations robot

  # TODO consider re-enabling this listener if we ever decide that:
  #   (1) it is safe to do so -- not a security risk, or that big responses
  #       from Insights wouldn't kill the bot, etc
  #   (2) it would be a useful command to have in chat
  #
  # robot.respond /(newrelic|nr) insights (.*)$/i, (msg) ->
  #   getInsights msg.match[2], (err, json) ->
  #     if err
  #       msg.send "Failed: #{err.message}"
  #     else
  #       rendered = switch
  #         when json.facets? then plugin.insightsFacets json
  #         when json.results? then plugin.insightsEvents json
  #         else "Unable to recognize Insights response; please check your NRQL"
  #       send_message msg, rendered


insightsValueFmt = (key, val) ->
  timestampFormat = "YYYY-MM-DD HH:mm"

  if key == "timestamp"  # NR fixed column name, unlikely to ever change
    moment(parseInt(val, 10)).format(timestampFormat)
  else if typeof val == "number" and Number.isInteger(val)
    val.toLocaleString()
  else if typeof val == "number" and not Number.isInteger(val)
    val.toFixed(2).toString()
  else
    val


plugin.insightsEvents = (data) ->
  if (
    not data.results.length or
    not data.results[0].events? or
    not data.results[0].events.length
  )
    return "(no results)"

  orderCol = data.metadata.contents[0].order.column
  allKeys = Object.keys(data.results[0].events[0]).sort()
  cols = [orderCol].concat(_.without(allKeys, orderCol))

  extract = (r) -> _.map(cols, f = (k) -> insightsValueFmt(k, r[k]))
  rows = (extract(row) for row in data.results[0].events)
  rows.unshift(cols)

  mdTable(rows, {align: 'l'})


plugin.insightsFacets = (data) ->
  if not data.facets.length
    return "(no results)"

  facetName = data.metadata.facet
  dataItems = _.map(data.metadata.contents.contents, 'alias')
  cols = [facetName].concat(dataItems)

  rows = (
    [r.name].concat(
      _.map(
        r.results, f = (r) -> insightsValueFmt("result", Object.values(r)[0])
      )
    ) for r in data.facets
  )
  rows.unshift(cols)

  mdTable(rows, {align: 'l'})


plugin.cfgovDeploys = (deploys, githubBase) ->
  if !_.filter(deploys, (d) -> Object.keys(d).length).length
    return "No cfgov deploy data could be found."

  rows = [
    ["target", "env", "when", "tag/branch", "commit", "deployer", "job"]
  ].concat(
    _.flatMap(deploys, (group) ->
      _.map(group, (deploy) ->
        shortSha = deploy.revision.slice(0, 7)
        descrip = deploy.description.match(/^(.*?) was deployed by (.*?)$/)
        if descrip  # we overload the description field as you can see
          tagBranch = descrip[1]
          deployer = descrip[2]
          if tagBranch.startsWith('origin/')
            tagBranch = tagBranch.slice(7)
          tagBranchURL =
            if tagBranch.match(/^[0-9.]+$/)
              "#{githubBase}releases/tag/#{tagBranch}"
            else
              "#{githubBase}tree/#{tagBranch}"
        else
          tagBranch = "unknown"
          deployer = "unknown"
          tagBranchURL = "unknown"
        [
          deploy.user,  # actually the deploy target, not a user (don't ask)
          deploy.deployEnvName,
          moment(deploy.timestamp).format("YYYY-MM-DD HH:mm"),
          "[#{tagBranch}](#{tagBranchURL})",
          "[#{shortSha}](#{githubBase}commit/#{deploy.revision})",
          deployer,
          "[job](#{deploy.changelog})",
        ]
      )
    )
  )
  mdTable rows, {align: "l"}


plugin.apps = (apps, opts = {}) ->
  up = opts.up || "UP"
  down = opts.down || "DN"

  header = """
  | :white_medium_small_square: | Name | ID | Response time (ms) | Throughput | Error rate %|
  | -- | ---  | -- | ---                | ---        | ---         |
  """


  lines = apps.map (a) ->
    line = []
    summary = a.application_summary || {}

    if a.reporting
      line.push "| " + up
    else
      line.push "| " + down

    line.push a.name
    line.push a.id
    line.push summary.response_time
    line.push summary.throughput
    line.push summary.error_rate || "&nbsp;"

    line.join " | "

  "#{header}\n" + lines.join(" |\n")

plugin.hosts = (hosts, opts = {}) ->

  lines = hosts.map (h) ->
    line = []
    summary = h.application_summary || {}

    line.push h.application_name
    line.push h.host

    if isFinite(summary.response_time)
      line.push "Res:#{summary.response_time}ms"

    if isFinite(summary.throughput)
      line.push "RPM:#{summary.throughput}"

    if isFinite(summary.error_rate)
      line.push "Err:#{summary.error_rate}%"

    line.join "  "

  lines.join("\n")

plugin.instances = (instances, opts = {}) ->

  lines = instances.map (i) ->
    line = []
    summary = i.application_summary || {}

    line.push i.application_name
    line.push i.host

    if isFinite(summary.response_time)
      line.push "Res:#{summary.response_time}ms"

    if isFinite(summary.throughput)
      line.push "RPM:#{summary.throughput}"

    if isFinite(summary.error_rate)
      line.push "Err:#{summary.error_rate}%"

    line.join "  "

  lines.join("\n")

plugin.ktrans = (ktrans, opts = {}) ->

  lines = ktrans.map (k) ->
    line = []
    a_summary = k.application_summary || {}
    u_summary = k.end_user_summary || {}

    line.push "#{k.name} (#{k.id})"

    if isFinite(a_summary.response_time)
      line.push "Res:#{a_summary.response_time}ms"

    if isFinite(u_summary.response_time)
      line.push "URes:#{u_summary.response_time}ms"

    if isFinite(a_summary.throughput)
      line.push "RPM:#{a_summary.throughput}"

    if isFinite(u_summary.throughput)
      line.push "URPM:#{u_summary.throughput}"

    if isFinite(a_summary.error_rate)
      line.push "Err:#{a_summary.error_rate}%"

    line.join "  "

  lines.join("\n")

plugin.ktran = (ktran, opts = {}) ->

  result = [ktran]

  lines = result.map (t) ->
    line = []
    a_summary = t.application_summary || {}

    line.push t.name

    if isFinite(a_summary.response_time)
      line.push "Res:#{a_summary.response_time}ms"

    if isFinite(a_summary.throughput)
      line.push "RPM:#{a_summary.throughput}"

    if isFinite(a_summary.error_rate)
      line.push "Err:#{a_summary.error_rate}%"

    line.join "  "

  lines.join("\n")

plugin.users = (users, opts = {}) ->

  lines = users.map (u) ->
    line = []

    line.push "#{u.first_name} #{u.last_name}"
    line.push "Email: #{u.email}"
    line.push "Role: #{u.role}"

    line.join "  "

  lines.join("\n")

plugin.useremails = (users, opts = {}) ->

  lines = users.map (u) ->
    line = "#{u.email}"

  lines.join("\n")

plugin.deployments = (deployments, opts = {}) ->

  if opts.recent
    DAY = 1000 * 60 * 60  * 24
    today = new Date()

    recent = deployments.filter (d) ->
      Math.round((today.getTime() - new Date(d.timestamp).getTime()
      ) / DAY) <= 7
    deployments = recent

  header = """
  | Time | Deployer | Revision | Description |
  | ---  | ---      | ---      | ---         |
  """

  lines = deployments.map (d) ->
    line = []

    line.push("|" + moment(d.timestamp).calendar())
    line.push d.user
    line.push "[#{d.revision}](#{d.changelog})"
    line.push d.description

    line.join " | "

  "#{header}\n" + lines.join(" |\n")

plugin.violations = (violations, opts = {}) ->

  header = """
  **Current alerts are:**

  | Entity | Policy name | Opened | Duration |
  | ---    | ---         | ---    | ---      |
  """

  lines = violations.map (v) ->
    line = []

    line.push "|" + v.entity.name
    line.push "#{v.policy_name} - #{v.condition_name}"
    line.push "[#{moment(v.opened_at).calendar()}](#{v.url})"
    line.push moment.duration(v.duration, 's').humanize()

    line.join " | "

  "#{header}\n" + lines.join(" |\n")

module.exports = plugin
