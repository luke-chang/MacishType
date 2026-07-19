#!/usr/bin/env python3
"""DBus typing client for an isolated fcitx5 instance.

Creates an input context on the session bus, focuses it, sends key events,
and prints observed signals as JSON lines:

    {"event": "commit", "text": "..."}
    {"event": "preedit", "text": "...", "cursor": 3}
    {"event": "forward", "keyval": 65293, "state": 0, "isRelease": false}
    {"event": "key-result", "keyval": 97, "handled": true}

The first argument is the input method unique name to switch the focused
context to (a fresh context starts on the group's inactive keyboard entry).
Remaining arguments are key events in the form `keyval[:keycode[:state]]`
(all integers, keyval may be a single ASCII character instead), with an
implicit release after each press.
"""

import json
import sys
import time

import gi
from gi.repository import Gio, GLib

BUS_NAME = "org.fcitx.Fcitx5"
IM_PATH = "/org/freedesktop/portal/inputmethod"
IM_IFACE = "org.fcitx.Fcitx.InputMethod1"
IC_IFACE = "org.fcitx.Fcitx.InputContext1"

CAPABILITY_PREEDIT = 1 << 1
CAPABILITY_FORMATTED_PREEDIT = 1 << 4
# Routes the input panel over DBus (UpdateClientSideUI) so tests can assert
# candidate lists and their comments.
CAPABILITY_CLIENT_SIDE_INPUT_PANEL = 1 << 39


