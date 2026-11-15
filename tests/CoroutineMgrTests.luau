---------------------------------------------------------------------
-- Tests for CoroutineMgr: waiting, resuming, timeouts, and the
-- is_waiting check that message handlers use to skip work for replies
-- nobody asked for. Needs no story and no ROM cards.
---------------------------------------------------------------------

local CoroMgr, await_event, yield_frame = table.unpack(require("../VM/coromgr.luau"))
local TestFramework = require("TestFramework.luau")

local runTest = TestFramework.run
local assertEqual = TestFramework.assertEqual
local assertTrue = TestFramework.assertTrue

local function runAllTests()
    runTest("is_waiting is true only while a task waits for that event", function()
        local result: string? = nil
        CoroMgr:create_task(function()
            local _, data = await_event("cm_test_a")
            result = data
        end)
        assertTrue(CoroMgr:is_waiting("cm_test_a"), "waiting")
        assertEqual(CoroMgr:is_waiting("cm_test_other"), false, "a different event")
        CoroMgr:handle_event("cm_test_a", true, "go")
        assertEqual(result, "go")
        assertEqual(CoroMgr:is_waiting("cm_test_a"), false, "no longer waiting once resumed")
    end)

    runTest("handle_event works from inside a running task and wakes only the matching waiter", function()
        local first, second = nil, nil
        CoroMgr:create_task(function()
            local _, data = await_event("cm_test_b1")
            first = data
        end)
        CoroMgr:create_task(function()
            local _, data = await_event("cm_test_b2")
            second = data
        end)
        -- This test body is itself a running task.
        CoroMgr:handle_event("cm_test_b2", true, "two")
        assertEqual(first, nil, "the other waiter stays asleep")
        assertEqual(second, "two")
        CoroMgr:handle_event("cm_test_b1", true, "one")
        assertEqual(first, "one")
    end)

    runTest("a wait with a timeout resumes with false and 'timeout', and stops waiting", function()
        local ok: boolean? = nil
        local data: any = nil
        CoroMgr:create_task(function()
            ok, data = await_event("cm_test_c", 0.2)
        end)
        assertTrue(CoroMgr:is_waiting("cm_test_c"))
        yield_frame(0.6)
        assertEqual(ok, false)
        assertEqual(data, "timeout")
        assertEqual(CoroMgr:is_waiting("cm_test_c"), false)
    end)

    runTest("an event nobody waits for does nothing", function()
        CoroMgr:handle_event("cm_test_nobody", true, "ignored")
        assertEqual(CoroMgr:is_waiting("cm_test_nobody"), false)
    end)

    runTest("a finished task leaves nothing behind in the manager's table", function()
        local function count(): number
            local n = 0
            for _ in CoroMgr._coros do
                n += 1
            end
            return n
        end
        local before = count()
        for _ = 1, 50 do
            CoroMgr:create_task(function() end)
        end
        local waiting = CoroMgr:create_task(function()
            await_event("cm_test_leak")
        end)
        assertEqual(count(), before + 1, "only the task that is still waiting remains")
        CoroMgr:handle_event("cm_test_leak", true, "go")
        assertEqual(count(), before, "and it leaves too once it finishes")
        assertTrue(coroutine.status(waiting) == "dead", "the waiting task finished")
    end)

    TestFramework.printSummary("CoroutineMgr tests")
end

print(`Starting Memory: {ll.GetFreeMemory()} bytes`)

CoroMgr:create_task(runAllTests)
