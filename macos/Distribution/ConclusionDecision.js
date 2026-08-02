// Installer JavaScript that decides the Summary-pane conclusion action.
// Force a re-login when the declared input mode set changed (first install, or
// the installed ComponentInputModeDict differs from the one being installed),
// otherwise close normally. `macishNew` (the new build's ComponentInputModeDict)
// is injected ahead of this block by the build.
//
// Runs in the Installer's sandboxed JS. Two quirks of system.files.plistAtPath
// are handled: plist booleans bridge as numbers (normalized below), and bridged
// objects expose a phantom enumerable `toString` (filtered via hasOwnProperty).
var macishPath = system.env["HOME"] + "/Library/Input Methods/MacishType.app/Contents/Info.plist";
var macishOld = (function () {
    var plist = system.files.plistAtPath(macishPath);
    return (plist == null) ? null : plist["ComponentInputModeDict"];
})();

function macishNorm(value) {
    if (value === true) { return 1; }
    if (value === false) { return 0; }
    return value;
}

function macishDiffers(a, b) {
    a = macishNorm(a);
    b = macishNorm(b);
    var typeA = (a === null) ? "null" : typeof a;
    var typeB = (b === null) ? "null" : typeof b;
    if (typeA !== typeB) { return true; }
    if (typeA === "object") {
        var keysA = [];
        for (var k1 in a) { if (a.hasOwnProperty(k1)) { keysA.push(k1); } }
        var keysB = [];
        for (var k2 in b) { if (b.hasOwnProperty(k2)) { keysB.push(k2); } }
        if (keysA.length !== keysB.length) { return true; }
        for (var i = 0; i < keysA.length; i++) {
            if (macishDiffers(a[keysA[i]], b[keysA[i]])) { return true; }
        }
        return false;
    }
    return a !== b;
}

function macishConclusion() {
    var action = (macishOld == null || macishDiffers(macishOld, macishNew)) ? "RequireLogout" : "none";
    system.log("[MacishType] conclusion action=" + action);
    return action;
}
