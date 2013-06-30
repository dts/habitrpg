express = require('express')
coffeeify = require('coffeeify')
derby = require('derby')
racerBrowserChannel = require('racer-browserchannel')
LiveDbMongo = require('livedb-mongo').LiveDbMongo
MongoStore = require('connect-mongo')(express)
error = require('./serverError')
mongoskin = require('mongoskin')
publicDir = require('path').join __dirname + '/../../public'

login = require('../login')
main = require('../app')

auth = require 'derby-auth'
nconf = require 'nconf'
priv = require './private.coffee'
middleware = require './middleware'
helpers = require("habitrpg-shared/script/helpers.coffee")

# Infinite stack trace
Error.stackTraceLimit = Infinity if nconf.get('NODE_ENV') is 'development'

# Set up our express app

expressApp = module.exports = express()

# Get Redis configuration
if nconf.get('REDIS_HOST')
  redis = require("redis").createClient nconf.get('REDIS_PORT'), nconf.get('REDIS_HOST')
  redis.auth nconf.get('REDIS_PASSWORD')
else
  redis = require("redis").createClient()
redis.select nconf.get('REDIS_DATABASE')

# Get Mongo configuration
mongoUrl = nconf.get('NODE_DB_URI')
mongo = mongoskin.db(mongoUrl + "?auto_reconnect",
  safe: true
)

# The store creates models and syncs data
store = derby.createStore(
  db: new LiveDbMongo(mongo)
  redis: redis
)

# Expose stuff to test suite which we wouldn't want exposed to production app
if nconf.get('NODE_ENV')
  module.exports.store = store

store.on 'bundle', (browserify) ->
  vendorScripts = [
    "jquery-ui-1.10.2/jquery-1.9.1"
    "jquery.cookie.min"
    "bootstrap/js/bootstrap.min"
    "jquery.bootstrap-growl.min"
    "datepicker/js/bootstrap-datepicker"
    "bootstrap-tour/bootstrap-tour"
  ]
  # FIXME check if mobile
  vendorScripts = vendorScripts.concat [
    "jquery-ui-1.10.2/ui/jquery.ui.core"
    "jquery-ui-1.10.2/ui/jquery.ui.widget"
    "jquery-ui-1.10.2/ui/jquery.ui.mouse"
    "jquery-ui-1.10.2/ui/jquery.ui.sortable"
    "sticky"
  ]
  vendorScripts.forEach (s) -> browserify.add "#{publicDir}/vendor/#{s}.js"
  # Add support for directly requiring coffeescript in browserify bundles
  browserify.transform coffeeify

# Authentication setup

#Save new user in usersPublic & usersPrivate after derby-auth has saved to `auths` collection
module.exports.registerCallback = (req, res, auth, next) ->
  u = require('../app/user.coffee')
  model = req.getModel()
  uobj = u.transformForDerby helpers.newUser()
  uobj.priv.id = uobj.pub.id = auth.id
  uobj.pub.profile = name: helpers.usernameCandidates(auth)
  model.add "usersPublic", uobj.pub, (err) ->
    return next(err) if err
    model.add "usersPrivate", uobj.priv, (err) ->
      return next(err) if err
      next()

strategies =
  facebook:
    strategy: require("passport-facebook").Strategy
    conf:
      clientID: nconf.get('FACEBOOK_KEY')
      clientSecret: nconf.get('FACEBOOK_SECRET')

options =
  site:
    domain: nconf.get('BASE_URL')
  passport:
    registerCallback: registerCallback: module.exports.registerCallback

# This has to happen before our middleware stuff
auth.store(store, mongo, strategies)
#require('./store')(store) # setup our own accessControl

expressApp
  .use(middleware.allowCrossDomain)
  .use(express.favicon())
  .use(express.compress()) # Gzip dynamically
  .use(main.scripts(store)) # Respond to requests for application script bundles
  .use(login.scripts(store)) # Respond to requests for application script bundles
  .use(express['static'](publicDir)) # Serve static files from the public directory

  # Session middleware
  .use(express.cookieParser())
  .use(express.session(
    secret: nconf.get('SESSION_SECRET')
    store: new MongoStore(
      url: mongoUrl
      safe: true
    )
  ))
  # Parse form data
  .use(express.bodyParser())
  .use(express.methodOverride())

  #.use(everyauth.middleware(autoSetupRoutes: false))

  # Add browserchannel client-side scripts to model bundles created by store,
  # and return middleware for responding to remote client messages
  .use(racerBrowserChannel(store))

  .use(store.modelMiddleware()) # Add req.getModel() method

  # Authentication
  .use(auth.middleware(strategies, options))

  # Custom Translations
  .use(middleware.translate)

  # API should be hit before all other routes
  .use('/api/v1', require('./api').middleware)
  .use('/api/v2', require('./apiv2').middleware)
  .use(require('./deprecated').middleware)

  # Other custom middlewares
  .use(priv.middleware)
  .use(middleware.view)

  # Create an express middleware from the app's routes
  .use(main.router())
  .use(login.router())
  .use(require('./static').middleware) #custom static middleware
  .use error()

priv.routes(expressApp)

# SERVER-SIDE ROUTES #

expressApp.all "*", (req, res, next) ->
  next "404: " + req.url