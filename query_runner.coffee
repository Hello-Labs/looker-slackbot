_ = require("underscore")
FuzzySearch = require('fuzzysearch-js')
levenshteinFS = require('fuzzysearch-js/js/modules/LevenshteinFS')

module.exports = {}

module.exports.FancyReplier = class FancyReplier

  constructor: (@replyContext) ->

  reply: (obj, cb) ->

    if @loadingMessage
      # Hacky stealth update of message to preserve chat order

      if typeof(obj) == 'string'
        obj = {text: obj, channel: @replyContext.replyTo.channel}

      params = {ts: @loadingMessage.ts, channel: @replyContext.replyTo.channel}

      update = _.extend(params, obj)
      update.attachments = if update.attachments then JSON.stringify(update.attachments) else null
      update.text = update.text || " "

      @replyContext.bot.api.chat.update(update)
    else
      @replyContext.bot.reply(@replyContext.replyTo, obj, cb)

  startLoading: (cb) ->

    sassyMessages = [
      ":flag-us: Just a second..."
      ":flag-gb: Working on it..."
      ":flag-ca: One moment please..."
      ":flag-in: Give me a minute..."
      ":flag-pk: Hold on..."
      ":flag-ng: Looking into it..."
      ":flag-ph: One sec..."
      ":flag-us: Hold please..."
      ":flag-eg: Wait a moment..."
      ":flag-es: Un momento, por favor..."
      ":flag-mx: Por favor espera..."
      ":flag-de: Bitte warten Sie einen Augenblick..."
      ":flag-jp: お待ちください..."
      ":flag-ca: Un moment s'il vous plait..."
      ":flag-cn: 稍等一會兒..."
      ":flag-nl: Even geduld aub..."
      ":flag-so: Ka shaqeeya waxaa ku..."
      ":flag-th: กรุณารอสักครู่..."
      ":flag-ru: один момент, пожалуйста..."
      ":flag-fi: Hetkinen..."
    ]

    sass = sassyMessages[Math.floor(Math.random() * sassyMessages.length)]

    params =
      text: sass
      channel: @replyContext.replyTo.channel
      as_user: true
      attachments: [] # Override some Botkit stuff

    @replyContext.bot.say(params, (err, res) =>
      @loadingMessage = res
      cb()
    )

  start: ->
    if process.env.LOOKER_SLACKBOT_STEALTH_EDIT == "true"
      @startLoading(=>
        @work()
      )
    else
      @work()

  replyError: (response) ->
    if response?.error
      @reply(":warning: #{response.error}")
    else if response?.message
      @reply(":warning: #{response.message}")
    else
      @reply(":warning: Something unexpected went wrong: #{JSON.stringify(response)}")

  work: ->

    # implement in subclass

module.exports.QueryRunner = class QueryRunner extends FancyReplier

  constructor: (@replyContext, @querySlug) ->
    super @replyContext

  showShareUrl: -> false

  postImage: (query, imageData, options = {}) ->
    success = (url) =>
      share = if @showShareUrl() then query.share_url else ""
      @reply(
        attachments: [
          _.extend({}, options, {image_url: url, title: share, title_link: share})
        ]
        text: ""
      )
    error = (error) =>
      @reply(":warning: #{error}")
    @replyContext.looker.storeBlob(imageData, success, error)

  postResult: (query, result, options = {}) ->
    if result.data.length == 0
      if result.errors?.length
        txt = result.errors.map((e) -> "#{e.message}```#{e.message_details}```").join("\n")
        @reply(":warning: #{query.share_url}\n#{txt}")
      else
        @reply("#{query.share_url}\nNo results.")
    else if result.fields.dimensions.length == 0
      attachment = _.extend({}, options, {
        fields: result.fields.measures.map((m) ->
          {title: m.label, value: result.data[0][m.name].rendered, short: true}
        )
      })
      @reply(
        attachments: [attachment]
        text: if @showShareUrl() then query.share_url else ""
      )
    else if result.fields.dimensions.length == 1 && result.fields.measures.length == 0
      attachment = _.extend({}, options, {
        fields: [
          title: result.fields.dimensions[0].label
          value: result.data.map((d) ->
            d[result.fields.dimensions[0].name].rendered
          ).join("\n")
        ]
      })
      @reply(
        attachments: [attachment]
        text: if @showShareUrl() then query.share_url else ""
      )
    else if (result.fields.dimensions.length == 1 && result.fields.measures.length == 1) || (result.fields.dimensions.length == 2 && result.fields.measures.length == 0)
      dim = result.fields.dimensions[0]
      mes = result.fields.measures[0] || result.fields.dimensions[1]
      attachment = _.extend({}, options, {
        fields: [
          title: "#{dim.label} – #{mes.label}"
          value: result.data.map((d) ->
            "#{d[dim.name].rendered} – #{d[mes.name].rendered}"
          ).join("\n")
        ]
      })
      @reply(
        attachments: [attachment]
        text: if @showShareUrl() then query.share_url else ""
      )
    else
      @reply("#{query.share_url}\n_Result table too large to display in Slack._")

  work: ->
    @replyContext.looker.client.get("queries/slug/#{@querySlug}", (query) =>
      @runQuery(query)
    (r) => @replyError(r))

  runQuery: (query, options = {}) ->
    type = query.vis_config?.type || "table"
    if type == "table"
      @replyContext.looker.client.get("queries/#{query.id}/run/unified", (result) =>
        @postResult(query, result, options)
      (r) => @replyError(r))
    else
      @replyContext.looker.client.get("queries/#{query.id}/run/png", (result) =>
        @postImage(query, result, options)
      (r) => @replyError(r)
      {encoding: null})

