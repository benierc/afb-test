--[[
    Copyright (C) 2018 "IoT.bzh"
    Author Romain Forlot <romain.forlot@iot.bzh>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

      http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.


    NOTE: strict mode: every global variables should be prefixed by '_'
--]]

local lu = require('luaunit')
lu.LuaUnit:setOutputType('JUNIT')
lu.LuaUnit.fname = "var/jUnitResults.xml"

-- Use our own print function to redirect it to a file the standard output
_standard_print = print
print = function(...)
	io.write(... .. '\n')
	_standard_print(...)
end

_AFT = {
	exit = {0, code},
	context = _ctx,
	tests_list = {},
	event_history = false,
	monitored_events = {},
}

function _AFT.enableEventHistory()
	_AFT.event_history = true
end

function _AFT.setJunitFile(filePath)
	lu.LuaUnit.fname = filePath
end

function _AFT.setOutputFile(filePath)
	local file = assert(io.open(filePath, "w+"))
	io.output(file)
end

function _AFT.exitAtEnd(code)
	_AFT.exit = {1, code}
end

--[[
  Events listener and assertion functions to test correctness of received
  event data.

  Check are in 2 times. First you need to register the event that you want to
  monitor then you test that it has been correctly received.

  Notice that there is a difference between log and event. Logs are daemon
  messages normally handled by the host log system (journald, syslog...) and
  events are generated by the apis to communicate and send informations to the
  subscribed listeners.
]]

function _AFT.addEventToMonitor(eventName, callback)
	_AFT.monitored_events[eventName] = { cb = callback, receivedCount = 0 }
end

function _AFT.incrementCount(dict)
	if dict.receivedCount then
		dict.receivedCount = dict.receivedCount + 1
	else
		dict.receivedCount = 1
	end
end

function _AFT.registerData(dict, eventData)
	if dict.data and type(dict.data) == 'table' then
		if _AFT.event_history == true then
			table.insert(dict.data, eventData, 1)
		else
			dict.data[1] = eventData
		end
	else
		dict.data = {}
		table.insert(dict.data, eventData)
	end
end

function _AFT.requestDaemonEventHandler(eventObj)
	local eventName = eventObj.data.message
	local log = _AFT.monitored_events[eventName]
	local api = nil

	if eventObj.daemon then
		api = eventObj.daemon.api
	elseif eventObj.request then
		api = eventObj.request.api
	end

	if log and log.api == api and log.type == eventObj.data.type then
		_AFT.incrementCount(_AFT.monitored_events[eventName])
		_AFT.registerData(_AFT.monitored_events[eventName], eventObj.data)
	end

end

function _AFT.bindingEventHandler(eventObj)
	local eventName = eventObj.event.name
	local eventListeners = eventObj.data.result

	-- Remove from event to hold the bare event data and be able to assert it
	eventObj.data.result = nil

	if type(_AFT.monitored_events[eventName]) == 'table' then
		_AFT.monitored_events[eventName].eventListeners = eventListeners

		_AFT.incrementCount(_AFT.monitored_events[eventName])
		_AFT.registerData(_AFT.monitored_events[eventName], eventObj.data)
	end
end

function _evt_catcher_ (source, action, eventObj)
	if eventObj.type == "event" then
		_AFT.bindingEventHandler(eventObj)
	elseif eventObj.type == "daemon" or eventObj.type == "request" then
		_AFT.requestDaemonEventHandler(eventObj)
	end
end

--[[
  Assert and test functions about the event part.
]]

function _AFT.assertEvtNotReceived(eventName)
	local count = 0
	if _AFT.monitored_events[eventName].receivedCount then
		count = _AFT.monitored_events[eventName].receivedCount
	end

	_AFT.assertIsTrue(count == 0, "Event '".. eventName .."' received but it shouldn't")

	if _AFT.monitored_events[eventName].cb then
		local data_n = #_AFT.monitored_events[eventName].data
		_AFT.monitored_events[eventName].cb(eventName, _AFT.monitored_events[eventName].data[data_n])
	end
end

