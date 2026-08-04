// Reports which modifier states the host hands to the engine: the ones it
// can see, and (by their absence) the web-spec states it reports for no
// keyboard at all.
export default class {
  handleKey(event) {
    const names = ["Shift", "Control", "Alt", "Meta", "CapsLock", "NumLock",
                   "AltGraph", "Hyper", "Super", "ScrollLock", "Fn"];
    const active = names.filter((name) => event.getModifierState(name));
    console.log(`modifierfx ${event.code} states=[${active}]`);
    return false;
  }
}