def emit(payload):
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def main():
    im_name = sys.argv[1]
    keys = []
    for spec in sys.argv[2:]:
        # "sleep:MS" pauses between keys (e.g. for hot-reload tests).
        if spec.startswith("sleep:"):
            keys.append(("sleep", int(spec.split(":")[1])))
            continue
        # "iminfo" dumps the current IM's registered entry fields.
        if spec == "iminfo":
            keys.append(("iminfo",))
            continue
        # "getconfig" dumps the IM's config values and description.
        if spec == "getconfig":
            keys.append(("getconfig",))
            continue
        # "refocus" ends and restarts the session (deactivate + activate),
        # the boundary at which settings refresh.
        if spec == "refocus":
            keys.append(("refocus",))
            continue
        # "setconfig:KEY=VALUE" writes one option through DBus SetConfig.
        if spec.startswith("setconfig:"):
            key, _, value = spec[len("setconfig:"):].partition("=")
            keys.append(("setconfig", key, value))
            continue
        parts = spec.split(":")
        keyval = parts[0]
        keyval = ord(keyval) if len(keyval) == 1 and not keyval.isdigit() \
            else int(keyval)
        keycode = int(parts[1]) if len(parts) > 1 else 0
        state = int(parts[2]) if len(parts) > 2 else 0
        keys.append(("key", keyval, keycode, state))

    bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)

    result = bus.call_sync(
        BUS_NAME, IM_PATH, IM_IFACE, "CreateInputContext",
        GLib.Variant("(a(ss))", ([("program", "typing-client")],)),
        GLib.VariantType("(oay)"), Gio.DBusCallFlags.NONE, 5000, None)
    ic_path = result.unpack()[0]
    emit({"event": "created", "path": ic_path})

    def on_signal(_bus, _sender, _path, _iface, signal, params):
        values = params.unpack()
        if signal == "CommitString":
            emit({"event": "commit", "text": values[0]})
        elif signal == "UpdateFormattedPreedit":
            segments, cursor = values
            emit({
                "event": "preedit",
                "text": "".join(text for text, _format in segments),
                "cursor": cursor,
                "segments": [[text, fmt] for text, fmt in segments],
            })
        elif signal == "ForwardKey":
            keyval, state, is_release = values
            emit({"event": "forward", "keyval": keyval, "state": state,
                  "isRelease": is_release})
        elif signal == "UpdateClientSideUI":
            (_preedit, _cursor, _aux_up, _aux_down, candidates,
             candidate_cursor, layout, has_prev, has_next) = values
            emit({
                "event": "candidates",
                "items": [{"label": label, "text": text}
                          for label, text in candidates],
                "cursor": candidate_cursor,
                "layout": layout,
                "hasPrev": has_prev,
                "hasNext": has_next,
            })

    bus.signal_subscribe(None, IC_IFACE, None, ic_path, None,
                         Gio.DBusSignalFlags.NONE, on_signal)

    def ic_call(method, params=None, reply_type=None):
        return bus.call_sync(
            BUS_NAME, ic_path, IC_IFACE, method, params,
            GLib.VariantType(reply_type) if reply_type else None,
            Gio.DBusCallFlags.NONE, 5000, None)

    ic_call("SetCapability", GLib.Variant(
        "(t)", (CAPABILITY_PREEDIT | CAPABILITY_FORMATTED_PREEDIT |
                CAPABILITY_CLIENT_SIDE_INPUT_PANEL,)))
    ic_call("FocusIn")
    # The first switch to a macishtype IM loads its JS engine synchronously,
    # so this duration doubles as the engine load time.
    switch_started = time.monotonic()
    bus.call_sync(
        BUS_NAME, "/controller", "org.fcitx.Fcitx.Controller1",
        "SetCurrentIM", GLib.Variant("(s)", (im_name,)), None,
        Gio.DBusCallFlags.NONE, 30000, None)
    emit({"event": "im-switched",
          "ms": round((time.monotonic() - switch_started) * 1000, 1)})

    loop = GLib.MainLoop()

    def send_keys():
        for entry in keys:
            if entry[0] == "sleep":
                time.sleep(entry[1] / 1000)
                continue
            if entry[0] == "refocus":
                ic_call("FocusOut")
                time.sleep(0.2)
                ic_call("FocusIn")
                time.sleep(0.2)
                emit({"event": "refocused"})
                continue
            if entry[0] == "getconfig":
                reply = bus.call_sync(
                    BUS_NAME, "/controller", "org.fcitx.Fcitx.Controller1",
                    "GetConfig",
                    GLib.Variant(
                        "(s)", (f"fcitx://config/inputmethod/{im_name}",)),
                    GLib.VariantType("(va(sa(sssva{sv})))"),
                    Gio.DBusCallFlags.NONE, 5000, None)
                values, description = reply.unpack()
                emit({"event": "config", "values": values,
                      "description": description})
                continue
            if entry[0] == "setconfig":
                _kind, key, value = entry
                raw = GLib.Variant("a{sv}", {key: GLib.Variant("s", value)})
                bus.call_sync(
                    BUS_NAME, "/controller", "org.fcitx.Fcitx.Controller1",
                    "SetConfig",
                    GLib.Variant(
                        "(sv)",
                        (f"fcitx://config/inputmethod/{im_name}", raw)),
                    None, Gio.DBusCallFlags.NONE, 5000, None)
                emit({"event": "config-set", "key": key, "value": value})
                continue
            if entry[0] == "iminfo":
                reply = bus.call_sync(
                    BUS_NAME, "/controller", "org.fcitx.Fcitx.Controller1",
                    "AvailableInputMethods", None,
                    GLib.VariantType("(a(ssssssb))"),
                    Gio.DBusCallFlags.NONE, 5000, None)
                for (unique_name, name, _native, icon, label, language,
                     _configurable) in reply.unpack()[0]:
                    if unique_name == im_name:
                        emit({"event": "iminfo", "name": name, "icon": icon,
                              "label": label, "language": language})
                continue
            _kind, keyval, keycode, state = entry
            for is_release in (False, True):
                call_started = time.monotonic()
                reply = ic_call(
                    "ProcessKeyEvent",
                    GLib.Variant("(uuubu)",
                                 (keyval, keycode, state, is_release, 0)),
                    "(b)")
                if not is_release:
                    emit({"event": "key-result", "keyval": keyval,
                          "handled": reply.unpack()[0],
                          "ms": round(
                              (time.monotonic() - call_started) * 1000, 1)})
        # Give queued signals a beat to arrive before quitting.
        GLib.timeout_add(300, loop.quit)
        return False

    GLib.timeout_add(300, send_keys)
    loop.run()

    ic_call("FocusOut")
    ic_call("DestroyIC")
    emit({"event": "done"})


if __name__ == "__main__":
    main()