function _AFT.assertEvtReceived(eventName)
	local count = 0
	if _AFT.monitored_events[eventName].receivedCount then
		count = _AFT.monitored_events[eventName].receivedCount
	end

	_AFT.assertIsTrue(count > 0, "No event '".. eventName .."' received")

	if _AFT.monitored_events[eventName].cb then
		local data_n = #_AFT.monitored_events[eventName].data
		_AFT.monitored_events[eventName].cb(eventName, _AFT.monitored_events[eventName].data[data_n])
	end
end

function _AFT.testEvtNotReceived(testName, eventName, timeout)
	table.insert(_AFT.tests_list, {testName, function()
		if timeout then sleep(timeout) end
		_AFT.assertEvtNotReceived(eventName)
	end})
end

function _AFT.testEvtReceived(testName, eventName, timeout)
	table.insert(_AFT.tests_list, {testName, function()
		if timeout then sleep(timeout) end
		_AFT.assertEvtReceived(eventName)
	end})
end

--[[
  Assert function meant to tests API Verbs calls
]]

local function assertVerbCallParameters(src, api, verb, args)
	_AFT.assertIsUserdata(src, "Source must be an opaque userdata pointer which will be passed to the binder")
	_AFT.assertIsString(api, "API and Verb must be string")
	_AFT.assertIsString(verb, "API and Verb must be string")
	_AFT.assertIsTable(args, "Arguments must use LUA Table (event empty)")
end

function _AFT.assertVerb(api, verb, args, cb)
	assertVerbCallParameters(_AFT.context, api, verb, args)
	local err,responseJ = AFB:servsync(_AFT.context, api, verb, args)
	_AFT.assertIsFalse(err)
	_AFT.assertStrContains(responseJ.request.status, "success", nil, nil, "Call for API/Verb failed.")

	local tcb = type(cb)
	if cb then
		if tcb == 'function' then
			cb(responseJ)
		elseif tcb == 'table' then
			_AFT.assertEquals(responseJ.response, cb)
		elseif tcb == 'string' or tcb == 'number' then
			_AFT.assertEquals(responseJ.response, cb)
		else
			_AFT.assertIsTrue(false, "Wrong parameter passed to assertion. Last parameter should be function, table representing a JSON object or nil")
		end
	end
end

function _AFT.assertVerbError(api, verb, args, cb)
	assertVerbCallParameters(_AFT.context, api, verb, args)
	local err,responseJ = AFB:servsync(_AFT.context, api, verb, args)
	_AFT.assertIsTrue(err)
	_AFT.assertNotStrContains(responseJ.request.status, "success", nil, nil, "Call for API/Verb succeed but it shouldn't.")

	local tcb = type(cb)
	if cb then
		if tcb == 'function' then
			cb(responseJ)
		elseif tcb == 'string' then
			_AFT.assertNotEquals(responseJ.request.info, cb)
		else
			_AFT.assertIsFalse(false, "Wrong parameter passed to assertion. Last parameter should be a string representing the failure informations")
		end
	end
end

function _AFT.testVerb(testName, api, verb, args, cb)
	table.insert(_AFT.tests_list, {testName, function()
		_AFT.assertVerb(api, verb, args, cb)
	end})
end

function _AFT.testVerbError(testName, api, verb, args, cb)
	table.insert(_AFT.tests_list, {testName, function()
		_AFT.assertVerbError(api, verb, args, cb)
	end})
end

function _AFT.describe(testName, testFunction)
	table.insert(_AFT.tests_list, {testName, function()
		testFunction()
	end})
end

--[[
	Make all assertions accessible using _AFT and declare some convenients
	aliases.
]]

