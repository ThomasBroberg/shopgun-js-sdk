import fetch from 'cross-fetch'
import md5 from 'md5'
import SGN from '../../sgn'
import { error, btoa, throttle, uuid } from '../../util'
import * as clientLocalStorage from '../../storage/client-local'

createTrackerClient = ->
    id = clientLocalStorage.get 'client-id'
    id = id.data if id?.data

    if not id?
        id = uuid()
        
        clientLocalStorage.set 'client-id', id

    id: id

getPool = ->
    data = clientLocalStorage.get 'event-tracker-pool'
    data = [] if Array.isArray(data) is false
    data = data.filter (evt) ->
        typeof evt._i is 'string'

    data

pool = getPool()

export default class Tracker
    defaultOptions:
        trackId: null
        poolLimit: 1000

    constructor: (options = {}) ->
        for key, value of @defaultOptions
            @[key] = options[key] or value

        @client = options?.client or createTrackerClient()
        @location =
            geohash: null
            time: null
            country: null
        @dispatching = false

        dispatch()

        return

    trackEvent: (type, properties = {}, version = 2) ->
        throw error(new Error('Event type is required')) if typeof type isnt 'number'
        return if not @trackId?

        if SGN.config.get('appKey') is @trackId
            # coffeelint: disable=max_line_length
            throw error(new Error('Track identifier must not be identical to app key. Go to https://business.shopgun.com/developers/apps to get a track identifier for your app'))
        
        now = new Date().getTime()
        evt = Object.assign {}, properties, {
            '_e': type
            '_v': version
            '_i': uuid()
            '_t': Math.round(new Date().getTime() / 1000)
            '_a': @trackId
        }

        evt['l.h'] = @location.geohash if @location.geohash?
        evt['l.ht'] = @location.time if @location.time?
        evt['l.c'] = @location.country if @location.country?

        pool.push evt
        pool.shift() while pool.length > @poolLimit

        dispatch()

        @

    setLocation: (location = {}) ->
        for key, value of location
            if @location.hasOwnProperty(key)
                @location[key] = value

        @

    trackPagedPublicationOpened: (properties, version) ->
        @trackEvent 1, properties, version
    
    trackPagedPublicationPageDisappeared: (properties, version) ->
        @trackEvent 2, properties, version
    
    trackOfferOpened: (properties, version) ->
        @trackEvent 3, properties, version
    
    trackClientSessionOpened: (properties, version) ->
        @trackEvent 4, properties, version
    
    trackSearched: (properties, version) ->
        @trackEvent 5, properties, version
    
    createViewToken: (...parts) ->
        str = [@client.id].concat(parts).join ''
        viewToken = btoa String.fromCharCode.apply(null, (md5(str, {asBytes: true})).slice(0,8))

        viewToken

dispatching = false
dispatchLimit = 100

ship = (events = []) ->
    req = fetch SGN.config.get('eventsTrackUrl'),
        method: 'post'
        timeout: 1000 * 20
        headers:
            'Content-Type': 'application/json; charset=utf-8'
        body: JSON.stringify(events: events)
    
    req.then (response) -> response.json()
_dispatch = ->
    return if dispatching is true or pool.length is 0

    events = pool.slice 0, dispatchLimit
    nacks = 0
    dispatching = true

    ship(events)
        .then (response) ->
            dispatching = false

            response.events.forEach (resEvent) ->
                if resEvent.status is 'validation_error' or resEvent.status is 'ack'
                    pool = pool.filter (poolEvent) -> poolEvent._i isnt resEvent.id
                else if 'nack'
                    nacks++

                return

            # Keep dispatching until the pool size reaches a sane level.
            dispatch() if pool.length >= dispatchLimit and nacks is 0

            return
        .catch (err) ->
            dispatching = false

            throw err

            return
    
    return
dispatch = throttle _dispatch, 4000

clientLocalStorage.set 'event-tracker-pool', []

try
    window.addEventListener 'beforeunload', (e) ->
        pool = pool.concat getPool()

        clientLocalStorage.set 'event-tracker-pool', pool

        return
    , false