module.exports.LookQueryRunner = class LookQueryRunner extends QueryRunner

  constructor: (@replyContext, @lookId) ->
    super @replyContext, null

  showShareUrl: -> false

  work: ->
    @replyContext.looker.client.get("looks/#{@lookId}", (look) =>
      message =
        attachments: [
          fallback: look.title
          title: look.title
          text: look.description
          title_link: "#{@replyContext.looker.url}#{look.short_url}"
          image_url: if look.public then "#{look.image_embed_url}?width=606" else null
        ]

      @reply(message)

      if !look.public
        @runQuery(look.query, message.attachments[0])

    (r) => @replyError(r))


module.exports.DashboardQueryRunner = class DashboardQueryRunner extends QueryRunner

  constructor: (@replyContext, @dashboard, @filters = {}) ->
    super @replyContext, null

  showShareUrl: -> true

  work: ->
    for element in @dashboard.elements
      @replyContext.looker.client.get("looks/#{element.look_id}", (look) =>
        queryDef = look.query

        for dashFilterName, fieldName of element.listen
          if @filters[dashFilterName]
            queryDef.filters[fieldName] = @filters[dashFilterName]

        queryDef.filter_config = null

        @replyContext.looker.client.post("queries", queryDef, (query) =>
          @runQuery(query)
        , (r) => @replyError(r))

      (r) => @replyError(r))

module.exports.CLIQueryRunner = class CLIQueryRunner extends QueryRunner

  constructor: (@replyContext, @textQuery, @visualization) ->
    super @replyContext

  showShareUrl: -> true

  work: ->

    [txt, limit, path, ignore, fields] = @textQuery.match(/([0-9]+ )?(([\w]+\/){0,2})(.+)/)

    limit = +(limit.trim()) if limit

    pathParts = path.split("/").filter((p) -> p)

    if pathParts.length != 2
      @reply("You've got to specify the model and explore!")
      return

    fullyQualified = fields.split(",").map((f) -> f.trim()).map((f) ->
      if f.indexOf(".") == -1
        "#{pathParts[1]}.#{f}"
      else
        f
    )

    fields = []
    filters = {}
    sorts = []

    for field in fullyQualified
      matches = field.match(/([A-Za-z._ ]+)(\[(.+)\])?(-)? ?(asc|desc)?/i)
      [__, field, __, filter, minus, sort] = matches
      field = field.toLowerCase().trim().split(" ").join("_")
      if filter
        filters[field] = _.unescape filter
      if sort
        sorts.push "#{field} #{sort.toLowerCase()}"
      unless minus
        fields.push field

    queryDef =
      model: pathParts[0].toLowerCase()
      view: pathParts[1].toLowerCase()
      fields: fields
      filters: filters
      sorts: sorts
      limit: limit

    unless @visualization == "data"
      queryDef.vis_config =
        type: "looker_#{@visualization}"

    @replyContext.looker.client.post("queries", queryDef, (query) =>
      if @visualization == "data"
        @replyContext.looker.client.get("queries/#{query.id}/run/unified", (result) =>
          @postResult(query, result)
        (r) => @replyError(r))
      else
        @replyContext.looker.client.get("queries/#{query.id}/run/png", (result) =>
          @postImage(query, result)
        (r) => @replyError(r)
        {encoding: null})
    , (r) => @replyError(r))

module.exports.LookFinder = class LookFinder extends QueryRunner

  constructor: (@replyContext, @type, @query) ->
    super @replyContext

  matchLooks: (query, cb) ->
    @replyContext.looker.client.get("looks?fields=id,title,short_url,space(name,id)", (looks) =>
      fuzzySearch = new FuzzySearch(looks, {termPath: "title"})
      fuzzySearch.addModule(levenshteinFS({maxDistanceTolerance: 3, factor: 3}))
      results = fuzzySearch.search(query)
      cb(results)
    (r) => @replyError(r))

  work: ->
    @matchLooks(@query, (results) =>
      if results
        shortResults = results.slice(0, 5)
        @reply({
          text: "Matching Looks:"
          attachments: shortResults.map((v) =>
            look = v.value
            {
              title: look.title
              title_link: "#{@replyContext.looker.url}#{look.short_url}"
              text: "in #{look.space.name}"
            }
          )
        })
      else
        @reply("No Looks match \"#{@query}\".")
    )

module.exports.LookParameterizer = class LookParameterizer extends LookFinder

  constructor: (@replyContext, @paramQuery, @filterValue) ->
    super @replyContext

  showShareUrl: -> true

  work: ->
    @matchLooks(@paramQuery, (results) =>
      if results
        lookId = results[0].value.id
        @replyContext.looker.client.get("looks/#{lookId}", (look) =>

          queryDef = look.query
          if _.values(queryDef.filters).length > 0

            filterKey = _.keys(queryDef.filters)[0]
            queryDef.filters[filterKey] = @filterValue
            queryDef.filter_config = null

            @replyContext.looker.client.post("queries", queryDef, (query) =>
              @runQuery(query)
            , (r) => @replyError(r))

          else
            @reply("Look #{look.title} has no filters.")

        (r) => @replyError(r))
      else
        @reply("No Looks match \"#{@paramQuery}\".")
    )
