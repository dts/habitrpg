express = require 'express'
router = new express.Router()

_ = require 'lodash'
{algos, helpers} = require 'habitrpg-shared'
validator = require 'derby-auth/node_modules/validator'
check = validator.check
sanitize = validator.sanitize
u = require '../app/user.coffee'

NO_TOKEN_OR_UID = err: "You must include a token and uid (user id) in your request"
NO_USER_FOUND = err: "No user found."

# ---------- /api/v1 API ------------
# Every url added beneath router is prefaced by /api/v1

###
  v1 API. Requires api-v1-user (user id) and api-v1-key (api key) headers, Test with:
  $ cd node_modules/racer && npm install && cd ../..
  $ mocha test/api.mocha.coffee
###

###
  API Status
###
router.get '/status', (req, res) ->
  res.json status: 'up'

###
  beforeEach auth interceptor
###
auth = (req, res, next) ->
  uid = req.headers['x-api-user']
  token = req.headers['x-api-key']
  return res.json 401, NO_TOKEN_OR_UID unless uid || token

  model = req.getModel()

  $priv = model.query 'usersPrivate', {id: uid, apiToken: token, $limit:1}
  $priv.fetch (err) ->
    return res.json err: err if err
    return res.json 401, NO_USER_FOUND if _.isEmpty($priv.get()[0])

    $priv = model.at "usersPrivate.#{uid}"
    $pub = model.at "usersPublic.#{uid}"
    model.fetch $priv, $pub, (err) ->
      return res.json err: err if err
      req.ats = {$priv: $priv, $pub: $pub, id: $priv.get('id')}
      req.gets = gets = {priv:$priv.get(), pub:$pub.get()}
      req.uobj = u.transformForAPI gets.pub, gets.priv
      next()

###
  GET /user
###
router.get '/user', auth, (req, res) ->
  {uobj} = req

  uobj.stats.toNextLevel = algos.tnl uobj.stats.lvl
  uobj.stats.maxHealth = 50

  delete uobj.apiToken
  if uobj.auth
    delete uobj.auth.hashed_password
    delete uobj.auth.salt

  res.json uobj

###
  GET /user/task/:id
###
router.get '/user/task/:id', auth, (req, res) ->
  task = req.gets.priv.tasks[req.params.id]
  return res.json 400, err: "No task found." if _.isEmpty(task)
  res.json 200, task

###
  validate task
###
validateTask = (req, res, next) ->
  task = {}
  newTask = { type, text, notes, value, up, down, completed } = req.body

  # If we're updating, get the task from the user
  if req.method is 'PUT' or req.method is 'DELETE'
    task = req.gets.priv.tasks[req.params.id]
    return res.json 400, err: "No task found." if _.isEmpty(task)
    # Strip for now
    type = undefined
    delete newTask.type
  else if req.method is 'POST'
    newTask.value = sanitize(value).toInt()
    newTask.value = 0 if isNaN newTask.value
    unless /^(habit|todo|daily|reward)$/.test type
      return res.json 400, err: 'type must be habit, todo, daily, or reward'

  newTask.text = sanitize(text).xss() if typeof text is "string"
  newTask.notes = sanitize(notes).xss() if typeof notes is "string"

  switch type
    when 'habit'
      newTask.up = true unless typeof up is 'boolean'
      newTask.down = true unless typeof down is 'boolean'
    when 'daily', 'todo'
      newTask.completed = false unless typeof completed is 'boolean'

  _.extend task, newTask
  req.task = task
  next()

###
  PUT /user/task/:id
###
router.put '/user/task/:id', auth, validateTask, (req, res) ->
  req.ats.$priv.set "tasks.#{req.task.id}", req.task
  res.json 200, req.task

###
  DELETE /user/task/:id
###
router.delete '/user/task/:id', auth, validateTask, (req, res) ->
  taskIds = req.ats.$priv.get "ids.#{req.task.type}s"

  req.ats.$priv.del "tasks.#{req.task.id}"
  # Remove one id from array of typeIds
  req.ats.$priv.remove "ids.#{req.task.type}s", taskIds.indexOf(req.task.id), 1

  res.send 204

###
  POST /user/tasks
