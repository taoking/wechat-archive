# Invoked by the foreground workflow inside LLDB; no standalone/background scan.
import json
import os
import signal
from pathlib import Path
import lldb

CAPTURED = set()
STATS = {"calls": 0, "length32": 0, "readFailures": 0, "errors": 0}
OUTPUT = None
BREAKPOINT_IDS = set()


def on_crypto(frame, location, internal_dict):
    STATS["calls"] += 1
    try:
        process = frame.GetThread().GetProcess()
        mode = "WithMode" in (frame.GetFunctionName() or "")
        arm = "arm64" in process.GetTarget().GetTriple()
        reg = lambda name: frame.FindRegister(name).GetValueAsUnsigned()
        # Registers can be shifted by thunks/prologue handling. Try the two
        # known ABI layouts at these four CommonCrypto entrypoints, as upstream
        # does. Every candidate still needs native page HMAC before export.
        if arm:
            arguments = [(reg("x3"), reg("x4")), (reg("x5"), reg("x6"))]
        else:
            pointer = reg("r9" if mode else "rcx")
            error = lldb.SBError()
            length = process.ReadUnsignedFromMemory(reg("rsp") + 8, 8, error) if mode else reg("r8")
            if mode and not error.Success():
                return False
            arguments = [(pointer, length)]
        for pointer, length in arguments:
            if length != 32 or not pointer:
                continue
            STATS["length32"] += 1
            error = lldb.SBError()
            value = process.ReadMemory(pointer, 32, error)
            if not error.Success() or value is None or len(value) != 32:
                STATS["readFailures"] += 1
                continue
            if isinstance(value, str):
                value = value.encode("latin1")
            candidate = bytes(value).hex()
            if candidate in CAPTURED or len(CAPTURED) >= 4096:
                continue
            CAPTURED.add(candidate)
            temporary = OUTPUT.with_suffix(".tmp")
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "w") as stream:
                json.dump(sorted(CAPTURED), stream)
            temporary.replace(OUTPUT)
    except Exception as error:
        # Never include values or raw target memory in diagnostics.
        STATS["errors"] += 1
        STATS["lastErrorType"] = type(error).__name__
    return False


def __lldb_init_module(debugger, internal_dict):
    global OUTPUT
    OUTPUT = Path(os.environ["WECHAT_CAPTURE_OUTPUT"])
    os.umask(0o077)
    debugger.SetAsync(True)
    debugger.HandleCommand("settings set target.skip-prologue false")
    target = debugger.GetSelectedTarget()
    for name in ("CCCryptorCreate", "CCCryptorCreateWithMode", "CCCryptorCreateFromData", "CCCrypt"):
        breakpoint = target.BreakpointCreateByName(name)
        BREAKPOINT_IDS.add(breakpoint.GetID())
        breakpoint.SetScriptCallbackFunction(__name__ + ".on_crypto")
    print("CAPTURE_READY: candidate values are never logged.", flush=True)


def resume_breakpoint(debugger):
    """Resume capture breakpoints and debugger SIGSTOP, never a crash."""
    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    if process.GetState() != lldb.eStateStopped:
        return
    threads = list(process)
    reasons = [thread.GetStopReason() for thread in threads]
    # LLDB sometimes labels the second simultaneous software-breakpoint hit
    # EXC_BREAKPOINT. Accept it only at a location owned by this capture module.
    sites = set()
    for index in range(target.GetNumBreakpoints()):
        breakpoint = target.GetBreakpointAtIndex(index)
        if breakpoint.GetID() not in BREAKPOINT_IDS:
            continue
        for location_index in range(breakpoint.GetNumLocations()):
            location = breakpoint.GetLocationAtIndex(location_index)
            if location.IsResolved():
                sites.add(location.GetAddress().GetLoadAddress(target))
    recognized = []
    for thread, reason in zip(threads, reasons):
        if reason == lldb.eStopReasonException:
            description = thread.GetStopDescription(128)
            frame = thread.GetFrameAtIndex(0)
            pc = frame.GetPC()
            step = 4 if "arm64" in target.GetTriple() else 1
            site = next((value for value in sites if pc in (value, value + step)), None)
            if isinstance(description, str) and "EXC_BREAKPOINT" in description and site is not None:
                on_crypto(frame, None, None)
                if pc != site and not frame.SetPC(site):
                    STATS["pcResetFailed"] = True
                    return
                recognized.append(lldb.eStopReasonBreakpoint)
                continue
        recognized.append(reason)
    harmless = (lldb.eStopReasonNone, lldb.eStopReasonInvalid,
                lldb.eStopReasonBreakpoint, lldb.eStopReasonPlanComplete,
                lldb.eStopReasonTrace)
    debugger_stop = any(reason == lldb.eStopReasonSignal and
                        thread.GetStopReasonDataAtIndex(0) == signal.SIGSTOP
                        for thread, reason in zip(threads, recognized))
    # Trace stops come from this debugger stepping over its software traps.
    if (lldb.eStopReasonBreakpoint in recognized or debugger_stop or
            lldb.eStopReasonTrace in recognized) and all(
            reason in harmless or (reason == lldb.eStopReasonSignal and
                                   thread.GetStopReasonDataAtIndex(0) == signal.SIGSTOP)
            for thread, reason in zip(threads, recognized)):
        process.Continue()
    else:
        STATS["blockedStopReasons"] = sorted(set(reasons))
