// Logs what the host made of the session's locale environment: the
// preference list, the manifest name it picked, and Intl's default locale.
console.log(`langfx languages ${JSON.stringify(navigator.languages)}`);
console.log(`langfx name ${manifest.name}`);
console.log(`langfx intl ${new Intl.DateTimeFormat().resolvedOptions().locale}`);

export default class {}