###
updateTasks = (tasks, req) ->
  {uobj, ats} = req
  for idx, task of tasks
    if task.id
      if task.del
        ats.$priv.del "tasks.#{task.id}"
        if task.type # TODO we should enforce they pass in type, so we can properly remove from idList
          if (i = _.findIndex ats.$priv.get("ids.#{task.type}s"), {id: task.id}) != -1
            ats.$priv.remove("ids.#{task.type}s", i, 1) # doens't work when task.type isn't passed up
        task = deleted: true
      else
        ats.$priv.set "tasks.#{task.id}", task
    else
      type = task.type or 'habit'
      ats.$priv.set "tasks.#{task.id}", task
      ats.$priv.push "ids.#{type}s", task.id
    tasks[idx] = task
  return tasks

router.post '/user/tasks', auth, (req, res) ->
  tasks = updateTasks req.body, req
  res.json 201, tasks

###
  POST /user/task/
###
router.post '/user/task', auth, validateTask, (req, res) ->
  task = req.task
  type = task.type

  req.ats.$priv.set "tasks.#{task.id}", task
  req.ats.$priv.push "ids.#{type}s", task.id

  res.json 201, task

###
  GET /user/tasks
###
router.get '/user/tasks', auth, (req, res) ->
  {uobj} = req
  return res.json 400, NO_USER_FOUND if _.isEmpty(uobj)

  types = if /^(habit|todo|daily|reward)$/.test(req.query.type) then [req.query.type]
  else ['habit','todo','daily','reward']

  res.json 200, _.toArray req.ats.$priv.get('tasks'), ((t) ->t.type in types)

###
  This is called form deprecated.coffee's score function, and the req.headers are setup properly to handle the login
###
scoreTask = (req, res, next) ->
  {taskId, direction} = req.params
  {title, service, icon, type} = req.body
  type ?= 'habit'

  # Send error responses for improper API call
  return res.send(500, ':taskId required') unless taskId
  return res.send(500, ":direction must be 'up' or 'down'") unless direction in ['up','down']

  {ats, uobj} = req

  existingTask = ats.$priv.at "tasks.#{taskId}"
  # TODO add service & icon to task
  # If task exists, set it's compltion
  if existingTask.get()
    # Set completed if type is daily or todo
    existingTask.set 'completed', (direction is 'up') if /^(daily|todo)$/.test existingTask.get('type')
  else
    task =
      id: taskId
      type: type
      text: (title || taskId)
      value: 0
      notes: "This task was created by a third-party service. Feel free to edit, it won't harm the connection to that service. Additionally, multiple services may piggy-back off this task."

    switch type
      when 'habit'
        task.up = true
        task.down = true
      when 'daily', 'todo'
        task.completed = direction is 'up'

    ats.$priv.add "tasks", task
    ats.$priv.push "ids.#{type}", task.id

  paths = {}
  tobj = _.where uobj.habits.concat(uobj.todos.concat(uobj.dailys.concat(uobj.rewards))), {id:taskId}
  console.log {uobj, tobj}
  delta = algos.score(req.uobj, tobj, direction, {paths})
  u.setDiff req.getModel(), req.uobj, paths, cb: ->
    result = ats.$pub.get('stats')
    result.delta = delta
    res.json result

###
  POST /user/tasks/:taskId/:direction
###
router.post '/user/task/:taskId/:direction', auth, scoreTask
router.post '/user/tasks/:taskId/:direction', auth, scoreTask

###
  TODO POST /user
  when a put attempt didn't work, create a new one with POST
###

###
  PUT /user
###
router.put '/user', auth, (req, res) ->
  ats = {req}
  partialUser = req.body.user

  # REVISIT is this the best way of handling protected v acceptable attr mass-setting? Possible pitfalls: (1) we have to remember
  # to update here when we add new schema attrs in the future, (2) developers can't assign random variables (which
  # is currently beneficial for Kevin & Paul). Pros: protects accidental or malicious user data corruption

  # TODO - this accounts for single-nested items (stats.hp, stats.exp) but will clobber any other depth.
  # See http://stackoverflow.com/a/6394168/362790 for when we need to cross that road

  # acceptable attributes
  paths = {}
  ['flags', 'history', 'items', 'preferences', 'profile', 'stats', 'lastCron'].forEach (attr) ->
    paths[attr] = true if partialUser[attr]?
  u.setDiff(req.getModel(), partialUser, paths)

  updateTasks(partialUser.tasks, req) if partialUser.tasks?

  uobj = u.transformForAPI ats.$pub.get(), ats.$priv.get()
  res.json 201, uobj

module.exports = router
module.exports.auth = auth
module.exports.scoreTask = scoreTask # export so deprecated can call it
