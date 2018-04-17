# Description:
#   Display stats from New Relic
#
# Dependencies:
#
# Configuration:
#   HUBOT_NEWRELIC_API_KEY
#   HUBOT_NEWRELIC_INSIGHTS_API_KEY
#   HUBOT_NEWRELIC_INSIGHTS_API_ENDPOINT
#   HUBOT_NEWRELIC_ALERT_ROOM
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
#   hubot newrelic alerts - Returns a list of active alert violations
#
# Authors:
#   statianzo
#
# Contributors:
#   spkane
#   cmckni3
#   marcesher
#

_ = require 'lodash'
diff = require 'fast-array-diff'
gist = require 'quick-gist'
mdTable = require('markdown-table')
moment = require 'moment'


plugin = (robot) ->

  apiKey = process.env.HUBOT_NEWRELIC_API_KEY
  insightsKey = process.env.HUBOT_NEWRELIC_INSIGHTS_API_KEY
  insightsEndpoint = process.env.HUBOT_NEWRELIC_INSIGHTS_API_ENDPOINT
  apiHost = process.env.HUBOT_NEWRELIC_API_HOST or 'api.newrelic.com'
  room = process.env.HUBOT_NEWRELIC_ALERT_ROOM

  cfgovDeployConfig = {
    github: "https://github.com/cfpb/cfgov-refresh/",
    environments: ['prod', 'dev']
  }

  return robot.logger.error "Please provide your New Relic API key at HUBOT_NEWRELIC_API_KEY" unless apiKey
  return robot.logger.error "Please provide your New Relic Insights API key at HUBOT_NEWRELIC_INSIGHTS_API_KEY" unless insightsKey
  return robot.logger.error "Please provide your New Relic Insights API endpoint at HUBOT_NEWRELIC_INSIGHTS_API_ENDPOINT" unless insightsEndpoint
  return robot.logger.error "Please specify a room to report New Relic notifications to at HUBOT_NEWRELIC_ALERT_ROOM" unless room

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

  poll_violations = (robot) ->
    get "alerts_violations.json?only_open=true", (err, json) ->
      if err
        console.log err
        # robot.messageRoom room, "New Relic Violations Polling Failed: #{err.message}"
      else
        #console.log json.violations
        console.log "New Relic alerts poll. #{json.violations.length} alert(s) found"

        previous = robot.brain.get 'newrelicviolations'

        current = json.violations.map (v) -> "#{v.entity.name} - #{v.policy_name}"
        compare = diff.diff(previous || [], current)

        msg = ""
        if compare.removed.length
          msg = "**These New Relic alerts have cleared** :) \n\n"
          for v in compare.removed
            msg += "#{v} \n"

        if compare.added.length
          msg += "\n**There are new New Relic alerts** :( \n\n"
          for v in compare.added
            msg += "#{v} \n"

        if msg.length
          robot.brain.set 'newrelicviolations', current
          open = plugin.violations json.violations
          if json.violations.length
            msg += "\n\n**Current alerts are:** \n\n#{open} \n"
          message_room(robot, room, msg, "New Relic alerts have been cleared or added. ")
        else if json.violations.length
          console.log "Violations found, but none changed since last poll... not sending message"

  start_violations_polling = (robot) ->
    setInterval ->
      poll_violations(robot)?
    , 1000 * 60 * 2

  start_violations_polling(robot)

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
    targetsQuery = """
      SELECT uniques(target)
      FROM CFGovDeploy
      SINCE this quarter
      FACET environment
      LIMIT 1000
    """
    getInsights targetsQuery, (err, json) ->
      if err
        msg.send "Failed: #{err.message}"
      else
        targets = _.flatMap(cfgovDeployConfig.environments, (env) ->
          _.filter(json.facets, ['name', env])[0].results[0].members.sort()
        )
        query = _.template("""
          SELECT * FROM CFGovDeploy
          SINCE this quarter
          WHERE target = '${ target }'
          LIMIT 1
        """)
        Promise
          .all(
            # TODO would be nice to solve the n+1 queries situation here
            _.map(targets, (target) ->
              new Promise((resolve, reject) ->
                getInsights query({"target": target}), (err, json) ->
                  if err
                    resolve({"results": []})  # TODO add some logging?
                  else
                    resolve(json)
              )
            )
          )
          .then(
            (deploys) ->
              send_message msg, plugin.insightsDeploys(deploys, cfgovDeployConfig)
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


   robot.respond /(newrelic|nr) alerts$/i, (msg) ->
    get "alerts_violations.json?only_open=true", (err, json) ->
      if err
        msg.send "Failed: #{err.message}"
      else
        send_message msg, (plugin.violations json.violations, config)

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


plugin.insightsDeploys = (data, config) ->
  rows = [
    ["target", "env", "when", "tag/branch", "commit", "deployer", "job"]
  ].concat(
    _.map(_.filter(data, (d) -> d.results.length), (d) ->
      e = d.results[0].events[0]
      shortSha = e.revision.slice(0, 7)
      tagBranchURL =
        if e.tagBranch.match(/^[0-9.]+$/)
          "#{config.github}releases/tag/#{e.tagBranch}"
        else
          "#{config.github}tree/#{e.tagBranch}"
      [
        e.target,
        e.environment,
        insightsValueFmt("timestamp", e.timestamp),
        "[#{e.tagBranch}](#{tagBranchURL})",
        "[#{shortSha}](#{config.github}commit/#{e.revision})",
        e.deployer,
        "[job](#{e.jobURL})",
      ]
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
      Math.round((today.getTime() - new Date(d.timestamp).getTime() ) / DAY) <= 7
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
  | Entity | Policy name | Opened | Duration |
  | ---    | ---         | ---    | ---      |
  """

  lines = violations.map (v) ->
    line = []

    line.push "|" + v.entity.name
    line.push "#{v.policy_name} - #{v.condition_name}"
    line.push moment(v.opened_at).calendar()
    line.push moment.duration(v.duration, 's').humanize()

    line.join " | "

  "#{header}\n" + lines.join(" |\n")

module.exports = plugin
