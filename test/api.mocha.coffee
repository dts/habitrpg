_ = require 'lodash'
request = require 'superagent'
expect = require 'expect.js'
require 'coffee-script'
require 'racer'
u = require '../src/app/user.coffee'

path = require 'path'
conf = require("nconf")
conf.argv().env().file(path.join(__dirname + '/../config.json')).defaults "NODE_ENV": 'test'

## monkey-patch expect.js for better diffs on mocha
## see: https://github.com/LearnBoost/expect.js/pull/34

origBe = expect.Assertion::be
expect.Assertion::be = expect.Assertion::equal = (obj) ->
  @_expected = obj
  origBe.call this, obj

# Custom modules
helpers = require 'habitrpg-shared/script/helpers'

###### Helpers & Variables ######

model = null
uuid = null
taskPath = null
baseURL = 'http://localhost:1337/api/v1'

###### Specs ######

describe 'API', ->
  server = null
  store = null
  model = null
  ats = null
  uid = null

  before (done) ->
    server = require '../src/server/index.coffee'
    server.listen '1337', '0.0.0.0', null, ->
      store = server.store
      #store.flush()
      model = store.createModel()
      uid = model.id()
      server.registerCallback {getModel: (->model)}, null, {id:uid}, done

  describe 'Without token or user id', ->

    it '/api/v1/status', (done) ->
      request.get("#{baseURL}/status")
        .set('Accept', 'application/json')
        .end (res) ->
          expect(res.statusCode).to.be 200
          expect(res.body.status).to.be 'up'
          done()

    it '/api/v1/user', (done) ->
      request.get("#{baseURL}/user")
        .set('Accept', 'application/json')
        .end (res) ->
          expect(res.statusCode).to.be 401
          expect(res.body.err).to.be 'You must include a token and uid (user id) in your request'
          done()

  describe 'With token and user id', ->
    params = null
    currentUser = null

    getCurrentUser = (done) ->
      $pub = model.at "usersPublic.#{uid}"
      $priv = model.at "usersPrivate.#{uid}"
      model.fetch $pub, $priv, (err) ->
        throw err if err
        ats = $pub: $pub, $priv: $priv
        currentUser = u.transformForAPI $pub.get(), $priv.get()
        done()

    before (done) ->
      params =
        title: 'Title'
        text: 'Text'
        type: 'habit'
      getCurrentUser done

    beforeEach (done) ->
      getCurrentUser(done)

    it 'GET /api/v1/user', (done) ->
      request.get("#{baseURL}/user")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .end (res) ->
          expect(res.body.err).to.be undefined
          expect(res.statusCode).to.be 200
          expect(res.body.id).not.to.be.empty()
          self = _.clone(currentUser)
          delete self.apiToken
          self.stats.toNextLevel = 150
          self.stats.maxHealth = 50

          expect(res.body).to.eql self
          done()

    it 'GET /api/v1/user/task/:id', (done) ->
      tid = _.pluck(currentUser.tasks, 'id')[0]
      request.get("#{baseURL}/user/task/#{tid}")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .end (res) ->
          expect(res.body.err).to.be undefined
          expect(res.statusCode).to.be 200
          expect(res.body).to.eql currentUser.tasks[tid]
          done()

    it 'POST /api/v1/user/task', (done) ->
      request.post("#{baseURL}/user/task")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .send(params)
        .end (res) ->
          $q = model.query "usersPrivate", {id: currentUser.id, apiToken: currentUser.apiToken}
          $q.fetch (err) ->
            expect(res.body.err).to.be undefined
            expect(res.statusCode).to.be 201
            expect(res.body.id).not.to.be.empty()
            # Ensure that user owns the newly created object
            expect($q.get().tasks[res.body.id]).to.be.an('object')
            done()

    it 'POST /api/v1/user/task (without type)', (done) ->
      request.post("#{baseURL}/user/task")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .send({})
        .end (res) ->
          expect(res.body.err).to.be 'type must be habit, todo, daily, or reward'
          expect(res.statusCode).to.be 400
          done()

    it 'POST /api/v1/user/task (only type)', (done) ->
      request.post("#{baseURL}/user/task")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .send(type: 'habit')
        .end (res) ->
          $q = model.query 'usersPrivate', {id: currentUser.id, apiToken: currentUser.apiToken}
          $q.fetch (err) ->
            expect(res.body.err).to.be undefined
            expect(res.statusCode).to.be 201
            expect(res.body.id).not.to.be.empty()
            # Ensure that user owns the newly created object
            expect($q.get().tasks[res.body.id]).to.be.an('object')
            # Ensure that value gets set to 0 since not otherwise specified
            expect($q.get().tasks[res.body.id].value).to.be.equal(0)
            done()

    it 'PUT /api/v1/user/task/:id', (done) ->
      tid = _.pluck(currentUser.tasks, 'id')[0]
      request.put("#{baseURL}/user/task/#{tid}")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .send(text: 'bye')
        .end (res) ->
          expect(res.body.err).to.be undefined
          expect(res.statusCode).to.be 200
          currentUser.tasks[tid].text = 'bye'
          expect(res.body).to.eql currentUser.tasks[tid]
          done()

    it 'PUT /api/v1/user/task/:id (shouldnt update type)', (done) ->
      tid = _.pluck(currentUser.tasks, 'id')[1]
      type = if currentUser.tasks[tid].type is 'habit' then 'daily' else 'habit'
      request.put("#{baseURL}/user/task/#{tid}")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .send(type: type, text: 'fishman')
        .end (res) ->
          expect(res.body.err).to.be undefined
          expect(res.statusCode).to.be 200
          currentUser.tasks[tid].text = 'fishman'
          expect(res.body).to.eql currentUser.tasks[tid]
          done()

    it 'PUT /api/v1/user/task/:id (update notes)', (done) ->
      tid = _.pluck(currentUser.tasks, 'id')[2]
      request.put("#{baseURL}/user/task/#{tid}")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .send(text: 'hi',notes:'foobar matey')
        .end (res) ->
          expect(res.body.err).to.be undefined
          expect(res.statusCode).to.be 200
          currentUser.tasks[tid].text = 'hi'
          currentUser.tasks[tid].notes = 'foobar matey'
          expect(res.body).to.eql currentUser.tasks[tid]
          done()

    it 'GET /api/v1/user/tasks', (done) ->
      request.get("#{baseURL}/user/tasks")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .end (res) ->
          $q = model.query 'users', {id: currentUser.id, apiToken: currentUser.apiToken}
          $q.fetch (err) ->
            expect(res.body.err).to.be undefined
            expect(res.statusCode).to.be 200
            model.ref '_page.user', $q
            tasks = []
            for type in ['habit','todo','daily','reward']
              model.refList "_page.lists.#{type}s", "_page.user.tasks", "_page.user.ids.#{type}s"
              tasks = tasks.concat model.get("_page.lists.#{type}s")
            # Ensure that user owns the tasks
            expect(res.body.length).to.equal tasks.length
            # Ensure that the two sets are equal
            expect(_.difference(_.pluck(res.body,'id'), _.pluck(tasks,'id')).length).to.equal 0
            done()

    it 'GET /api/v1/user/tasks (todos)', (done) ->
      request.get("#{baseURL}/user/tasks")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .query(type:'todo')
        .end (res) ->
          $q = model.query 'usersPrivate', {id: currentUser.id, apiToken: currentUser.apiToken}
          $q.fetch (err) ->
            expect(res.body.err).to.be undefined
            expect(res.statusCode).to.be 200
            model.ref '_page.user', $q
            model.refList "_page.lists.todos", "_page.user.tasks", "_page.user.ids.todos"
            tasks = model.get("_page.lists.todos")
            # Ensure that user owns the tasks
            expect(res.body.length).to.equal tasks.length
            # Ensure that the two sets are equal
            expect(_.difference(_.pluck(res.body,'id'), _.pluck(tasks,'id')).length).to.equal 0
            done()

    it 'DELETE /api/v1/user/task/:id', (done) ->
      tid = currentUser.habitIds[2]
      request.del("#{baseURL}/user/task/#{tid}")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .end (res) ->
          expect(res.body.err).to.be undefined
          expect(res.statusCode).to.be 204
          $q = model.query 'usersPrivate', {id: currentUser.id, apiToken: currentUser.apiToken}
          $q.fetch (err) ->
            expect($q.get('ids.habits').indexOf(tid)).to.be -1
            expect($q.get("tasks.#{tid}")).to.be undefined
            done()

    it 'DELETE /api/v1/user/task/:id (no task found)', (done) ->
      tid = "adsfasdfjunkshouldntbeatask"
      request.del("#{baseURL}/user/task/#{tid}")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .end (res) ->
          expect(res.statusCode).to.be 400
          expect(res.body.err).to.be 'No task found.'
          done()

    it 'POST /api/v1/user/task/:id/up (habit)', (done) ->
      tid = currentUser.habitIds[0]
      request.post("#{baseURL}/user/task/#{tid}/up")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .send({})
        .end (res) ->
          expect(res.body.err).to.be undefined
          expect(res.statusCode).to.be 200
          expect(res.body).to.eql { gp: 1, exp: 7.5, lvl: 1, hp: 50, delta: 1 }
          done()

    it 'POST /api/v1/user/task/:id/up (daily)', (done) ->
      tid = currentUser.dailyIds[0]
      request.post("#{baseURL}/user/task/#{tid}/up")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .send({})
        .end (res) ->
          expect(res.body.err).to.be undefined
          expect(res.statusCode).to.be 200
          expect(res.body).to.eql { gp: 2, exp: 15, lvl: 1, hp: 50, delta: 1 }
          $q = model.query 'usersPrivate', {id: currentUser.id, apiToken: currentUser.apiToken}
          $q.fetch (err) ->
            expect($q.get("tasks.#{tid}.completed")).to.be true
            done()

    it 'POST /api/v1/user/task (array)', (done) ->
      habitId = currentUser.habitIds[0]
      dailyId = currentUser.dailyIds[0]
      arr = [{
        id: habitId
        text: 'hello'
        notes: 'note'
      },{
        text: 'new task'
        notes: 'notes!'
      },{
        id: dailyId
        del: true
      }]

      request.post("#{baseURL}/user/tasks")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .send(arr)
        .end (res) ->
          expect(res.body.err).to.be undefined
          expect(res.statusCode).to.be 201
          expect(res.body[0]).to.eql {id: habitId,text: 'hello',notes: 'note'}
          expect(res.body[1].id).to.be.a 'string'
          expect(res.body[1].text).to.be 'new task'
          expect(res.body[1].notes).to.be 'notes!'
          expect(res.body[2]).to.eql deleted: true

          $q = model.query 'usersPrivate', {id: currentUser.id, apiToken: currentUser.apiToken}
          $q.fetch (err) ->
            expect($q.get("tasks.#{habitId}")).to.eql {id: habitId,text: 'hello',notes: 'note'}
            expect($q.get("tasks.#{dailyId}")).to.be undefined
            expect($q.get("tasks.#{res.body[1].id}")).to.eql id: res.body[1].id, text: 'new task', notes: 'notes!'
            done()

    it 'PUT /api/v1/user', (done) ->
      userBefore = {}
      $q = model.query 'usersPrivate', {id: currentUser.id, apiToken: currentUser.apiToken}
      $q.fetch (err) -> userBefore = $q.get()

      habitId = currentUser.habitIds[0]
      dailyId = currentUser.dailyIds[0]
      userUpdates =
        stats:
          hp: 30
        flags:
          itemsEnabled: true
        tasks: [{
          id: habitId
          text: 'hello2'
          notes: 'note2'
        },{
          text: 'new task2'
          notes: 'notes2'
        },{
          id: dailyId
          del: true
        }]

      request.put("#{baseURL}/user")
        .set('Accept', 'application/json')
        .set('X-API-User', currentUser.id)
        .set('X-API-Key', currentUser.apiToken)
        .send(user: userUpdates)
        .end (res) ->
          expect(res.body.err).to.be undefined
          expect(res.statusCode).to.be 201
          tasks = res.body.tasks

          expect(_.find(tasks,{id:habitId})).to.eql {id: habitId,text: 'hello2',notes: 'note2'}
        
          foundNewTask = _.find(tasks,{text:'new task2'})
          expect(foundNewTask.text).to.be 'new task2'
          expect(foundNewTask.notes).to.be 'notes2'
        
          found = _.find(res.body.tasks, {id:dailyId})
          expect(found).to.not.be.ok()

          query.fetch (err, user) ->
            expect(user.get("tasks.#{habitId}")).to.eql {id: habitId, text: 'hello2',notes: 'note2'}
            expect(user.get("tasks.#{dailyId}")).to.be undefined
            tasks = res.body.tasks
            expect(user.get("tasks.#{foundNewTask.id}")).to.eql id: foundNewTask.id, text: 'new task2', notes: 'notes2'
            done()