local luaunit_list_of_assert = {
	--  official function name from luaunit test framework

	-- general assertions
	'assertEquals',
	'assertItemsEquals',
	'assertNotEquals',
	'assertAlmostEquals',
	'assertNotAlmostEquals',
	'assertEvalToTrue',
	'assertEvalToFalse',
	'assertStrContains',
	'assertStrIContains',
	'assertNotStrContains',
	'assertNotStrIContains',
	'assertStrMatches',
	'assertError',
	'assertErrorMsgEquals',
	'assertErrorMsgContains',
	'assertErrorMsgMatches',
	'assertIs',
	'assertNotIs',

	-- type assertions: assertIsXXX -> assert_is_xxx
	'assertIsNumber',
	'assertIsString',
	'assertIsTable',
	'assertIsBoolean',
	'assertIsNil',
	'assertIsTrue',
	'assertIsFalse',
	'assertIsNaN',
	'assertIsInf',
	'assertIsPlusInf',
	'assertIsMinusInf',
	'assertIsPlusZero',
	'assertIsMinusZero',
	'assertIsFunction',
	'assertIsThread',
	'assertIsUserdata',

	-- type assertions: assertNotIsXXX -> assert_not_is_xxx
	'assertNotIsNumber',
	'assertNotIsString',
	'assertNotIsTable',
	'assertNotIsBoolean',
	'assertNotIsNil',
	'assertNotIsTrue',
	'assertNotIsFalse',
	'assertNotIsNaN',
	'assertNotIsInf',
	'assertNotIsPlusInf',
	'assertNotIsMinusInf',
	'assertNotIsPlusZero',
	'assertNotIsMinusZero',
	'assertNotIsFunction',
	'assertNotIsThread',
	'assertNotIsUserdata',
}

local luaunit_list_of_functions = {
	"setOutputType",
}

local _AFT_list_of_funcs = {
	-- AF Binder generic assertions
	{ 'addEventToMonitor', 'resetEventReceivedCount' },
	{ 'assertVerb',      'assertVerbStatusSuccess' },
	{ 'assertVerb',      'assertVerbResponseEquals' },
	{ 'assertVerb',      'assertVerbCb' },
	{ 'assertVerbError', 'assertVerbStatusError' },
	{ 'assertVerbError', 'assertVerbResponseEqualsError' },
	{ 'assertVerbError', 'assertVerbCbError' },
	{ 'testVerb',      'testVerbStatusSuccess' },
	{ 'testVerb',      'testVerbResponseEquals' },
	{ 'testVerb',      'testVerbCb' },
	{ 'testVerbError', 'testVerbStatusError' },
	{ 'testVerbError', 'testVerbResponseEqualsError' },
	{ 'testVerbError', 'testVerbCbError' },
}

-- Import all luaunit assertion function to _AFT object
for _, v in pairs( luaunit_list_of_assert ) do
	local funcname = v
	_AFT[funcname] = lu[funcname]
end

-- Import specific luaunit configuration functions to _AFT object
for _, v in pairs( luaunit_list_of_functions ) do
	local funcname = v
	_AFT[funcname] = lu.LuaUnit[funcname]
end

-- Create all aliases in _AFT
for _, v in pairs( _AFT_list_of_funcs ) do
	local funcname, alias = v[1], v[2]
	_AFT[alias] = _AFT[funcname]
end

function _launch_test(context, args)
	_AFT.context = context

	_AFT.setOutputFile("var/test_results.log")
	AFB:servsync(_AFT.context, "monitor", "set", { verbosity = "debug" })
	AFB:servsync(_AFT.context, "monitor", "trace", { add = { api = args.trace, request = "vverbose", event = "push_after" }})
	if args.files and type(args.files) == 'table' then
		for _,f in pairs(args.files) do
			dofile('var/'..f)
		end
	elseif type(args.files) == 'string' then
		dofile('var/'..args.files)
	end

	AFB:success(_AFT.context, { info = "Launching tests"})
	lu.LuaUnit:runSuiteByInstances(_AFT.tests_list)

	local success ="Success : "..tostring(lu.LuaUnit.result.passedCount)
	local failures="Failures : "..tostring(lu.LuaUnit.result.testCount-lu.LuaUnit.result.passedCount)

	local evtHandle = AFB:evtmake(_AFT.context, 'results')
	AFB:subscribe(_AFT.context,evtHandle)
	AFB:evtpush(_AFT.context,evtHandle,{info = success.." "..failures})

	if _AFT.exit[1] == 1 then os.exit(_AFT.exit[2]) end
end