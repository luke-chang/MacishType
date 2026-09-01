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
# Lets the client push a selection via SetSurroundingText, the primary query
# source for the Find Input Code (reverse lookup) surface.
CAPABILITY_SURROUNDING_TEXT = 1 << 6
# Routes the input panel over DBus (UpdateClientSideUI) so tests can assert
# candidate lists and their comments.
CAPABILITY_CLIENT_SIDE_INPUT_PANEL = 1 << 39


def emit(payload):
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def main():
    im_name = sys.argv[1]
    keys = []
    kimpanel = False
    for spec in sys.argv[2:]:
        # "--kimpanel" impersonates the kimpanel panel (owns org.kde.impanel)
        # before anything else runs. Opt-in: owning that name changes which
        # UI addon fcitx5 selects for every test in the session.
        if spec == "--kimpanel":
            kimpanel = True
            continue
        # "props" dumps the last RegisterProperties payload received from
        # fcitx5's kimpanel addon (requires --kimpanel), with a sequence
        # number so assertions can target a specific dump.
        if spec == "props":
            keys.append(("props",))
            continue
        # "trigger:NAME" fires kimpanel's TriggerProperty at an action
        # (requires --kimpanel); a bare action name gets the /Fcitx/ prefix.
        if spec.startswith("trigger:"):
            keys.append(("trigger", spec[len("trigger:"):]))
            continue
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
        # "focusout" drops focus (window switch away); fcitx commits the
        # committable preedit and deactivates.
        if spec == "focusout":
            keys.append(("focusout",))
            continue
        # "reset" asks the IM to reset (in-app commit: click elsewhere in
        # the same field, Ctrl+A) without losing focus.
        if spec == "reset":
            keys.append(("reset",))
            continue
        # "switchim:NAME" switches the current input method by hand (e.g. to
        # keyboard-us) mid-sequence, keeping focus.
        if spec.startswith("switchim:"):
            keys.append(("switchim", spec[len("switchim:"):]))
            continue
        # "setsurrounding:TEXT" pushes TEXT as the client's surrounding text
        # with the whole string selected (cursor 0, anchor = char count), so
        # SurroundingText::selectedText() returns TEXT.
        if spec.startswith("setsurrounding:"):
            keys.append(("setsurrounding", spec[len("setsurrounding:"):]))
            continue
        # "setaddonconfig:ADDON:KEY=V1[,V2...]" writes one list option of an
        # addon's config through DBus SetConfig (e.g. chttrans EnabledIM).
        if spec.startswith("setaddonconfig:"):
            addon, _, assignment = spec[len("setaddonconfig:"):].partition(":")
            key, _, value = assignment.partition("=")
            keys.append(("setaddonconfig", addon, key, value))
            continue
        # "setaddonopt:ADDON:KEY=VALUE" writes one scalar option of an
        # addon's config (booleans travel as "True"/"False").
        if spec.startswith("setaddonopt:"):
            addon, _, assignment = spec[len("setaddonopt:"):].partition(":")
            key, _, value = assignment.partition("=")
            keys.append(("setaddonopt", addon, key, value))
            continue
        # "checkupdate" asks the controller whether newly installed input
        # methods or addons are pending; emits the boolean.
        if spec == "checkupdate":
            keys.append(("checkupdate",))
            continue
        # "refresh" loads newly installed input methods and addons (what
        # configtool's Update button does).
        if spec == "refresh":
            keys.append(("refresh",))
            continue
        # "setgroupims:NAME1,NAME2,..." replaces the Default group's input
        # method list (SetCurrentIM silently ignores IMs outside the group).
        if spec.startswith("setgroupims:"):
            keys.append(("setgroupims", spec[len("setgroupims:"):]))
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

    latest_properties = []
    if kimpanel:
        # The panel half: own the well-known name (fcitx5's kimpanel addon
        # resumes once org.kde.impanel has an owner), cache every
        # RegisterProperties payload, and announce the panel. fcitx5 signals
        # from /kimpanel; the panel signals from /org/kde/impanel.
        acquired = {"done": False}
        Gio.bus_own_name_on_connection(
            bus, "org.kde.impanel", Gio.BusNameOwnerFlags.NONE,
            lambda *_args: acquired.__setitem__("done", True), None)

        def on_kimpanel_signal(_bus, _sender, _path, _iface, signal, params):
            if signal == "RegisterProperties":
                latest_properties[:] = list(params.unpack()[0])

        bus.signal_subscribe(None, "org.kde.kimpanel.inputmethod", None, None,
                             None, Gio.DBusSignalFlags.NONE,
                             on_kimpanel_signal)
        context = GLib.MainContext.default()
        while not acquired["done"]:
            context.iteration(True)
        for iface, name in (("org.kde.impanel", "PanelCreated"),
                            ("org.kde.impanel2", "PanelCreated2")):
            bus.emit_signal(None, "/org/kde/impanel", iface, name, None)
        # Ready barrier: fcitx5's kimpanel requests this name in resume().
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            reply = bus.call_sync(
                "org.freedesktop.DBus", "/org/freedesktop/DBus",
                "org.freedesktop.DBus", "NameHasOwner",
                GLib.Variant("(s)", ("org.kde.kimpanel.inputmethod",)),
                GLib.VariantType("(b)"), Gio.DBusCallFlags.NONE, 1000, None)
            if reply.unpack()[0]:
                break
            while context.iteration(False):
                pass
            time.sleep(0.05)
        else:
            emit({"event": "kimpanel", "ready": False})
            sys.exit(1)
        emit({"event": "kimpanel", "ready": True})

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
            (_preedit, _cursor, aux_up, _aux_down, candidates,
             candidate_cursor, layout, has_prev, has_next) = values
            emit({
                "event": "candidates",
                "auxUp": "".join(text for text, _format in aux_up),
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
                CAPABILITY_SURROUNDING_TEXT |
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
    props_state = {"seq": 0}

    def send_keys():
        for entry in keys:
            if entry[0] == "props":
                props_state["seq"] += 1
                emit({"event": "properties", "seq": props_state["seq"],
                      "items": list(latest_properties)})
                continue
            if entry[0] == "trigger":
                key = entry[1]
                if not key.startswith("/"):
                    key = "/Fcitx/" + key
                bus.emit_signal(None, "/org/kde/impanel", "org.kde.impanel",
                                "TriggerProperty",
                                GLib.Variant("(s)", (key,)))
                emit({"event": "triggered", "key": key})
                continue
            if entry[0] == "sleep":
                # Pump the main context while waiting so queued DBus
                # signals (commit/preedit) reach stdout before the next
                # action — event-driven tests react to those lines.
                deadline = time.monotonic() + entry[1] / 1000
                context = GLib.MainContext.default()
                while time.monotonic() < deadline:
                    while context.iteration(False):
                        pass
                    time.sleep(0.02)
                continue
            if entry[0] == "refocus":
                ic_call("FocusOut")
                time.sleep(0.2)
                ic_call("FocusIn")
                time.sleep(0.2)
                emit({"event": "refocused"})
                continue
            if entry[0] == "focusout":
                ic_call("FocusOut")
                emit({"event": "focused-out"})
                continue
            if entry[0] == "reset":
                ic_call("Reset")
                emit({"event": "was-reset"})
                continue
            if entry[0] == "setsurrounding":
                text = entry[1]
                # cursor 0, anchor at the end selects the whole text (offsets
                # are in characters, so Python's len is the code-point count).
                ic_call("SetSurroundingText",
                        GLib.Variant("(suu)", (text, 0, len(text))))
                emit({"event": "surrounding-set", "text": text})
                continue
            if entry[0] == "switchim":
                # 30s like the initial switch: selecting a macishtype IM
                # loads its JS engine synchronously on the fcitx main loop.
                bus.call_sync(
                    BUS_NAME, "/controller",
                    "org.fcitx.Fcitx.Controller1", "SetCurrentIM",
                    GLib.Variant("(s)", (entry[1],)), None,
                    Gio.DBusCallFlags.NONE, 30000, None)
                emit({"event": "im-switched-away", "to": entry[1]})
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
            if entry[0] == "checkupdate":
                reply = bus.call_sync(
                    BUS_NAME, "/controller", "org.fcitx.Fcitx.Controller1",
                    "CheckUpdate", None, GLib.VariantType("(b)"),
                    Gio.DBusCallFlags.NONE, 5000, None)
                emit({"event": "checkupdate", "value": reply.unpack()[0]})
                continue
            if entry[0] == "refresh":
                bus.call_sync(
                    BUS_NAME, "/controller", "org.fcitx.Fcitx.Controller1",
                    "Refresh", None, None,
                    Gio.DBusCallFlags.NONE, 5000, None)
                emit({"event": "refreshed"})
                continue
            if entry[0] == "setgroupims":
                _kind, value = entry
                ims = [(name, "") for name in value.split(",") if name]
                bus.call_sync(
                    BUS_NAME, "/controller", "org.fcitx.Fcitx.Controller1",
                    "SetInputMethodGroupInfo",
                    GLib.Variant("(ssa(ss))", ("Default", "us", ims)),
                    None, Gio.DBusCallFlags.NONE, 5000, None)
                emit({"event": "group-set", "ims": [name for name, _ in ims]})
                continue
            if entry[0] == "setaddonopt":
                _kind, addon, key, value = entry
                raw = GLib.Variant("a{sv}", {key: GLib.Variant("s", value)})
                bus.call_sync(
                    BUS_NAME, "/controller", "org.fcitx.Fcitx.Controller1",
                    "SetConfig",
                    GLib.Variant("(sv)", (f"fcitx://config/addon/{addon}", raw)),
                    None, Gio.DBusCallFlags.NONE, 5000, None)
                emit({"event": "addon-opt-set", "addon": addon, "key": key,
                      "value": value})
                continue
            if entry[0] == "setaddonconfig":
                _kind, addon, key, value = entry
                # A RawConfig list travels as a nested a{sv} keyed by index;
                # an empty value writes an empty list.
                items = [item for item in value.split(",") if item]
                inner = GLib.Variant("a{sv}", {
                    str(i): GLib.Variant("s", item)
                    for i, item in enumerate(items)
                })
                raw = GLib.Variant("a{sv}", {key: inner})
                bus.call_sync(
                    BUS_NAME, "/controller", "org.fcitx.Fcitx.Controller1",
                    "SetConfig",
                    GLib.Variant("(sv)", (f"fcitx://config/addon/{addon}", raw)),
                    None, Gio.DBusCallFlags.NONE, 5000, None)
                emit({"event": "addon-config-set", "addon": addon, "key": key,
                      "value": value})
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
