SGN = require '../../sgn'
md5 = require 'md5'
clientLocalStorage = require '../../storage/client-local'

getPool = ->
    data = clientLocalStorage.get 'event-tracker-pool'
    data = [] if Array.isArray(data) is false

    data
pool = getPool()

clientLocalStorage.set 'event-tracker-pool', []

try
    window.addEventListener 'unload', ->
        pool = pool.concat getPool()

        clientLocalStorage.set 'event-tracker-pool', pool

        return
    , false

module.exports = class Tracker
    defaultOptions:
        trackId: null
        dispatchInterval: 3000
        dispatchLimit: 100
        poolLimit: 1000
        dryRun: false

    constructor: (options = {}) ->
        for key, value of @defaultOptions
            @[key] = options[key] or value

        @location =
            geohash: null
            time: null
            country: null
        @dispatching = false

        # Dispatch events periodically.
        @interval = setInterval @dispatch.bind(@), @dispatchInterval

        return

    trackEvent: (type, properties = {}, version = 2) ->
        throw SGN.util.error(new Error('Event type is required')) if typeof type isnt 'number'
        return if not @trackId?

        if SGN.config.get('appKey') is @trackId
            # coffeelint: disable=max_line_length
            throw SGN.util.error(new Error('Track identifier must not be identical to app key. Go to https://business.shopgun.com/developers/apps to get a track identifier for your app'))
        
        evt = Object.assign {}, properties, {
            '_e': type
            '_v': version
            '_i': SGN.util.uuid()
            '_t': Math.round(new Date().getTime() / 1000)
            '_a': @trackId
        }

        evt['l.h'] = @location.geohash if @location.geohash?
        evt['l.ht'] = @location.time if @location.time?
        evt['l.c'] = @location.country if @location.country?

        pool.push evt
        pool.shift() while @getPoolSize() > @poolLimit

        @

    setLocation: (location = {}) ->
        for key, value of location
            if @location.hasOwnProperty(key)
                @location[key] = value

        @

    getPoolSize: ->
        pool.length

    dispatch: ->
        return if @dispatching is true or @getPoolSize() is 0
        return pool.splice(0, @dispatchLimit) if @dryRun is true

        events = pool.slice 0, @dispatchLimit
        nacks = 0

        @dispatching = true

        @ship events, (err, response) =>
            @dispatching = false

            if not err?
                response.events.forEach (resEvent) ->
                    if resEvent.status is 'validation_error' or resEvent.status is 'ack'
                        pool = pool.filter (poolEvent) -> poolEvent._i isnt resEvent.id
                    else if 'nack'
                        nacks++

                    return

                # Keep dispatching until the pool size reaches a sane level.
                @dispatch() if @getPoolSize() >= @dispatchLimit and nacks is 0

            return

        @

    ship: (events = [], callback) ->
        http = new XMLHttpRequest()
        url = SGN.config.get 'eventsTrackUrl'

        http.open 'POST', url
        http.setRequestHeader 'Content-Type', 'application/json'
        http.setRequestHeader 'Accept', 'application/json'
        http.timeout = 1000 * 20
        http.onload = ->
            if http.status is 200
                try
                    callback null, JSON.parse(http.responseText)
                catch err
                    callback SGN.util.error(new Error('Could not parse JSON'))
            else
                callback SGN.util.error(new Error('Server did not accept request'))

            return
        http.onerror = ->
            callback SGN.util.error(new Error('Could not perform network request'))

            return
        http.send JSON.stringify(events: events)

        @

    trackPagedPublicationOpened: (properties, version) ->
        @trackEvent 1, properties, version
    
    trackPagedPublicationPageSpreadDisappeared: (properties, version) ->
        @trackEvent 2, properties, version
    
    trackOfferOpened: (properties, version) ->
        @trackEvent 3, properties, version
    
    trackClientSessionOpened: (properties, version) ->
        @trackEvent 4, properties, version
    
    trackSearched: (properties, version) ->
        @trackEvent 5, properties, version
    
    createViewToken: (...parts) ->
        str = [SGN.client.id].concat(parts).join ''
        viewToken = SGN.util.btoa String.fromCharCode.apply(null, (md5(str, {asBytes: true})).slice(0,8))

        viewToken